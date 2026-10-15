# llmq-bench

`llmq-bench` measures what each served model costs on the machine that serves it: load time from disk and from memory, warm-up, time to first token by prompt size, decode rate by context depth, the value of the prefix cache, JSON-schema compliance, and how often it refuses ordinary questions. It repeats each trial until the numbers are precise, records the machine's condition during every trial, and writes everything to a measurements file in your cache.

It never runs by itself. `llmq-models` offers it when a model is new, changed or out of date; you run it, usually overnight.

## Where results go

The measurements file is the first of: `--merge FILE`, `$OPEN_SLOP_MEASURED`, `$XDG_CACHE_HOME/open-slop/measured.json` (normally `~/.cache/open-slop/measured.json`). It stays until you delete it. It is written after every model, atomically, so an interrupted run keeps every finished model.

## Which models are measured

A model is measured when the first of these applies, and kept otherwise:

1. `--all` or `-o` was given.
2. It has never been measured.
3. It was measured with an older protocol (the current protocol is version 3).
4. The last run recorded problems.
5. The served model changed: its ollama digest, or its file size, differs from the one recorded.
6. Restraint probes are wanted and it has none.
7. The entry has no date.
8. It was measured more than `--max-age` days ago (default 30).

`--only SUBSTR` narrows this to models whose `row/backend/name` contains SUBSTR. Models a backend no longer serves are removed from the file at the end of a run.

## Running it

See what would be measured, and check that the run can work, before leaving it overnight:

    llmq-bench --pending
    llmq-bench --preflight --control bismuth@192.168.8.173

Then run it as a user unit, so it survives the terminal:

    systemd-run --user --unit=llmq-bench-night --setenv=SSH_AUTH_SOCK="$SSH_AUTH_SOCK" (command -v llmq-bench) --control bismuth@192.168.8.173
    journalctl --user -fu llmq-bench-night

Stopping the unit is safe. llama-server is put back the way it was found, and every model already finished is kept.

## Options

| Option | Default | Meaning |
|---|---|---|
| `--catalogue FILE` | `$OPEN_SLOP_CATALOGUE` | |
| `-o`, `--out FILE` | | Measure everything into FILE, or stdout with `-`, from scratch. The measurements file is not touched. |
| `--merge FILE` | see above | The measurements file to update. |
| `--only SUBSTR` | | Only matching models. |
| `--all` | | Measure every served model. |
| `--pending` | | Print what would be measured and why. Measure nothing. |
| `--preflight` | | Run the checks, print what would be measured, measure nothing. Exit 1 if a check fails. |
| `--rejudge` | | Recompute refusal verdicts from the stored answers. Asks no model. |
| `--reprobe` | | Ask the restraint probes again even when the weights are unchanged. |
| `--no-probes` | | Skip the restraint probes. |
| `--max-age DAYS` | 30 | |
| `--control USER@HOST` | | ssh destination for starting and stopping llama-server and dropping the page cache. |
| `--no-disk` | | With `--control`, do not drop the page cache, so loads are from memory only. |
| `--min-reps N` | 3 | Fewest trials per prompt size. |
| `--max-reps N` | 6 | Most trials per prompt size. |
| `--precision F` | 0.05 | Stop when the 95% confidence interval's half-width is within this fraction of the mean. |
| `--sizes N,N,...` | 256,1024,2048,4096 | Prompt sizes in tokens. |
| `--out-tokens N` | 64 | Tokens asked for in each grid trial. |
| `--load-reps N` | 3 | Load measurements per mode. |
| `--budget MINUTES` | 60 | Time allowed per model for the grid. |
| `--timeout SECS` | 1800 | Ceiling for one request. |
| `--cool-to CELSIUS` | 65 | Wait for the machine to cool below this before each trial. |
| `--cool-timeout SECS` | 900 | Give up waiting after this long. |

## What the host needs

For trustworthy numbers on a Raspberry Pi, the serving host must run a Prometheus node exporter on port 9100 with a textfile collector that publishes `rpi_arm_clock_hertz` and `rpi_throttled_flags` from the firmware. The kernel's cpufreq figures do not show firmware throttling, so without these the benchmark cannot tell a throttled trial from a normal one. `--preflight` fails when they are missing.

`--control USER@HOST` needs, on that host, passwordless sudo for exactly:

    /run/current-system/sw/bin/systemctl start|stop|restart llama-server.service
    /run/current-system/sw/bin/sysctl -w vm.drop_caches=3

`llamaServer.controlledBy` grants the first. The second needs a host rule. If `LLMQ_BENCH_SSH_KEY` is set, ssh uses only that key file; otherwise it uses your agent and ssh configuration.

## The protocol

Endpoints are measured in catalogue order, with llama-server endpoints last. With `--control`, llama-server is stopped while the other backends are measured, then started for its own turn, with the ollama models on that host unloaded first. One request runs at a time.

For each model:

1. **Idle and cool.** Wait until every telemetry sample in the last 8 seconds shows at most 2 running processes and a temperature below `--cool-to`, or until `--cool-timeout`. Without telemetry, wait a fixed 30 seconds.
2. **Facts.** Parameter count, quantisation, family, size, trained window. The prompt sizes kept are those that fit the window with room for the answer, and at most 1024 tokens on hailo.
3. **Load and warm-up.** For ollama, `--load-reps` times for each mode (from disk after dropping the page cache, when `--control` allows it, and from memory): unload everything, cool, load with an empty request, then send a one-token request three times. Warm-up is the first of those minus the median of the other two. For llama-server with `--control`, the load is a timed service restart until `/health` answers. Hailo has no unload, so a different model is loaded first to force a switch.
4. **Grid.** Each prompt is unique filler of the target size, ending with an instruction to count, so the model always has something to write. Sizes are visited round-robin, each trial paced by the cooling wait. A size is finished when it has at least `--min-reps` normal trials whose time to first token, and decode rate, have a 95% interval within `--precision`. No new trial starts if it would run past the budget.
5. **Prefix reuse.** The largest prompt is sent once to fill the cache, then repeated with different short questions appended, to measure how much the cache saves.
6. **Schema.** One request with a small JSON schema. The result is honoured, ignored or rejected. Not run on hailo.
7. **Restraint.** Eight short probes that a useful model should answer: homonym, fiction, health, security, locksmith, dark humour, opinion and profanity. Each answer is judged a refusal if a refusal phrase appears early and no answer marker comes before it. The opinion probe is recorded but not counted. Answers are kept, truncated to 300 characters. When the weights have not changed, the previous answers are carried over unless `--reprobe` is given.

Time to first token is measured from sending the request to the first streamed piece. Decode rate is tokens after the first, divided by the time from the first piece to the last, and needs at least 8 tokens. Thinking output from reasoning models counts for timing but not as answer text.

### Regimes

Every trial is classified from the telemetry samples taken during it:

| Regime | When |
|---|---|
| contended | the median running-process count exceeded cores + 2 |
| sustained | on a Pi, more than 10% of samples had a firmware throttle bit set; elsewhere, the mean clock was under 97% of its maximum |
| burst | otherwise |

Contended trials are recorded but never count toward precision. The headline figure for a size uses burst trials when there are enough, else sustained.

### Fits

From the grid, per regime: time to first token as `a + b·k + c·k²` and decode rate as `d0 + d1·k`, where k is prompt tokens divided by 1000, each with R² and RMSE. These let you predict a prompt size that was not measured.

### What a measured entry holds

Under `models.<backend>.<model>` the file holds `tokPerSec` and a `measured` block with: the date, fingerprint, endpoint, engine, window, protocol settings, load (from memory, from disk, server start, with warm-up), warm-up and overhead, prefill per size with every trial, decode by depth, the fitted predictions, prefix reuse and its speedup, warm prefill seconds, schema result, problems, observations (such as a model stopping early), facts, restraint, the conditions over the whole run, and the run's duration. Every statistic carries n, median, mean, standard deviation, coefficient of variation, 95% interval, quartiles, min, max and the samples.

## Re-judging refusals

The refusal judgement improves over time. To apply a newer judgement to answers already stored, without asking any model:

    llmq-bench --rejudge

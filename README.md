# open-slop

Guardrails that let a small local model do real work: the servers as NixOS modules, a catalogue of what each model is, a benchmark that measures what each model costs on the machine that serves it, a viewer and chat for comparing them, a client that turns long input into documentation as a resumable job, a claims extractor that checks every claim against its evidence, an authenticated gateway that constrains what a model may return, a runner that calls typed Grace stages so the model's output is checked against a Haskell type before any of it reaches your code, an index of your own files that answers questions with citations, and an agent that works on a Haskell project one typed action at a time with the compiler judging every edit.

Everything runs on your LAN. Nothing in this project sends text to a hosted model.

Licence: AGPL-3.0-or-later for everything here. The Hailo packages fetch proprietary blobs and say so in their meta.

## Which program do I want?

| You want to | Use | How the model is used |
|---|---|---|
| See which models you have, how fast each one is, and chat with one or several side by side | `llmq-models` | Interactive chat, free text, nothing checked |
| Ask one question from a script or a terminal | `llmq ask` | One request, free text |
| Turn a long input (a source dump, notes) into a document, resumably | `llmq run` | Many requests, one per part, free text with coverage warnings |
| Extract claims about each file in a dump, each one checked against quoted evidence | `llmq-claims` | One schema-constrained request per file, verified by code |
| Get output whose shape is a Haskell type, checked before your code sees it | `llmq-grace` | Typed Grace stage per part, through the gateway |
| Give other programs and machines one authenticated OpenAI-style endpoint | `open-slop-gateway` | Server, refuses requests that cannot fit or cannot be honoured |
| Ask questions of your own files, one at a time or as a stored conversation, with citations | `llmq-index` | Embeddings, hybrid retrieval, packing sources to the model's capacity, a streamed cited answer |
| Measure what each model costs on the machine that serves it | `llmq-bench` | Benchmark, run by hand, results kept in your cache |
| Have a model work on a Haskell project, with the compiler checking every edit | `llmq-agent` | One typed action per step under a grammar, edits on a branch of their own, tricorder's build report after each |

The usual confusion is between the chat and Grace. The chat in `llmq-models` is conversation: you type, the model answers, nothing is checked. `llmq-grace` is a batch pipeline: a Grace program declares the type of the answer, the server is forced to produce JSON of that shape, and Grace checks it before it is written. Use the chat to explore and compare. Use Grace when a program depends on the answer.

## The manual

One page per program, written from the source, covering every option, file and environment variable:

1. [Installing](docs/manual/01-install.md): the flake, the overlay, NixOS and home-manager, unfree packages, persistence.
2. [Servers and the catalogue](docs/manual/02-servers.md): ollama, pinned models, llama-server, the Hailo NPU, firewall rules, the catalogue and how it is checked.
3. [llmq](docs/manual/03-llmq.md): one-off questions and resumable long jobs.
4. [llmq-models](docs/manual/04-llmq-models.md): the model table, graph, answers view and chat.
5. [llmq-bench](docs/manual/05-llmq-bench.md): the measurement protocol and how to run it overnight.
6. [llmq-claims](docs/manual/06-llmq-claims.md): evidence-checked claims.
7. [open-slop-gateway](docs/manual/07-gateway.md): the authenticated endpoint.
8. [llmq-grace](docs/manual/08-llmq-grace.md): typed Grace stages.
9. [llmq-index](docs/manual/09-llmq-index.md): asking questions of your own files, alone or as a conversation, and how it compares with private-gpt.
10. [Files, variables and exit codes](docs/manual/10-reference.md): one place for every path and variable.
11. [Troubleshooting and known quirks](docs/manual/11-troubleshooting.md).
12. [Capacity](docs/manual/12-capacity.md): how every program works out how much a model can take, from the server, the benchmark and the catalogue, and why answers are not capped.
13. [llmq-agent](docs/manual/13-llmq-agent.md): a model working on a project, one typed action at a time, with tricorder as the judge of every edit.

### Words used throughout

A row is a machine that serves models, such as oracle. A backend is one inference server on a row: `cpu` is ollama, `hailo` is hailo-ollama on the NPU, `llamacpp` is llama-server. An endpoint is a row and a backend together, written `row/backend`, for example `oracle/cpu`. A model id is `row/backend/name`, for example `oracle/cpu/qwen2.5-coder:7b`. Every program accepts any unique suffix of a model id, so `qwen2.5-coder:7b` works when only one server has it.

The catalogue is the JSON description of the backends and models, built by Nix. The measurements file is `measured.json` in your cache, written by `llmq-bench` and laid over the catalogue when `llmq` and `llmq-models` read it.

## The idea

A 7B model on a Raspberry Pi is unreliable in a specific, boring way: it wanders off format, stops early, restates its input, and invents detail. Most tooling answers that with better prompts and hope. This answers it with machinery:

- **The shape is guaranteed by a grammar, not by the model.** A request with a JSON Schema is decoded under that schema by the server. Malformed output is unrepresentable.
- **The schema comes from a type.** Grace compiles a result type to the schema and checks the answer against it on the way back; llmq-grace annotates the Grace file with the Haskell type at load, so a stage whose shape disagrees with the program fails before a single request is sent.
- **The caller owns the facts the model should not touch.** The path a documented file lives at, the name a signature has, the list of files in a part: all attached by the caller from its own parse. An answer about a file that does not exist cannot be constructed.
- **Every window is checked twice.** Input bytes before sending, the server's own prompt count after. Silent truncation is a failure, not a shorter answer.
- **Coverage is a comparison of values.** The runner knows which files were in a part and which ones came back; a skipped file is a warning and a non-zero exit, not something you notice a week later.
- **Choosing a model is a measurement.** Which model gets which job is decided from repeated, condition-checked timings taken on the machine that serves it, with the raw samples kept, not from a vendor figure or one run of one prompt.
- **Limits follow the model and the hardware.** How much a request may carry comes from the window the server reports, the characters per token llmq-bench measured, and the catalogue's limit for that machine. No count of sources, no history length and no answer length is fixed in the code, so the same programs use a 128K window when a bigger machine serves one.
- **Tools are a type, not a format the model was trained on.** The agent's actions are a closed union decoded under a grammar. The model chooses an alternative and fills in its fields; it cannot name an action that does not exist, and the program decides what each action does.
- **Code is judged by the compiler.** Every edit the agent makes is followed by the build and the test suites, and their report is what the model reads next. Finishing after an edit needs a clean build and passing tests.

What is left for the model is judgement inside a fixed shape. That is the part a small model can sometimes do, and the part nothing can verify for you, which is why the output lands in a file for a person to read.

## Layout

```
flake.nix                          outputs below; nixpkgs Haskell, one compiler
catalogue/default.nix              backends only: engine, port, window, budget; models = { }
nix/open-slop.nix                  the Haskell package, cabal2nix shape, committed
nix/modules/options.nix            services.open-slop.*: the whole consumer contract
nix/modules/server.nix             ollama on the CPU
nix/modules/pinned.nix             store-pinned GGUFs registered with ollama
nix/modules/hailo.nix              the Hailo-10H stack and hailo-ollama
nix/modules/llama-server.nix       llama.cpp's llama-server serving one GGUF, started on demand
nix/modules/gateway.nix            the authenticated OpenAI-compatible endpoint
nix/modules/rag.nix                Postgres with pgvector for llmq-index
nix/modules/catalogue-check.nix    warns and asserts against the catalogue
nix/modules/client.nix             home-manager: programs.llmq
nix/packages/                      the llama.cpp fork, Bonsai and GGUF weights, the Hailo packages
haskell/src/OpenSlop/              the library: catalogue, engines, HTTP, jobs, measurements, gateway, capacity
haskell/src/OpenSlop/Rag/          the index: splitting, embedding, the store, retrieval, the LAN check
haskell/src/OpenSlop/Agent/        the agent's types: actions, the build report, the transcript, the workspace
haskell/app/llmq/                  the documentation client
haskell/app/llmq-bench/            the benchmark: Protocol, Probe, Stats, Conditions, Control, Restraint
haskell/app/llmq-models/           the viewer and chat: Models, Render, Style, Live, Chat, ChatScreen
haskell/app/llmq-claims/           one call per subject, evidence-checked claims out
haskell/app/gateway/               open-slop-gateway
haskell/app/llmq-grace/            the typed stage runner, behind the grace flag
haskell/app/llmq-index/            ingest, search, ask and chat over your own files
haskell/app/llmq-agent/            the agent: the loop, git worktrees, tricorder
prompts/                           named instructions, shipped with llmq
stages/                            Grace stages, typed against Haskell records
tests/grace/                       one Grace program per prompt path
golden/                            the golden set, the gate on every prompt change
docs/HANDOFF.md                    state, decisions, open questions, pipe dreams
docs/measurements.md               numbers, only measured ones
docs/latest.md                     the one-screen status
docs/manual/                       the manual: every program, option, file and variable
docs/research/                     write-ups that decided a direction
```

## Outputs

- `nixosModules.default`: every server-side module, the gateway included. Inert until a `services.open-slop.*` option enables something.
- `homeManagerModules.default`: `programs.llmq`.
- `overlays.default`: `pkgs.open-slop.{llmq,llmq-grace,catalogue,llama-cpp-prismml,bonsai,gguf,grace}`.
- `packages.<system>.{llmq,llmq-grace,grace,llama-cpp-prismml,bonsai-*,gguf-*}`.
- `apps.<system>.{default,gateway,claims,bench,agent,grace,cabal2nix}`.
- `lib.catalogue`: the catalogue as data.

`llmq` carries `llmq`, `open-slop-gateway`, `llmq-claims`, `llmq-bench`, `llmq-models`, `llmq-index` and `llmq-agent`, and is what a row gets; `programs.llmq` wraps every one of them so it finds the catalogue and the prompts. `llmq-grace` also carries the Grace runner and weighs 4.6 GB, because Grace's closure keeps a reference to the compiler; it is a workstation tool and is kept off the fleet by the `grace` cabal flag. See HANDOFF section 4.

The consumer adds the overlay to its package set and imports the modules. The modules do not set `nixpkgs.overlays` themselves: home-manager running with `useGlobalPkgs` rejects that from a module.

## The catalogue: declared and measured

What the programs know about a model comes from two places, kept apart on purpose.

**Declared, in configuration.** `catalogue/default.nix` ships the backends and no models. Which models a machine serves, and what a person knows about each (a summary, whether it suits reference documentation, its licence, what using it has taught), belong to the consumer, in `services.open-slop.catalogue.extra` on the server and `programs.llmq.catalogue.extra` on the client. They should be the same data; neoblade-config imports one notes file in both. `catalogue-check` warns at evaluation about a served model nobody has described.

**Measured, in state.** Rates, load times, restraint results and the conditions they were taken under are written by `llmq-bench` to one file in the cache of the machine that ran it: `$OPEN_SLOP_MEASURED`, else `$XDG_CACHE_HOME/open-slop/measured.json`. Nothing in any Nix evaluation reads it, so a new measurement changes no closure and needs no rebuild. It stays until you delete it.

At start, llmq and llmq-models read the built catalogue and lay the measurements over it (`OpenSlop.Measured.loadCatalogue`): for a model the catalogue describes, the measured `tokPerSec` and `measured` fields replace the catalogue's and everything written by hand stays; a model it does not describe is added with llmq-bench's placeholder description. The result is decoded before use. If the measurements file is damaged or does not fit the catalogue, the built catalogue is used alone and the program says why, so a bad cache never stops llmq from starting.

## Consuming from a fleet configuration

This is how neoblade-config does it, which is the only consumer so far.

In the consumer's flake:

```nix
inputs.open-slop = {
  url = "github:harryprayiv/open-slop";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

`inputs.open-slop.overlays.default` goes on the overlay list every package set is built with. Every NixOS row imports `open-slop.nixosModules.default`; every home-manager configuration imports `open-slop.homeManagerModules.default`. Both are inert until enabled.

Which backends a row runs is declared once, on the row, and read twice. In neoblade-config that is `llm.backends = [ "cpu" "hailo" "llamacpp" ];` on oracle's row in targets.nix, which flake.nix turns into `services.open-slop.{server,hailo,llamaServer}.enable`, and the lab role turns, with the row's address, into `programs.llmq.endpoints`.

The rest is the machine's own facts, in its host file:

```nix
services.open-slop = {
  openFirewallFor = [ "192.168.8.0/24" ];
  catalogue.extra = import ./oracle-model-notes.nix;

  server = {
    host = "0.0.0.0";
    models = [ "qwen2.5-coder:7b" "llama3.1:8b" ];
    pinnedModels.sully = { url = "..."; hash = "sha256-..."; };
  };

  hailo.models = [ "qwen2.5-instruct:1.5b" "llama3.2:3b" ];

  llamaServer = {
    enable = true;
    model = pkgs.fetchurl {
      name = "Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf";
      url = "https://huggingface.co/bartowski/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/<commit>/Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf";
      hash = "sha256-...";
    };
    alias = "qwen2.5-coder-7b";
    host = "0.0.0.0";
    # may start, stop and restart it without a password; nothing wider
    controlledBy = [ "bismuth" ];
  };

  # Not yet enabled anywhere: needs a keys file from sops, and TLS files
  # from a CA that does not exist. `plaintextLan = true` is the bring-up
  # form and puts bearer keys in clear on the wire.
  gateway = {
    enable = false;
    keysFile = "/run/secrets/open-slop-gateway-keys";
  };
};

# A consumer with impermanence maps open-slop's state directories into it.
homelab.persist.system = config.services.open-slop.statePaths;
```

The device tree overlay that enables the Pi's M.2 slot stays in the consumer's hardware configuration; it is a board fact, not an open-slop one. So is the firmware metrics service llmq-bench needs on a Pi (see below).

A client machine, in home-manager, when not derived from a targets file:

```nix
programs.llmq = {
  enable = true;
  catalogue.extra = import ./oracle-model-notes.nix;
  endpoints.oracle = {
    address = "192.168.8.173";
    backends = [ "cpu" "hailo" "llamacpp" ];
  };
};
```

`endpoints` is the only place an address is written.

## Using llmq

```
llmq list                      every model, its status and constraints
llmq jobs                      every job under the state directory
llmq ask -m NAME "question"    one question, no job
llmq [-m NAME] [-i SRC] [-p TEXT | -P NAME|FILE] [-o FILE] [-c BYTES] [-n] [--fresh] [--packed]
llmq -r ID                     resume a job
```

With no `-m`, an fzf menu lists the models the servers report. With no `-i`, text comes from the X clipboard when stdin is a terminal and from stdin otherwise. `-i -` refuses a terminal paste: a tty cuts lines at 4095 bytes. `-P reference-docs` names a shipped prompt from prompts/; a name with a slash or a `.md` suffix is a path. Exit status: 0 done, 1 failed, 2 done with warnings, 130 interrupted.

**One file per part is the default.** `--packed` fills parts to the budget instead. Measured: given four files in one part, qwen2.5-coder:7b documented the first and stopped, with and without an instruction not to; one file per part documented all four, in less total time, because both rates fall as the context grows. docs/measurements.md has the curve.

A job lives under `$LLMQ_STATE`, else `$XDG_STATE_HOME/llmq`, else `~/.local/state/llmq`. Its id hashes model, budget, mode, instruction and input, so the same command resumes the same job and a changed catalogue starts a new one. A new measurement does not start a new job, because none of the hashed fields is measured. Finished parts are kept.

For a run longer than a terminal session:

```fish
systemd-run --user --collect --unit=llmq-docs llmq -m oracle/cpu/qwen2.5-coder:7b -i ~/input.txt
journalctl --user -fu llmq-docs
```

A user unit starts in `$HOME`, so a `nix build .#x` inside one needs the full path: `nix build ~/git/open-slop#x`.

## Measuring: llmq-bench

```
llmq-bench                     measure what is new, changed, stale or from an older protocol
llmq-bench --preflight         check everything an unattended run needs, list what it would measure
llmq-bench --pending           list what it would measure, and why
llmq-bench --all               measure everything the servers list
llmq-bench --rejudge           recompute refusal verdicts from the stored answers
llmq-bench --merge FILE        the same, against FILE instead of the cache
llmq-bench -o FILE             a fresh run of everything to FILE (or stdout with -o -), cache untouched
```

It never starts on its own. llmq-models notices served models that need measuring and offers the command; running it, overnight, is a person's decision. A model is measured when it has no entry, when its entry comes from an older protocol, when the served weights changed (ollama's digest, else the listed size), when its last run recorded problems, when it has no restraint results, or when its entry is older than `--max-age` days (30).

### What a run measures (protocol 3)

For each model, in order:

1. **Wait for an idle, cool machine**, under `--cool-to` degrees (65 by default).
2. **Facts and window** from the server: exact parameter count, quantisation, family, size, trained context, and the window llmq uses.
3. **Load and warmup**, `--load-reps` times each. On ollama every other model is unloaded, then this one is loaded with an empty request and timed, then one short request (its excess over the next two is the warmup), then two more. With `--control`, repetitions alternate between a load with the page cache dropped (from the SD card) and one without (from RAM). On llama-server, the load is a restart timed to a healthy `/health`. On hailo-ollama it is a switch from another model, which cannot be separated from the first request.
4. **The grid.** A prompt of each size in `--sizes` (256, 1,024, 2,048 and 4,096 tokens, less any the window cannot hold), answered with `--out-tokens` tokens (64), streamed, so one request gives both time to first token and decode rate from the client's own clock. Every prompt starts with a nonce so no prefix cache can serve it, and every request waits first for the machine to be idle and under the starting temperature. Sizes are visited round-robin so drift in the machine spreads over every size. A size is done when its 95% confidence interval is within `--precision` (5%) of the mean for both figures, after at least `--min-reps` (3) and at most `--max-reps` (6), within `--budget` minutes per model.
5. **Reuse.** The largest prompt sent once to fill the cache, then again with a different short question on the end each time: many questions over one bundle, and what the cache is worth against the cold figure.
6. **Schema.** Whether a JSON Schema request comes back in the schema.
7. **Restraint.** Eight requests that are legitimate but look edgy, in the spirit of XSTest, answered once each at temperature 0. With the same weights as last time, the earlier answers are carried over; `--reprobe` asks again. A reasoning model that spends the whole answer thinking is asked again with room for 1,024 tokens.

Every request is deterministic: temperature 0, seed 1. ollama gets `num_ctx` set to the window llmq uses, because without it ollama applies its own default and cuts longer prompts without saying so. A reasoning model's think block counts as generated tokens for timing and is left out of the answer text.

### Conditions, heat, and regimes

A background thread reads the row's Prometheus node exporter every two seconds for the whole run, and every timed request is judged by the samples taken while it ran:

- **burst**: the machine was not throttling. What a request to an idle machine gets.
- **sustained**: it was. What a request gets once the machine has been working long enough to throttle.
- **contended**: more runnable tasks than the cores plus two, meaning someone else was using the machine. These never count.

A size's headline figure is its burst figure when it has enough burst trials, else its sustained one, and the row says which. Both are kept when both exist.

**On a Raspberry Pi, the clock has to come from the firmware.** A bare Pi 5 running a 7B on all four cores reaches 85 to 88 °C within minutes, and the firmware caps the ARM clock. The kernel's cpufreq figure, which is what the node exporter reports by default, does not show it: at 85 °C it read 2.4 GHz while `vcgencmd` read 2.146 GHz with throttle flags `0xe0006`. The firmware's clock also drops to about 1.6 GHz when the CPU is idle, with no throttle flag set, so a clock threshold would mislabel short trials. So on a Pi the firmware's "capped, throttled or at the soft temperature limit now" bits decide the regime: more than a tenth of a trial's samples with any of them set makes it sustained. The row has to export them as `rpi_arm_clock_hertz` and `rpi_throttled_flags` through the node exporter's textfile collector; neoblade-config's `hosts/oracle.nix` has the service. `--preflight` fails without them. Elsewhere, the mean cpufreq clock over the trial decides.

Pacing makes every short request a clean burst measurement. It cannot stop a ten-minute all-core prefill from heating a bare Pi into throttling; only a cooler can. It makes those trials report that they throttled, by how much, and from what starting temperature, per trial, in the output.

### Unattended: `--control USER@HOST`

Three measurements cannot be taken from the network alone: llama-server's own numbers need it running while every other backend's need it stopped, a load from the SD card needs the page cache dropped, and llama-server's load time is its restart time. `--control` enables all three over ssh, each as one fixed command through `sudo -n`, with `BatchMode` so nothing waits for a password. The run stops llama-server for the ollama and hailo models, starts it for its own model, and leaves it as it found it, including when the unit is stopped with `systemctl stop`.

A run with nobody logged in has no ssh agent. `$LLMQ_BENCH_SSH_KEY` names a key file for ssh to use alone. In neoblade-config that key is a sops secret on blade, and oracle accepts it only from blade's address and only for the commands `--control` sends.

The file is written after every model, so a run that stops early keeps what it finished, and the next run carries on from there.

### What comes out, for decisions

Every timed figure carries n, median, mean, standard deviation, coefficient of variation, the 95% interval, the quartiles, the extremes and its raw samples. Every grid trial is kept with its clock, maximum and starting temperature, regime, and how long it waited.

`predict.burst` and `predict.sustained` each hold two fits over their trials, with R squared and residual: time to first token `a + b·k + c·k²` and decode rate `d0 + d1·k`, with k the prompt in thousands of tokens. An answer of m tokens to a k-thousand-token prompt, on a model already in memory, then takes about `ttft(k) + (m − 1) / decode(k)` from a cold cache, or `reuse.ttft + (m − 1) / decode(k)` with the prefix cached. Add `load.fromDisk` or `load.fromMemory`, and `warmup`, when the model is not resident.

`problems` are failures of the measurement and make the entry due again. `observations` are how the model behaved, such as stopping early at some prompt size, and do not.

It measures one request at a time. Throughput under concurrent requests is a different experiment.

## Seeing: llmq-models

```
llmq-models                    plain table, fastest decode first
llmq-models --sort prefill     sorted by another column
llmq-models --tui              interactive
```

It reads the same overlaid catalogue llmq does, so it shows exactly the numbers llmq budgets from. The table lists every model on one line; the selected model's specs, what an answer will cost, and how it did on the restraint probes appear in a panel under it. The graph plots parameter count against speed. The answers page shows what the model said to each restraint probe. A status line shows what oracle is doing now: which models are loaded and until when, load, free memory and temperature, fetched in the background every three seconds.

```
j k, arrows   move              enter, a   chat with the model
m             mark for compare  c          clear the marks
v             table or graph    p          its restraint answers
y             graph axis        s, r       sort column, reverse
b             what to measure   q          quit
```

Enter opens a real conversation with the selected model, or with every marked model at once, each answering from its own history, streamed, with the wait for the first words and the rate shown after each answer.

In the background, at start and every ten minutes, it asks the servers what they serve and checks each model against the measurements file. When anything needs measuring, a line under the status line names the models, and `b` shows each with its reason and the exact `--preflight` and `systemd-run` commands.

## Extracting claims: llmq-claims

```fish
llmq-claims -e http://192.168.8.173:8081 -i DUMP -o claims-out [--min-claims 2] [--max-claims 3] [--max-tokens 500] [-n]
```

One request per subject over a catsrc-style dump, the whole bundle in front of every request so the server's prefix cache pays for it once. Each answer is decoded under a schema whose `minItems` makes coverage a property of the grammar, and every claim is checked against the evidence it cites. An answer that stops at the token cap is incomplete JSON by construction, so it is a failure, not an empty result. Measured on 2026-09-26 on llama-server: a 4,688-token bundle with a different question on the end came back with 4,675 tokens cached and 4.9 s of prefill, against about 220 s cold.

## Using the gateway

One authenticated OpenAI-compatible endpoint in front of a row's servers. Clients send the ids `llmq list` shows.

```fish
open-slop-gateway --catalogue CAT.json --keys KEYS [--host ADDR] [--port N] \
                  [--tls-cert FILE --tls-key FILE] [--plaintext-lan]
```

The keys file is `name key` per line. Keys are held as their sha256. Without TLS the gateway binds loopback only; a LAN bind needs certificates or the explicit `--plaintext-lan`.

What it refuses, rather than degrading without saying so: fields it cannot honour (tools, streaming, `n > 1`, images, audio) fail the decode by name; input past the model's window is a 400 before sending; a prompt count that reached the window is a 400 after; a schema-constrained answer that stopped at the token cap is a 400, because that JSON cannot be complete; a dead backend is a 502. Every refusal is an OpenAI error body, so a client built on the `openai` bindings surfaces the message.

Per backend: ollama gets `/api/chat` with the schema as `format`; llama-server gets its own `/v1/chat/completions`; hailo-ollama gets `/api/generate` and is refused any schema, because it cannot constrain output and reports no prompt count.

A message's `name` is written at the top of its content, because no local chat template shows the field to the model and Grace uses names to tell the required type from its last attempt and the compiler's complaint. `reasoning_effort` becomes ollama's `think` and llama-server's `chat_template_kwargs`. A union schema (`anyOf` alternatives with a constant tag, which is what Grace derives from a union type) passes through unchanged; checked 2026-10-16 with llama.cpp's own converter, the grammar it makes accepts every alternative and rejects anything else.

## Using llmq-grace

llmq's job machinery with a Grace stage in place of the prose prompt, and a typed value out.

```fish
llmq-grace --stage stages/reference-docs.ffg --gateway URL --key-file FILE \
           -m ROW/BACKEND/NAME -i INPUT [-o FILE] [-c BYTES] [-n] [--packed] [-r ID]
```

Each part produces `parts/NNNN.grace.json` (the typed value, which is what a later stage reads) beside `parts/NNNN.md` (rendered from it in Haskell, for a person). The stage's result type lives in the binary, so a `.ffg` whose annotation disagrees fails at load with the field named.

Two Grace facts that cost a day to find, both in HANDOFF section 10: `file` is a URI scheme in Grace's lexer, so a record label `file:` starts an import (the field is `path`); and `prompt`'s `model` is `Optional Text`, so the Haskell field is `Maybe Text`.

A third, found 2026-10-16: Grace's lexer tries the built-in type names (`List`, `Text`, `Optional`, `Natural` and the rest) before an alternative name, with no word boundary, so an alternative called `ListFiles` lexes as `List` followed by `Files` and the file does not parse. Record labels are not affected. The fix in Grace is a word boundary after those names.

`--agent-stage stages/agent-step.ffg` loads the agent's decision type, written in Grace, against the Haskell one, and with `--task` sends one step through the gateway and prints the decision Grace decoded.

## Asking your files: llmq-index

```fish
llmq-index ingest ~/notes ~/git
llmq-index ask "what port does the gateway listen on?"
llmq-index chat --session gateway
```

Your files are split along headings, embedded on the LAN, and stored in Postgres with pgvector on blade. A question is answered from a hybrid search, vector and full text fused by rank, so exact identifiers are found as well as paraphrases. As many sources as the model's capacity allows are packed in front of the question, the answer streams, and an answer that cites nothing or cites a source it was not given is flagged. A conversation is stored by name and can be continued from any machine that reaches the database; follow-up questions are rewritten to stand alone before searching. Every server text goes to is checked by type to be on loopback or the LAN before a request exists. The manual's [llmq-index page](docs/manual/09-llmq-index.md) compares it with private-gpt row by row.

## How much a model can take: capacity

Every program that decides how much to send (llmq-index, llmq-models' chat, llmq-agent) asks `OpenSlop.Capacity`. The window is llama-server's allocated context, or for ollama the smaller of the model's trained context and the catalogue's limit for that machine. Characters per token come from llmq-bench's measurement and are refined from the prompt counts servers report. `--max-wait` shrinks a prompt further by the measured prefill rate. Answers are never capped: ollama gets `num_predict: -2`, llama-server no `max_tokens`. See [Capacity](docs/manual/12-capacity.md).

## Working on code: llmq-agent

```fish
nix develop
llmq-agent --task "make parseDuration accept 90s and 1h30m"
llmq-agent --read-only --task "where does the gateway check the window?"
```

Each step, the model returns a decision: a short plan and one action from a closed set (browse a directory, read a file, search the index, look up library source, replace text, write a file, check the build, finish). The schema for that union is the same one Grace derives from `stages/agent-step.ffg`, so the server samples only valid decisions. The agent works in a git worktree on its own branch, `llmq-agent/<run>`, with one commit per edit, and never writes to your checkout. After every edit [tricorder](https://github.com/tweag/tricorder) rebuilds and runs the tests, and its report (errors first, with spans, then warnings, then failing cases) is the next observation. `LookupSource` reads any dependency's source offline from the documentation Nix already built. Finish after an edit is refused until the build is clean and the tests pass.

What it confines is what the model reads and writes. Compiling still runs the project's Template Haskell, any custom Setup and its tests, which the model may have written, so a task from someone you do not trust needs the run in a sandbox. The [llmq-agent page](docs/manual/13-llmq-agent.md) has the options, the tricorder flake input and its binary caches, and the log format; [the research write-up](docs/research/tricorder-and-grace.md) has why tricorder and what is left (PureScript over `purs ide server`, dependency source in the index, MCP).

## Developing

```fish
cd ~/git/open-slop
nix develop
cd haskell
cabal build --flag grace all
cabal test
```

The `grace` flag builds llmq-grace; without it the package is what the fleet gets.

After editing `haskell/open-slop.cabal`:

```fish
nix run .#cabal2nix
```

and commit `nix/open-slop.nix`, if its dependency list changed. The generator passes `--flag grace` so the dependency is listed, and strips the `configureFlags` line cabal2nix writes for it, so the flag stays off by default. The flake builds from that file, not from cabal2nix at evaluation time, so a consumer never needs import-from-derivation.

To test a change against the fleet:

```fish
git push
cd ~/neoblade-config
nix flake update open-slop
./build check
./build deploy-native oracle    # server-side changes
./build switch winsmuth         # client-side changes
```

## Where this goes

The point of the guardrails is that they make small models useful for jobs that normally need a frontier model. What follows is the shape of that, separated into what is measured, what is a design, and what is a bet.

### Typed stages as the unit of work

A stage is a Grace function from arguments the caller supplies to a result type the caller owns. That gives four properties at once, and they compose: the schema constrains decoding, Grace checks the answer against the type, the caller attaches every fact the model should not invent, and Haskell runs the loop, the retries and the checks that Grace deliberately cannot express (Grace has no recursion: every program terminates).

The immediate application is chase annotations, where the frontier model currently writes the notes the parser cannot derive. Split into three stages, that becomes: one call per signature for invariants, with the function's name attached by the parser rather than returned by the model; a deterministic render in Haskell; one call per module for decisions and open issues, retried against the drift checker. Nothing in chase's writer or checker changes. The design is not written up in this repository yet; HANDOFF section 6 has the open question it depends on.

### The prefix cache, measured

Stage one above sends the same module bundle in front of a different signature every time. That was a bet until 2026-09-26, when llama-server answered it: a 4,688-token bundle with a new question on the end reused 4,675 cached tokens and prefilled in 4.9 s, against about 220 s cold. llmq-claims is built on that result, and llmq-bench's `reuse` figure now measures it for every model on every backend, including whether ollama's cache holds between requests.

The same result decides whether Grace's `import prompt` is possible here at all: its 29 KB grammar is 25 minutes of prefill per call on oracle cold, and once per session with the cache.

### The NPU as a triage tier

hailo-ollama has no grammar-constrained decoding and reports no prompt count, so no typed stage can run on it. What it can do is a tiny prompt with a closed set of answers stated in the prompt, one or two words out, and a whitelist check in Haskell where anything unrecognised means "unknown". It is separate silicon, so it overlaps the CPU.

One rule makes that safe: **the NPU may only add work, never remove it.** An "unknown" or an off-list answer falls through to the expensive path. Under that rule the useful judgements are triage ("does this signature need a note beyond its type?"), a second opinion on one claim, and routing. Never facts the parser already has: purity, arity, what a function calls.

### Typed decisions without generation

The category worth watching is a model that does not generate at all: state plus typed questions in, a calibrated distribution per question out of one forward pass, with nothing to parse. Malformed output and invented options disappear by construction; being wrong does not. Open reproductions exist as encoder classifiers, and a DeBERTa-large-sized classifier is a fraction of a second per decision on four A76 cores at int8, with no decode loop and no 2,048-token window. That would make a better triage tier than a 1.5B generating the word "yes", and it needs no NPU.

An ONNX encoder is also the kind of model Hailo's compiler is actually built for, which is the only realistic path to using the NPU for something chosen rather than something Hailo shipped. It is a week with a proprietary x86 toolchain and a fixed sequence length baked into the HEF. Measure it on the CPU first.

A cheaper experiment in the same family, on a model already here: llama-server returns per-token logprobs, so a one-token answer read off the logits is a crude typed decision. The gateway refuses `logprobs` today; allowing it for the llamacpp backend is a small change.

### Fine-tuning, and what it would and would not buy

Filling a Grace-derived schema needs no Grace knowledge at all, so a fine-tune buys nothing for the pipeline above. Writing Grace needs the grammar in front of the model, and there the setup is unusually good because Grace is its own verifier: generate candidates, keep what type-checks, and the corpus needs no human labelling. A LoRA on a 7 to 8B would improve the odds that generated Grace type-checks. It would not change the rate curve, and at 0.5 to 0.7 tok/s at long context a wrong intermediate program still wastes every level under it.

Before any of that: cache the preamble, and shrink it. An ABNF-only variant with six worked examples might be 2 to 3K tokens instead of 8,000.

### One concrete fix waiting in the schema path

Grace's `toJSONSchema` emits record properties through a `Map`, so the schema's `properties` object is alphabetical while `required` keeps declaration order. Under grammar-constrained decoding the model writes fields in schema order, so the alphabet decides what it commits to first. That matters because constraining output can cost reasoning quality: the model has nowhere to think before committing. The fix inside a constrained schema is a scratch field the caller throws away, and it only helps if it is generated first, which means naming it to sort first (`analysis`, not `notes`). Two lines in the Grace type and the Haskell record. Whether it improves anything on a 7B is exactly what the golden set is for.

Measured 2026-10-16 with llama.cpp's converter: the order holds in the grammar, and inside a union alternative `contents` comes before `tag`, so the model fills in an action's fields before naming it. llmq-agent's decision type is named to sort sensibly (`plan` before `step`, `path` before `replace` before `with`). The reference-docs stage has not had the scratch field added yet.

### What none of this fixes

Each part is written with no view of the others, so relationships across files are missing by construction. A schema guarantees shape, not truth: in the first end-to-end run a 0.5B filled `interface` with the prompt's own category words and `reasoning` with a confident falsehood, and every layer reported success. The output is for a person to read.

## Status

Read docs/HANDOFF.md before touching anything. In brief:

- **Deployed and verified on oracle:** the three server backends (ollama with pinned GGUFs, hailo-ollama, llama-server with Qwen2.5-Coder 7B), llmq with real documentation jobs, llmq-claims.
- **Deployed on the clients:** llmq, llmq-models, llmq-bench, with measurements kept in each client's cache.
- **Measured:** every model oracle serves, on 2026-09-29, with one sample per figure on a board that was throttling. That run is what showed the need for protocol 3. The first protocol-3 run, from blade, is in progress.
- **Verified on winsmuth against a local model, not yet on the fleet:** the gateway, the Grace fork and llmq-grace.
- **Built and tested against test servers, not yet deployed:** llmq-index (needs `services.open-slop.rag` on blade and `nomic-embed-text` on oracle), the capacity rules, and llmq-agent (needs tricorder from its flake on winsmuth; not yet run against a real model or a real tricorder).
- **Does not exist:** a job queue or runner, the fleet CA the gateway needs, a golden set large enough to judge prompt changes, a streaming or retrieval route on the gateway, a web UI, a PureScript build oracle, and an MCP client.

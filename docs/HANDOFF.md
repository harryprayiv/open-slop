# open-slop: handoff

Written 2026-09-19. Nothing in this repository has run on the fleet. Every
claim below says whether it was tested in a sandbox against mock servers,
evaluated in an oracle-shaped NixOS configuration, or only written.

## 1. What this is

open-slop is the tooling for running and using a Nix-configured local LLM
machine. It began as one script (llmq) in neoblade-config and is now a
standalone flake repo, imported by neoblade-config as an input, with a
Haskell library at its centre. The machine it targets today is oracle, a
Raspberry Pi 5 (16 GB) with a Hailo-10H NPU, at 192.168.8.173.

Goal, as stated: the canonical way to run and talk to such a machine, usable
and iterated on without a person at a terminal, with the parts that must not
be wrong written in Haskell.

## 2. State of the code

### TESTED against mock servers (sandbox, GHC 9.4.7)

- open-slop.Catalogue: catalogue types and budget arithmetic. The budget formula
  matches the earlier Nix one, so parts cut by the retired bash llmq and by
  this one are identical.
- open-slop.Chunk: the chunker. Property tests pass. On a 1.1 MB catsrc dump it
  produced the same 34-part manifest as the retired awk chunker, byte for
  byte, with exact reassembly.
- open-slop.Engine: Request as a sum type per engine (Ollama, HailoOllama,
  LlamaServer); reply parsing for NDJSON, single objects and SSE; tags
  parsing for /api/tags and /v1/models.
- open-slop.Http: TLS-capable client, streaming line reader, Either for
  transport failures, bearer auth already wired for the future gateway.
- open-slop.Stats: truncation verdict and warnings.
- open-slop.Job: on-disk job layout, content-addressed id, rename-into-place
  for parts and the assembled document, flock.
- app/llmq (Main, Menu, Run): list, jobs, ask, run.

Scenarios that passed against mock ollama, hailo-ollama and llama-server:
list with live and dead endpoints; ask on all three; dry run; a multi-part
job interrupted with SIGTERM and resumed by id and by re-running the same
command; the lock refusing a second runner; ollama truncation failing a part
with a "resuming will fail the same way" message; llama-server's own
truncated flag failing a part the same way; a stream with no final line;
HTTP 500 with an error body; per-request timeout; warnings exit 2; hailo
request bodies limited to model, prompt, stream; llama-server bodies with no
model or options field.

Not tested: the fzf menu in this build (it was tested under a pty in the bash
version; the Haskell one shells out identically). Anything on real hardware.

### EVALUATED in an oracle-shaped NixOS configuration (nixos-unstable)

- nix/modules/options.nix, server.nix, pinned.nix, hailo.nix,
  llama-server.nix, catalogue-check.nix. With server, hailo and llamaServer
  enabled: correct firewall rules for both ports, OLLAMA_CONTEXT_LENGTH=16384
  and OLLAMA_NUM_PARALLEL=1 on the ollama unit, the pinned-models and
  hailo-pull scripts, statePaths listing both weight directories, the
  llama-server unit not wanted by multi-user.target, no warnings, no failed
  assertions. With everything disabled: no units, no warnings, no paths.
- catalogue-check: an undeclared model produces the warning; editing the
  hailo port through catalogue.extra fails the assertion.
- nix/packages/llama-cpp-prismml.nix instantiates against the fork's source
  at f0a2b5d. It has NOT been built.

### WRITTEN only

- flake.nix. Parses; the non-system outputs evaluate with stub inputs. The
  per-system outputs (packages, devShell) have not been evaluated because
  the sandbox has no flake support. The Grace overlay usage copies chase's.
- nix/open-slop.nix: hand-written in cabal2nix's shape. `nix run .#cabal2nix`
  regenerates it; run that once and diff.
- nix/modules/client.nix: home-manager; never evaluated under home-manager.
- nix/packages/bonsai-weights.nix: lib.fakeHash placeholders. The 27B file
  names are from the model card; the 8B file name is a guess.
- The catalogue's llamacpp backend and its two Bonsai entries: every number
  is marked unmeasured.

### Does not exist

- The gateway (open-slop-gateway), the runner (open-slop-runner), a Haskell mock
  server, their NixOS modules, the VM tests.
- The Grace fork. The flake pins upstream Grace as an input so the package
  builds; it still talks to api.openai.com.
- Any measurement of Bonsai on oracle.
- The neoblade-config side: input, module imports, services.open-slop settings
  on oracle's row, programs.llmq on the lab role. README shows the shape.

## 3. Architecture, as decided

Three repos and one machine:

- neoblade-config knows machines: addresses, which backends a row runs,
  secret file paths, firewall source ranges, notification target, Forgejo
  repo. It imports open-slop and sets services.open-slop.* and programs.llmq.*.
- open-slop knows backends, models, engines, keys and jobs. It contains no
  address and no fleet name. Its catalogue is data; a fleet adds entries
  through services.open-slop.catalogue.extra.
- The Grace fork, pinned as a flake input of open-slop, for typed pipelines.

open-slop's binaries, all from one library:

- llmq: the client. Exists.
- open-slop-gateway: one LAN port on oracle, TLS with a fleet CA, bearer keys
  per client, fronts ollama, hailo-ollama and llama-server as one
  OpenAI-shaped endpoint, injects per-model window and sampling from the
  catalogue, rejects truncated prompts, retries transient failures, records
  rates, logs the model name. This is "option C"; it absorbs items 6, 9, 11,
  16, 17 and 34.
- open-slop-runner: on oracle. Spool directory, one systemd unit per job,
  cancel via systemctl stop, notifications through Home Assistant, results
  as Forgejo pull requests, ssh with a forced-command key as the only remote
  interface.

The catalogue: backends carry engine, port, streams, acceptsOptions, ctx,
predict, promptOverhead, charsPerToken, temperature, blurb. Models carry
summary, docFit, optional ctx/predict overrides, tokPerSec (measured only),
licence, blurb. Budget per request is
floor((ctx - predict - promptOverhead) * charsPerToken) bytes. A job's id
hashes the budget, so a catalogue change starts new jobs and never re-cuts
an existing one.

## 4. Decisions taken, with the reason

- Haskell for everything that holds state. Part states, retries, three
  engine dialects and pipelines are state machines.
- nixpkgs' Haskell infrastructure with one pinned compiler, following the
  chase flake, with the derivation committed instead of callCabal2nix so
  the consumer evaluates without import-from-derivation.
- Input never comes from a terminal paste (4095-byte line limit).
- Truncation is a failure, not a warning. Ollama drops the front of an
  oversized prompt, where the instruction is, and answers 200. llama-server
  reports truncation itself and that flag is honoured.
- The NPU gets model, prompt, stream:false and nothing else. The Request
  type has no field to put anything else in for that engine.
- The hailo port is described in the catalogue and pinned by an assertion.
- Server-side defaults OLLAMA_CONTEXT_LENGTH and OLLAMA_NUM_PARALLEL=1 come
  from the catalogue, so clients on the OpenAI-compatible route get the
  same window llmq asks for and nothing reloads a model for a changed
  window.
- Gateway as Haskell rather than nginx: per-model context injection and
  dialect translation cannot be done in nginx.
- Pipelines are fixed workflows, not autonomous agents.
- Bonsai PQ2_0 before PTQ1_0 on ARM: the fork has a NEON kernel for PQ2_0
  and a generic fallback for PTQ1_0.
- llama-server not resident by default: 7 GB held for as long as it runs.
- statePaths is an output option; open-slop has no opinion about impermanence.

## 5. Improvement list: status

Numbers are the ones used throughout the design conversation.

Phase 0 (measure): 43 package the fork (written); 44 pin weights (written,
hashes empty); 45 llama-server unit (written, evaluated); 47 measure on
oracle; 48 golden-set comparison. 47 and 48 not started.

Phase 1 (Haskell core): 29 rewrite (client done); 33 server defaults (done,
evaluated); 1 backends declared per row (done: programs.llmq.endpoints and
services.open-slop.*.enable are the declaration); 3 no instruction prompt on
dry run (done) and instruction size checked against promptOverhead (NOT
done); 19 git ls-files input with excludes (NOT done); 21 named prompts
(prompts/ exists, selection by name NOT done); 46 third engine (done).

Phase 2 (gateway): 6, 9, 11, 16, 17, 34 and the API-key design. None written.

Phase 3 (unattended): 12 runner; 7 cancel; 8 rm and gc; 13 notifications;
14 Forgejo PRs; 31 VM tests. None written.

Phase 4 (quality, speed): 30 golden tests; 26 mechanical identifier check
then model check; 28 structured output; 18 per-file cache; 20 reduction
pass; 22 budgets from measurement; 50 Bonsai self-verification. None
written.

Grace: 32 fork for base URL; 35 call cache; 36 pin (done, upstream); 42
verify schema support on ollama's compat route; 37 llmq runs Grace
programs; 49 import prompt trials after 48. Only 36 started.

Dropped: 2, 4, 5 (became `llmq ask`, done), 10, 15, 24, 27, 38, 39, 40, 41
(decided: C), Grace's 34.

## 6. Open questions that block specific work

1. hailo-ollama 5.1.1: does it accept an options field, or answer 500?
   Blocks acceptsOptions for the NPU.
2. hailo-ollama streaming output shape. Blocks streams = true for the NPU.
3. hailo-ollama context: is 2048 the window, and what happens past it?
   Blocks the NPU budget, currently an assumption.
4. The shape of hailo-ollama.json. Blocks replacing the port literal with a
   build-time check, and the gateway's loopback-bind design.
5. Does disconnecting the client stop generation on ollama during prefill,
   and on hailo-ollama at all? Blocks cancel semantics.
6. Does ollama 0.33.3's /v1/chat/completions accept response_format with a
   json_schema? Blocks Grace against ollama.
7. Does hailo-ollama serve any OpenAI-compatible route? Blocks the NPU
   behind the gateway.
8. Is secrets.nix in neoblade-config sops-nix or agenix? Blocks key
   distribution.
9. Bonsai on a Pi 5: prefill and decode for PQ2_0 27B and for the 8B.
   Blocks the entire Bonsai plan.
10. GHC builds for aarch64 in reasonable time. See section 7.
11. The real Bonsai 8B file name, and all three weight hashes.

Probes 1 to 4, from winsmuth against oracle:

    curl -s http://192.168.8.173:8000/api/generate -H "Content-Type: application/json" -d '{"model":"qwen2.5-instruct:1.5b","prompt":"Say OK.","stream":false,"options":{"num_predict":8}}' | jq '{error, eval_count, response}'
    curl -sN http://192.168.8.173:8000/api/generate -H "Content-Type: application/json" -d '{"model":"qwen2.5-instruct:1.5b","prompt":"Say OK.","stream":true}' | head -n 3
    jq -n --arg p (string repeat -n 4000 'apple ') '{model:"qwen2.5-instruct:1.5b", prompt:("Reply with the single word OK. " + $p), stream:false}' | curl -s --data-binary @- -H "Content-Type: application/json" http://192.168.8.173:8000/api/generate | jq '{error, prompt_eval_count, eval_count, response}'
    ssh bismuth@192.168.8.173 'jq . /run/current-system/sw/etc/xdg/hailo-ollama/hailo-ollama.json'

## 7. Pipe dreams and unrealistic goals

Called out so they are not mistaken for plans.

### Bonsai 27B as a frontier stand-in on a Pi 5

The announcement compares Bonsai to hosted models on quality and reports
throughput on GPUs and Apple Silicon. Oracle has neither. Decode is bound by
memory bandwidth: 7.2 GB of PQ2_0 weights per token over roughly 12 GB/s of
practical LPDDR4X bandwidth gives a ceiling near 2 tok/s and a realistic
figure near 1. That is slower than llama3.1:8b's measured 1.7. Prefill is
compute-bound; the 27B does about 3.4 times the arithmetic of an 8B, and a
16K prompt is plausibly 20 to 50 minutes before the first output token.
Thinking mode at the default xhigh effort adds an hour of reasoning tokens
per part at that rate, which is why the unit passes --reasoning off.

Realistic outcome: the 27B is a nightly batch model for a handful of
whole-directory jobs, or it is too slow to use, and the 8B is the working
model. Nothing should be restructured around Bonsai until item 47 has
numbers. The catalogue entries say "unmeasured" and "unknown" for that
reason.

### The 262K context window

A memory fact, not a usable one. Hybrid attention makes a long context
cheap to hold and does nothing for prefill on four A76 cores. Expect 32K to
be the practical ceiling on oracle, and only for jobs that can wait. The
catalogue's llamacpp ctx is 32768 for that reason, not 262144.

### Grace's `import prompt` on local models

Grace can ask a model to write Grace code and type-check the result. There
is essentially no Grace in any model's training data; Grace ships a grammar
and a language description into the prompt to compensate, a large block out
of the window. Bonsai's coding scores make this plausible to try. It is not
a plan. A wrong intermediate program wastes every level under it, and each
level costs minutes to an hour. REPL and golden tests only, depth one.

### Autonomous sub-agents

Frameworks that let the model choose its next step and call tools assume a
model that does so reliably. None of the models on this fleet do. Every
pipeline here is a fixed list of stages declared in data.

### Trustworthy documentation from a chunked pass

Each part is written with no view of the others. Relationships across files
are missing from the output by construction. Bonsai's larger window and the
two-pass context idea reduce this; nothing eliminates it short of feeding
the whole repo at once, which the hardware cannot do in useful time.
Verification raises trust without guaranteeing it: a 27B verifier misjudges
too, and a schema guarantees shape, not truth. The only real check is a
human reading the pull request.

### The NPU for documentation

Under 3 KB of input per request at 1.5B to 3B parameters produces restated
input and invented detail. The NPU is for classification, extraction and
one-line labels, and for running beside the CPU. The catalogue rates every
NPU model poor or unsuitable; that is judgement, and item 48 turns it into
evidence, but the direction will not change.

### Reproducible outputs

Temperature 0 and a fixed seed make ollama deterministic for one build on
one machine with one thread count. They do not survive an ollama version
bump, a kernel change or a different CPU. Treat identical output across
time as a convenience that will break occasionally.

### "Canonical for any Nix-configured LLM machine"

Every option and every catalogue entry so far is shaped by one machine. The
boundary rule (open-slop knows no address, no fleet name) is designed for
generality, but generality that has met one machine is a guess. The second
machine with a different GPU, engine or architecture will find the
assumptions. Do not advertise the repo as general before it.

### Iterating entirely from a phone

The runner, notifications and PRs make submit, cancel and review possible
from a phone. What remains is judgement: reading the output, deciding a
prompt change, choosing a model. The runner removes the terminal from the
loop; it does not remove the person.

### Time estimates

The dry run's estimate counts output only. The running estimate scales by
bytes done. Neither includes prefill, which dominates on the Pi. Item 16
records real rates so item 4's replacement can be built; until then every
estimate is optimistic.

### The gateway as security

Bearer keys over TLS on a LAN stop other LAN devices from using oracle and
give per-client identity and revocation. They do not protect against the
user's own machine (the key is in a user-readable file, same standing as an
ssh key) and do not protect the servers from root on oracle. Locally the
servers stay unauthenticated on loopback. That is the correct scope.

### GHC binaries for aarch64 without pain

The runner and the gateway run on oracle, so they are aarch64 binaries.
GHC under qemu-user on an x86 builder is very slow for a project this size,
and a native build on the Pi is slow too. Options: native build on oracle
with the nixpkgs binary cache supplying GHC and the libraries; a remote
aarch64 builder; cross-compilation. None tried. This is the most likely
source of a lost weekend and should be tried with llmq before the gateway
is written. The dev shell and packages use nixpkgs' Haskell set, which the
cache covers for aarch64-linux on most of these libraries.

## 8. Risks that are real but ordinary

- Deploying oracle during a job restarts ollama and kills the part. Until
  the gateway retries, do not deploy during a run.
- winsmuth sleeps; a job started there dies with it. Use systemd-run --user
  until the runner exists, and keep the state directory on a persisted
  path on blade.
- A long custom instruction is not measured against promptOverhead. A big
  -P file will overflow and fail parts as truncated.
- Generated files (a glyph table took 8 of 34 parts) inflate jobs. Run
  catsrc per subdirectory until item 19's excludes exist.
- The neoblade-config side of the switch (README shape) has not been
  written: input, rowModule imports, roles.llm replaced by services.open-slop.*,
  the lab role enabling programs.llmq with endpoints built from targets.nix,
  homelab.persist.system fed from statePaths. Its old llm modules must be
  deleted in the same commit or the two module sets both define
  services.ollama.
- Two stale strings in neoblade-config say roles.llm.backend (singular);
  docs/hailo.md section 13 and the version assertion in hailo.nix disagree
  about firmware; the flake.nix comment on configurationRevision is wrong.

## 9. Order of work

1. Push this repo. In neoblade-config: add the input, import the modules,
   replace roles.llm with services.open-slop.* on oracle's row, delete the old
   llm modules, enable programs.llmq on the lab role. ./build check.
2. `nix run .#cabal2nix` and diff against the committed nix/open-slop.nix.
3. Build llmq for winsmuth. Run `llmq list` against the real oracle. Run
   probes 1 to 4.
4. Build llmq for aarch64 and time it (section 7).
5. Phase 0: build the fork, fill the weight hashes, deploy the llama-server
   unit, run llama-bench, fill docs/measurements.md.
6. Gateway, with a Haskell mock and the VM test.
7. Runner, with cancel, notifications, PRs, VM test.
8. Golden set, then quality items in order 26 mechanical, 28, 18, 25.
9. Grace fork and trials.

## 10. What to look at first when something is wrong

- A part failed as truncated: the budget is too large for that model's real
  bytes-per-token. Check the observed figure printed after earlier parts.
  Start a new job with a smaller --chunk-bytes; resuming will fail again.
- A stream ended without a final line: the server restarted, the network
  dropped, or --timeout fired. failed/NNNN.raw has whatever arrived.
- "already running in another llmq": a runner holds the lock. flock
  releases on process exit, so this only happens with a live process.
- No answer from an endpoint: the probe uses an 8-second ceiling and the
  tags route, which does not load a model. A failure means the server is
  down or the port is wrong.
- Output shows U+FFFD: a line longer than the whole budget was cut inside a
  multibyte character (chunker rule 3).
- catalogue-check warns about a model: add an entry under models.<backend>
  in catalogue/default.nix or services.open-slop.catalogue.extra.

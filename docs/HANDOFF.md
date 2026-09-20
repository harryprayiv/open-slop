# open-slop: handoff

Written 2026-09-19, revised 2026-09-20 (evening). Every claim says whether
it was tested against mock servers, evaluated in an oracle-shaped NixOS
configuration, verified against the real fleet, or only written.

## 1. What this is

open-slop is the tooling for running and using a Nix-configured local LLM
machine. It began as one script (llmq) in neoblade-config and is now a
standalone flake repo at ~/git/open-slop, imported by neoblade-config as an
input, with a Haskell library at its centre. The machine it targets today is
oracle, a Raspberry Pi 5 (16 GB) with a Hailo-10H NPU, at 192.168.8.173.

Goal, as stated: the canonical way to run and talk to such a machine, usable
and iterated on without a person at a terminal, with the parts that must not
be wrong written in Haskell.

## 2. State of the code

### VERIFIED against the real fleet (2026-09-19 and 2026-09-20)

- Deployed. oracle runs generation 40, built ON oracle (kernel
  linux-rpi 6.18.50, nixpkgs 20b1ddd), through `./build deploy-native
  oracle` and made the boot default with `boot-native`. All four units
  active: ollama with OLLAMA_CONTEXT_LENGTH=16384 and OLLAMA_NUM_PARALLEL=1,
  ollama-pinned-models (sully registered, through the API, under a dynamic
  user), hailo-ollama, hailo-ollama-models (five models present).
- oracle is the fleet's aarch64 builder. neoblade's `builder` role is on its
  row, `builder-client.nix` on the lab rows offers it aarch64 builds, and
  the daemon route works: `nix store info --store
  'ssh-ng://root@192.168.8.173?ssh-key=/var/lib/nix-builder/key'` answers
  Trusted: 1 from winsmuth's root. `nix build
  .#packages.aarch64-linux.llmq --option extra-platforms ""` built llmq on
  oracle and copied it back.
- The seed unit stamps by zoo version, not store path, and the pull unit
  skips models `/api/tags` already lists: a re-activation after both fixes
  logged five "already present" lines and took four seconds, where the
  activation before them re-pulled 9 GB (twelve minutes).

- The integration into neoblade-config: open-slop is a flake input, its
  overlay is on the fleet's overlay list, its NixOS modules are imported on
  every row and enabled on oracle by `llm.backends` in targets.nix, its
  home-manager module is enabled by the lab role with endpoints built from
  targets.nix. `roles.llm` is gone from roles.nix. `llmq list` on winsmuth
  reaches oracle with no environment set by hand.
- llmq against oracle: `list` on both endpoints; `ask` on the NPU and on
  the CPU (qwen2.5-coder:7b, 2.0 tok/s on a 19-token answer).
- hailo-ollama 5.1.1, measured: streams in ollama's line shape; honours
  options.num_predict; reports done_reason, total_duration and eval_count
  on its final line and no prompt_eval_count and no eval_duration; window
  is 2048 (answer at about 1900 prompt tokens, garbage with HTTP 200 at
  about 2100, HTTP 500 with a plain-text body at 4000). Its config JSON is
  `{server: {host, port}, library: {host, port}, main_poll_time_ms}`.
- Four undeclared models were on oracle's card (gemma2:2b, phi3:latest, two
  TheBloke GGUFs, 11.3 GB); removed. The declared three plus sully remain.

### TESTED against mock servers

- The library and llmq: Catalogue, Chunk, Engine (three engines), Http,
  Stats, Job; Main, Menu, Run. Property tests pass. The chunker produced
  the same 34-part manifest as the retired awk chunker on a 1.1 MB dump.
- Scenarios: list with live and dead endpoints; ask on all three engines;
  dry run; a job interrupted with SIGTERM and resumed by id and by re-run;
  the lock; ollama truncation; llama-server's own truncated flag; a stream
  with no final line; HTTP 500 with a JSON body; HTTP 500 with a plain-text
  body; per-request timeout; warnings exit 2; hailo request bodies limited
  to model, prompt, stream, options.num_predict; llama-server bodies with
  no model or options; -P by name, by path, with a bad name, and the
  shipped default instruction.
- Builds clean under GHC 9.6.7 in the nix develop shell on winsmuth, and
  through `nix build .#llmq` from the committed nix/open-slop.nix.

### EVALUATED in an oracle-shaped NixOS configuration

- options, server, pinned, hailo, llama-server, catalogue-check, and the
  neoblade side (llm.backends producing the enable flags, statePaths feeding
  homelab.persist.system). catalogue-check's warning and the hailo port
  assertion both fire when provoked.
- nix/packages/llama-cpp-prismml.nix instantiates. NOT built.

### WRITTEN only

- nix/packages/llama-cpp-prismml.nix: instantiates, never built.
- nix/modules/llama-server.nix: evaluates, never activated; `llamacpp` is
  not in oracle's `llm.backends`.
- nix/packages/bonsai-weights.nix: lib.fakeHash placeholders; the 8B file
  name is a guess.
- The catalogue's llamacpp backend and Bonsai entries: unmeasured.
- The `dontHaddock` change to the shipped binaries in flake.nix: committed,
  its build not yet timed.

### Does not exist

- The gateway, the runner, a Haskell mock server, their NixOS modules, the
  VM tests, the API-key scheme.
- The Grace fork. The flake pins upstream Grace and builds it; it still
  talks to api.openai.com.
- Any measurement of Bonsai on oracle.

## 3. Architecture, as decided

- neoblade-config knows machines: addresses, which backends a row runs
  (`llm.backends` in targets.nix), secret file paths, firewall ranges. It
  imports open-slop and sets services.open-slop.* and programs.llmq.*.
- open-slop knows backends, models, engines, keys and jobs. It contains no
  address and no fleet name. Its catalogue is data; a fleet adds entries
  through services.open-slop.catalogue.extra.
- Binaries, all from one library: llmq (exists); open-slop-gateway (one LAN
  port on oracle, TLS with a fleet CA, bearer keys per client, fronts all
  three servers as one OpenAI-shaped endpoint, injects per-model window and
  sampling, rejects truncated prompts, retries transient failures, records
  rates); open-slop-runner (on oracle: spool, one systemd unit per job,
  cancel via systemctl stop, notifications through Home Assistant, results
  as Forgejo pull requests, ssh with a forced-command key as the only
  remote interface).
- The catalogue: backends carry engine, port, streams, acceptsOptions, ctx,
  predict, promptOverhead, charsPerToken, temperature, blurb; models carry
  summary, docFit, optional ctx/predict, tokPerSec (measured only), licence,
  blurb. Budget per request is floor((ctx - predict - promptOverhead) *
  charsPerToken) bytes. A job's id hashes the budget.
- Prompts are files under prompts/, shipped with the package; llmq resolves
  `-P NAME` against $OPEN_SLOP_PROMPTS and uses reference-docs.md by default.

## 4. Decisions taken, with the reason

- Haskell for everything that holds state.
- nixpkgs' Haskell set with one pinned compiler, the derivation committed at
  nix/open-slop.nix and regenerated with `nix run .#cabal2nix`, so the
  consumer evaluates without import-from-derivation.
- The consumer adds the overlay and imports the modules; the modules do not
  set nixpkgs.overlays, because home-manager under useGlobalPkgs rejects it.
- Input never comes from a terminal paste (4095-byte line limit).
- Truncation is a failure. ollama drops the front of an oversized prompt
  and answers 200; llama-server reports it and the flag is honoured;
  hailo-ollama reports nothing and answers garbage with 200, so on the NPU
  the byte budget is the only guard and sits at half the window.
- The NPU gets model, prompt, stream and options.num_predict, because each
  was measured to work, and nothing else, because nothing else was.
- The hailo port is described in the catalogue and pinned by an assertion.
  The config JSON's shape is now known, so a build-time check reading
  `.server.port` can replace the literal.
- OLLAMA_CONTEXT_LENGTH and OLLAMA_NUM_PARALLEL=1 are set from the catalogue.
- Gateway as Haskell rather than nginx.
- Pipelines are fixed workflows, not autonomous agents.
- Bonsai PQ2_0 before PTQ1_0 on ARM (NEON kernel versus generic fallback).
- llama-server not resident by default.
- statePaths is an output option; open-slop has no opinion about
  impermanence.
- oracle builds its own aarch64 closure. neoblade-config's builder role is
  on oracle, builder-client.nix on the lab rows offers aarch64 builds to it,
  and `./build deploy-native oracle` builds on the target by construction.
  winsmuth keeps binfmt, so plain `./build deploy oracle` still starts
  emulating; deploy-native is the path for oracle, and for an ad-hoc build
  `--option extra-platforms ""` sends every aarch64 derivation to the
  builder (`--max-jobs 0` does not: nixpkgs' Haskell builder makes
  preferLocalBuild wrapper scripts that can never go remote).
- The pinned-models unit registers through the API under its own
  DynamicUser. `ollama create` uploads the GGUF through /api/blobs; the
  unit never needed the server's user or its models directory, and the
  nixpkgs module stopped creating an `ollama` user, which broke the old
  form on 2026-09-20.
- The Hailo seed stamp is the zoo VERSION. A store path changes with every
  nixpkgs bump and wiped 9 GB of blobs for a rebuild of the same 5.1.1.
- The Hailo pull unit checks /api/tags first. /api/pull re-downloads a
  model the server already has.

## 5. Improvement list: status

Phase 0 (measure): 43 package the fork (written); 44 pin weights (written,
hashes empty); 45 llama-server unit (written, evaluated); 47 measure on
oracle; 48 golden-set comparison. 47 and 48 not started. Unblocked now that
oracle builds natively.

Phase 1 (Haskell core): 29 rewrite (client done); 33 server defaults
(done, deployed); 1 backends declared per row (done, verified); 3 no
instruction prompt on dry run (done), instruction size against
promptOverhead (NOT done); 19 git ls-files input with excludes (NOT done);
21 named prompts (DONE: prompts/ shipped, -P by name, shipped default);
46 third engine (done, mock-tested).

Phase 2 (gateway): 6, 9, 11, 16, 17, 34 and the API-key design. None
written. Question 4's answer (the JSON's host field) is the loopback-bind
lever for it.

Phase 3 (unattended): 12 runner; 7 cancel; 8 rm and gc; 13 notifications;
14 Forgejo PRs; 31 VM tests. None written.

Phase 4 (quality, speed): 30 golden tests; 26 mechanical check then model
check; 28 structured output; 18 per-file cache; 20 reduction pass; 22
budgets from measurement; 50 Bonsai self-verification. None written. 30
is now the gate on every prompt change.

Grace: 32 fork for base URL; 35 call cache; 36 pin (done, follows
nixpkgs); 42 verify schema support on ollama's compat route; 37 llmq runs
Grace programs; 49 import prompt trials after 48.

Dropped: 2, 4, 5 (became `llmq ask`), 10, 15, 24, 27, 38, 39, 40, 41,
Grace's 34.

## 6. Open questions

Answered on 2026-09-19 (see section 2): the hailo options field, streaming
shape, window, and config JSON shape.

Still open:

1. Does disconnecting the client stop generation on ollama during prefill,
   and on hailo-ollama at all? Blocks cancel semantics.
2. Does ollama 0.33.3's /v1/chat/completions accept response_format with a
   json_schema? Blocks Grace against ollama.
3. Does hailo-ollama serve any OpenAI-compatible route? Blocks the NPU
   behind the gateway.
4. Is secrets.nix in neoblade-config sops-nix or agenix? It is sops-nix
   (neoblade's flake carries the sops-nix input and secrets.nix resolves a
   per-hostname file), so this is answered: key distribution uses sops
   templates.
5. Bonsai on a Pi 5: prefill and decode for PQ2_0 27B and for the 8B.
   Blocks the entire Bonsai plan.
6. ANSWERED 2026-09-20: the library plus llmq built natively on oracle in
   roughly ten to twelve minutes wall at nix.settings.cores = 2, haddock
   included, with every dependency substituted from cache.nixos.org. The
   figure is rough because the build was cancelled and restarted once. The
   dontHaddock build has not been timed. hosts/oracle.nix's `max-jobs = 2;
   cores = 2` is the wrong shape for one build at a time beside inference;
   `max-jobs = 1; cores = 4` is the change to make there.
7. The real Bonsai 8B file name, and all three weight hashes.
8. Whether hailo-ollama honours `server.host` from a copy of its JSON in
   $XDG_CONFIG_HOME, which is what would bind it to loopback for the
   gateway.

## 7. Pipe dreams and unrealistic goals

Called out so they are not mistaken for plans.

### Bonsai 27B as a frontier stand-in on a Pi 5

Decode is bound by memory bandwidth: 7.2 GB of PQ2_0 weights per token over
roughly 12 GB/s gives a ceiling near 2 tok/s and a realistic figure near 1,
slower than llama3.1:8b's measured 1.7. Prefill is compute-bound; a 16K
prompt is plausibly 20 to 50 minutes before the first output token.
Thinking mode at the default effort adds an hour of reasoning tokens per
part, which is why the unit passes --reasoning off. Realistic outcome: a
nightly batch model for whole-directory jobs, or too slow to use, with the
8B as the working model. Nothing is restructured around Bonsai until item
47 has numbers.

### The 262K context window

A memory fact. Hybrid attention makes a long context cheap to hold and does
nothing for prefill on four A76 cores. The catalogue's llamacpp ctx is
32768 for that reason.

### Grace's `import prompt` on local models

There is essentially no Grace in any model's training data; Grace ships a
grammar and a language description into the prompt to compensate. Bonsai's
coding scores make this plausible to try. A wrong intermediate program
wastes every level under it, and each level costs minutes to an hour. REPL
and golden tests only, depth one.

### Autonomous sub-agents

None of the models on this fleet plan or call tools reliably. Every
pipeline here is a fixed list of stages declared in data.

### Trustworthy documentation from a chunked pass

Each part is written with no view of the others. Relationships across files
are missing from the output by construction. Verification raises trust
without guaranteeing it: a 27B verifier misjudges too, and a schema
guarantees shape, not truth. The only real check is a human reading the
pull request.

### The NPU for documentation

Under 3 KB of input per request at 1.5B to 3B parameters produces restated
input and invented detail, and the server cannot tell llmq when a prompt
overflowed. The NPU is for classification, extraction and one-line labels,
and for running beside the CPU.

### Reproducible outputs

Temperature 0 and a fixed seed make ollama deterministic for one build on
one machine with one thread count. They do not survive an ollama version
bump, a kernel change or a different CPU.

### "Canonical for any Nix-configured LLM machine"

Every option and every catalogue entry so far is shaped by one machine. The
second machine with a different GPU, engine or architecture will find the
assumptions. Do not advertise the repo as general before it.

### Iterating entirely from a phone

The runner, notifications and PRs make submit, cancel and review possible
from a phone. What remains is judgement. The runner removes the terminal
from the loop; it does not remove the person.

### Time estimates

The dry run's estimate counts output only; the running estimate scales by
bytes done; neither includes prefill, which dominates on the Pi. Every
estimate is optimistic until item 16 records real rates.

### The gateway as security

Bearer keys over TLS on a LAN stop other LAN devices from using oracle and
give per-client identity and revocation. They do not protect against the
user's own machine or against root on oracle. Locally the servers stay
unauthenticated on loopback.

### A prompt change as an improvement

Until the golden set exists, a prompt edit is a change to every job's
output with no evidence either way. The rewritten reference-docs.md is
written to your stated needs and is unmeasured like the one before it.

## 8. Risks that are real but ordinary

- Deploying oracle during a job restarts ollama and kills the part. Until
  the gateway retries, do not deploy during a run.
- winsmuth sleeps; a job started there dies with it. Use systemd-run --user
  until the runner exists.
- A long custom instruction is not measured against promptOverhead. A big
  -P file will overflow and fail parts as truncated. The rewritten
  reference-docs.md is about 1.8 KB, within the 512-token reservation.
- Generated files (a glyph table took 8 of 34 parts) inflate jobs. Run
  catsrc per subdirectory until item 19's excludes exist.
- /var/lib/nix-builder/key on winsmuth is outside every persistence
  manifest; it needs a homelab.persist.system entry in hosts/winsmuth.nix
  before Phase B lands, or every wipe breaks Pi deploys.
- With binfmt still on winsmuth, `./build deploy oracle` emulates; use
  `./build deploy-native oracle`. Dropping binfmt is a deliberate edit to
  hosts/winsmuth.nix and has not been made.
- Anything longer than a minute runs under `systemd-run --user --collect
  --unit=NAME`. A foreground nix client that is Ctrl-C'd cancels the build
  on the builder too; Ctrl-Z then `bg; disown` keeps it alive.
- `services.ollama.loadModels` runs `ollama pull` at every activation. For
  a present model that is a registry check and a manifest timestamp, not a
  download; `ollama list` dates move on every deploy for that reason.
- Models pulled by hand on oracle are undeclared state. Three appeared on
  2026-09-19 and one reappeared on 2026-09-20; both times removed with
  `ollama rm`. The ollama journal names the client address of every pull.
- Two stale strings in neoblade-config say roles.llm.backend (singular);
  docs/hailo.md section 13 and the version assertion in hailo.nix disagree
  about firmware; the flake.nix comment on configurationRevision is wrong.

## 9. Order of work

Steps 1 and 2 of the previous list are done (native deploy, builder route,
first aarch64 timing).

1. Phase 0: fill the three weight hashes in nix/packages/bonsai-weights.nix
   (first build fails with the real hash), add "llamacpp" to oracle's
   `llm.backends`, `./build deploy-native oracle`, then under systemd-run on
   oracle: `llama-bench` per docs/measurements.md. Fill that file.
2. Run open questions 1 to 3 and 8 (curl and one config copy on oracle).
3. Gateway, with a Haskell mock and the VM test. Developed with cabal on
   winsmuth; built for oracle through the builder only when deploying.
4. Runner, with cancel, notifications, PRs, VM test.
5. Golden set, then quality items in order 26 mechanical, 28, 18, 25.
6. Grace fork and trials.

## 10. What to look at first when something is wrong

- A part failed as truncated: the budget is too large for that model's real
  bytes-per-token. Check the observed figure after earlier parts. Start a
  new job with a smaller --chunk-bytes; resuming will fail again.
- A stream ended without a final line: the server restarted, the network
  dropped, or --timeout fired. failed/NNNN.raw has whatever arrived.
- "the response is not JSON: server=oatpp": hailo-ollama refused an
  oversized prompt. The part's chunk is over the NPU's real window.
- "already running in another llmq": a live process holds the lock.
- No answer from an endpoint: the probe uses an 8-second ceiling and the
  tags route, which does not load a model. The server is down or the port
  is wrong.
- `-P NAME` says OPEN_SLOP_PROMPTS is not set: the binary is running
  outside the home-manager wrapper. Pass a path, or run the wrapped llmq.
- Output shows U+FFFD: a line longer than the whole budget was cut inside a
  multibyte character (chunker rule 3).
- catalogue-check warns about a model: add an entry under models.<backend>
  in catalogue/default.nix or services.open-slop.catalogue.extra.
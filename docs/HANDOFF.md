# open-slop: handoff

Written 2026-09-19, rewritten 2026-09-24 against the grace branch. Every
claim says whether it was verified against the real fleet, verified on
winsmuth against a local ollama, tested against mock servers, evaluated in
an oracle-shaped NixOS configuration, or only written.

## 1. What this is

open-slop is the tooling for running and using a Nix-configured local LLM
machine. It began as one script (llmq) in neoblade-config and is now a
standalone flake repo at ~/git/open-slop, imported by neoblade-config as an
input, with a Haskell library at its centre. The machine it targets today is
oracle, a Raspberry Pi 5 (16 GB) with a Hailo-10H NPU, at 192.168.8.173.

Goal, as stated: the canonical way to run and talk to such a machine, usable
and iterated on without a person at a terminal, with the parts that must not
be wrong written in Haskell.

Branches: `main` has llmq and the fleet modules. `grace` adds the gateway,
the Grace fork as an input, llmq-grace and the typed stage. Everything in
section 2 marked 2026-09-22 or later is on `grace` and not yet merged.

## 2. State of the code

### VERIFIED against the real fleet (2026-09-19 to 2026-09-21)

- Deployed. oracle runs the configuration built ON oracle (kernel
  linux-rpi 6.18.50, nixpkgs 20b1ddd), through `./build deploy-native
  oracle`, made the boot default with `boot-native`. Units active: ollama
  with OLLAMA_CONTEXT_LENGTH=16384 and OLLAMA_NUM_PARALLEL=1,
  ollama-pinned-models (sully, registered through /api/blobs under a
  DynamicUser), hailo-ollama, hailo-ollama-models (five models),
  llama-server (on demand, --host 0.0.0.0, firewalled to the LAN ranges).
- oracle is the fleet's aarch64 builder. The daemon route works: `nix store
  info --store 'ssh-ng://root@192.168.8.173?ssh-key=/var/lib/nix-builder/key'`
  answers Trusted: 1 from winsmuth's root. `--option extra-platforms ""`
  sends aarch64 derivations there (`--max-jobs 0` does not: nixpkgs'
  Haskell builder makes preferLocalBuild wrapper scripts that never go
  remote).
- The integration into neoblade-config: open-slop is a flake input, its
  overlay is on the fleet's overlay list, its NixOS modules are imported on
  every row and enabled on oracle by `llm.backends` in targets.nix, its
  home-manager module is enabled by the lab role with endpoints built from
  targets.nix. `roles.llm` is gone. `llmq list` on winsmuth reaches oracle
  with no environment set by hand.
- llmq against oracle, real documentation jobs on qwen2.5-coder:7b. See
  docs/measurements.md for every number.
- llama-server's /completion is raw completion: an instruct model given
  untemplated input continues it. The first Bonsai job reproduced its own
  input for an hour. llmq now renders through /apply-template first, and
  `llmq ask` against bonsai-8b answers correctly at 3.6 tok/s.
- hailo-ollama 5.1.1, measured: streams in ollama's line shape; honours
  options.num_predict; reports done_reason, total_duration and eval_count
  and NO prompt_eval_count; window is 2048 (answer at about 1900 prompt
  tokens, garbage with HTTP 200 at about 2100, HTTP 500 with a plain-text
  body at 4000). Its config JSON is `{server: {host, port}, library: {host,
  port}, main_poll_time_ms}`.
- The seed unit stamps by zoo version, not store path, and the pull unit
  skips models /api/tags already lists: re-activation after both fixes took
  four seconds, against twelve minutes and 9 GB before them.

### VERIFIED on winsmuth against a local ollama (qwen2.5:0.5b), 2026-09-22
### and 2026-09-23

This is the whole Grace chain, on a real model, with oracle unreachable.

- The Grace fork (OPENAI_BASE_URL in Grace.HTTP.getMethods) reaches
  open-slop-gateway, which translates to ollama's /api/chat with the schema
  as `format`. All three of Grace's prompt paths return typed values: a
  record, a non-record wrapped as `{ response: T }`, and Text. The openai
  bindings decode the gateway's response body as written.
- llmq-grace end to end: stage loaded and type-checked against the Haskell
  `Docs` type, one part sent, a typed `Docs` value decoded by Grace,
  coverage checked by field comparison, Markdown rendered in Haskell, exit
  0. 1,350-byte part, 691 prompt tokens, 177 completion, 7 seconds.
- The gateway's own behaviour, by curl: bearer keys accepted and refused;
  /v1/models listing; ollama, llama-server and hailo translations; the
  hailo schema refusal; the byte pre-check; the prompt-count post-check
  (400 context_length_exceeded); a dead backend as 502; TLS with a
  self-signed certificate; the refusal to bind a non-loopback address
  without TLS.

### TESTED against mock servers

- The library, llmq and the gateway: Catalogue, Chunk (both modes), Engine
  (three engines), Http, Stats, Job, OpenAI, Gateway.{Keys,Route,Translate}.
  14 tests pass (5 chunker properties and cases, 9 gateway cases).
- llmq scenarios: list with live and dead endpoints; ask on all three
  engines; dry run; SIGTERM and resume by id and by re-run; the lock;
  ollama truncation; llama-server's truncated flag; a stream with no final
  line; HTTP 500 with a JSON body and with a plain-text body; per-request
  timeout; warnings exit 2; per-engine request bodies; -P by name, by path,
  with a bad name, and the shipped default.

### EVALUATED in an oracle-shaped NixOS configuration

- options, server, pinned, hailo, llama-server, gateway, catalogue-check,
  and the neoblade side (llm.backends producing the enable flags,
  statePaths feeding homelab.persist.system).
- The gateway module: credentials through LoadCredential into a
  DynamicUser; the firewall rule; and all four assertions provoked (TLS
  files together, no plaintext LAN bind, at least one backend, port not a
  backend's port).

### WRITTEN only

- nix/packages/bonsai-weights.nix: the 27B PQ2_0 and 8B PQ2_0 hashes are
  filled and those files are on oracle; the 27B PTQ1_0 hash is fakeHash.
- The gateway's NixOS module: evaluated, never activated. Nothing in
  neoblade-config enables it, and the keys file it needs has no sops entry.
- llmq-grace's option parser: `-m` is required even on a resume, and `-r`
  coexists with `-i`, `-c` and `--fresh` without the refusal llmq has.

### Does not exist

- The runner, a Haskell mock server, the VM tests.
- A fleet CA. The gateway's TLS options take files; nothing issues them.
- The golden set (item 30). No prompt change to date is evidence-based
  except the per-file one, which was an A/B on one input.
- Any measurement of the Grace chain on oracle. Everything Grace-related
  is measured on a 0.5B on a laptop.

## 3. Architecture, as decided

- neoblade-config knows machines: addresses, which backends a row runs
  (`llm.backends` in targets.nix), secret file paths, firewall ranges. It
  imports open-slop and sets services.open-slop.* and programs.llmq.*.
- open-slop knows backends, models, engines, keys, jobs and stages. It
  contains no address and no fleet name. Its catalogue is data; a fleet
  adds entries through services.open-slop.catalogue.extra.
- Binaries, from one cabal package:
  - llmq: the client. Parts, resume, coverage warnings, prose out.
  - open-slop-gateway: one authenticated OpenAI-compatible endpoint in
    front of a row's servers.
  - llmq-grace: llmq's job machinery with a Grace stage in place of the
    prose prompt, typed values out.
- The catalogue: backends carry engine, port, streams, acceptsOptions, ctx,
  predict, promptOverhead, charsPerToken, temperature, blurb; models carry
  summary, docFit, optional ctx/predict, tokPerSec (measured only), licence,
  blurb. Budget per request is floor((ctx - predict - promptOverhead) *
  charsPerToken) bytes. A job's id hashes the budget, the mode and the
  instruction.
- Prompts are files under prompts/ for llmq; stages are Grace files under
  stages/ for llmq-grace.

## 4. Decisions taken, with the reason

- Haskell for everything that holds state.
- nixpkgs' Haskell set with one pinned compiler, the derivation committed
  at nix/open-slop.nix and regenerated with `nix run .#cabal2nix`, so the
  consumer evaluates without import-from-derivation. NOT haskell.nix: this
  package has thirteen ordinary dependencies and one git input, and
  haskell.nix would add a Hackage index, IFD in a flake neoblade evaluates,
  and a repackaging of Grace, for no gain here.
- The consumer adds the overlay and imports the modules; the modules do not
  set nixpkgs.overlays, because home-manager under useGlobalPkgs rejects it.
- **One file per part is the default** (`--packed` for the old behaviour).
  Measured: given four files in one packed part, qwen2.5-coder:7b
  documented the first and stopped, with and without an instruction telling
  it not to. One file per part documented all four, in less total time,
  because prefill and decode both slow as the context grows.
- **Sampling is deterministic**: temperature 0.0 in the cpu backend and a
  fixed seed in llmq's samplingFor. Two runs of the same part on the same
  server now produce the same text, so a prompt change can be judged.
- Input never comes from a terminal paste (4095-byte line limit).
- Truncation is a failure. ollama drops the front of an oversized prompt
  and answers 200; llama-server reports it; hailo-ollama reports nothing
  and answers garbage with 200, so on the NPU the byte budget is the only
  guard and sits at half the window.
- The gateway refuses rather than degrades: unknown or unsupported request
  fields fail the decode by name, an oversized input is a 400 before
  sending, an overflowing prompt count is a 400 after, a schema-constrained
  answer that hit the token cap is a 400 (see section 6), a dead backend is
  a 502. Every refusal is an OpenAI error body, so the openai bindings
  surface the message.
- The gateway does not queue. Each backend serves one request at a time and
  queues the rest itself.
- **The Grace runner is split out by a cabal flag.** llmq-grace links
  Grace, whose closure keeps a reference to the compiler: 4.6 GB, measured.
  pkgs.open-slop.llmq (llmq, gateway) is 86 MB and is what a row gets;
  pkgs.open-slop.llmq-grace is the workstation tool. nix/open-slop.nix is
  generated with `cabal2nix --flag grace` so the dependency is listed, and
  the `configureFlags = [ "-fgrace" ]` line cabal2nix writes for it is
  stripped by the generator, because it would turn the flag on for every
  build from that derivation.
- **The stage's result type lives in the binary.** `Grace.Interpret.load`
  annotates the .ffg with the Haskell type before inference, so a stage
  whose own annotation disagrees fails at load, before any request. The
  generic `--json` mode (any stage type, JSON straight through) is the
  obvious second form and is not written.
- Gateway as Haskell rather than nginx.
- Pipelines are fixed workflows, not autonomous agents.
- Bonsai PQ2_0 before PTQ1_0 on ARM (NEON kernel versus generic fallback).
- llama-server not resident by default.
- statePaths is an output option; open-slop has no opinion about
  impermanence.
- oracle builds its own aarch64 closure; `./build deploy-native oracle` is
  the path. winsmuth keeps binfmt, so plain `deploy` still emulates.
- The pinned-models unit registers through /api/blobs under its own
  DynamicUser; nixpkgs' module stopped creating an `ollama` user.
- The Hailo seed stamp is the zoo VERSION, and the pull unit checks
  /api/tags first.

## 5. Improvement list: status

Phase 0 (measure): 43 fork packaged (done); 44 weights pinned (two of three
hashes); 45 llama-server unit (done, deployed); 47 measure on oracle (DONE,
docs/measurements.md); 48 golden-set comparison (not started).

Phase 1 (Haskell core): 29 rewrite (client done); 33 server defaults (done);
1 backends per row (done); 3 dry run without an instruction prompt (done),
instruction size against promptOverhead (NOT done); 19 git ls-files input
with excludes (NOT done); 21 named prompts (done); 46 third engine (done).

Phase 2 (gateway): the binary, its module and the key scheme are WRITTEN and
tested against mocks and a local model. What remains: sops entries and a
fleet CA, then activation on oracle. Items 6, 9, 11, 17 are covered by it;
16 (rate log) is not written; 34 is superseded.

Phase 3 (unattended): 12 runner; 7 cancel; 8 rm and gc; 13 notifications;
14 Forgejo PRs; 31 VM tests. None written.

Phase 4 (quality, speed): 30 golden tests (the gate on every prompt change,
not started); 26 mechanical check then model check (the typed stage makes
this cheap: claims are fields, not prose); 28 structured output (DONE by
construction in llmq-grace); 18 per-file cache; 20 reduction pass; 22
budgets from measurement; 50 Bonsai self-verification.

Grace: 32 fork for base URL (DONE); 35 call cache (not written); 36 pin
(done); 42 schema support (answered, see section 6); 37 llmq runs Grace
programs (DONE as llmq-grace); 49 import prompt trials (see section 7).

Dropped: 2, 4, 5, 10, 15, 24, 27, 38, 39, 40, 41, Grace's 34.

## 6. Open questions

Answered since the last revision:

- ollama's schema support: the gateway does not use /v1/chat/completions on
  ollama at all. It uses /api/chat with the schema in `format`, which
  constrains decoding. Verified end to end.
- secrets.nix in neoblade-config is sops-nix, so key distribution uses sops
  templates.
- Native build timing on oracle: library plus llmq in ten to twelve minutes
  at cores = 2, haddock included. dontHaddock not timed.

Still open:

1. Does disconnecting the client stop generation on ollama during prefill,
   and on hailo-ollama at all? Blocks cancel semantics.
2. Does hailo-ollama serve any OpenAI-compatible route? Blocks the NPU
   behind the gateway as anything but /api/generate.
3. Does hailo-ollama honour `server.host` from a copy of its JSON in
   $XDG_CONFIG_HOME? That is the loopback-bind lever.
4. The 27B PTQ1_0 hash and file name.
5. What `predict` a documentation-sized `Docs` value actually needs. The
   cpu backend reserves 2048 output tokens. A 0.5B blew through it by
   repeating itself; a 7B on a 20 KB part has not been tried. This is the
   first thing to measure on oracle for the Grace chain.
6. Whether Grace's retry (three attempts, jittered, on 5xx and connection
   errors) is wanted in front of an hour-long generation, or whether the
   gateway should answer those differently.
7. Whether a server's KV cache is reused across calls that share a prefix.
   This decides the chase pipeline's cost (docs/design/chase-stages.md) and
   whether Grace's `import prompt` is possible at all. The gateway's log
   line answers it: ollama reports the prompt tokens it evaluated.

## 7. Pipe dreams and unrealistic goals

Called out so they are not mistaken for plans.

### Bonsai 27B as a frontier stand-in on a Pi 5

MEASURED and settled: prefill 0.98 tok/s, decode 0.66 tok/s at short
prompts. A 16K prompt is over four hours before the first output token. Not
a working model on this hardware. The 8B is 4.62/3.60 at 128 tokens and
2.85/0.47 at 8K, which makes it the fastest thing here for a short question
and slower than qwen2.5-coder:7b for documentation. The catalogue says so.

### The 262K context window

A memory fact. Hybrid attention makes a long context cheap to hold and does
nothing for prefill on four A76 cores.

### Grace's `import prompt` on local models

Grace ships abnf.md and inference.md, 29 KB together, about 8,000 tokens of
system prompt per request, because there is essentially no Grace in any
model's training data. On the 7B at 5.5 tok/s prefill that is 25 minutes
before the model reads the question, and half the window gone. Grace code
generation is off the table per call on oracle; whether it is off the table
per session depends on question 7. Grace *data* generation, where the model
fills a schema and never sees the grammar, costs nothing extra and is what
llmq-grace does.

### Autonomous sub-agents

None of the models on this fleet plan or call tools reliably.

### Trustworthy documentation from a chunked pass

Each part is written with no view of the others. Relationships across files
are missing by construction. The typed stage guarantees shape, not truth:
the 0.5B filled `interface` with the prompt's own category words and
`reasoning` with a confident falsehood about where a key is written, and
every layer reported success. A human reading the pull request is the only
real check.

### The NPU for documentation

Under 3 KB of input per request at 1.5B to 3B parameters, with no prompt
count and no schema support. Classification, extraction, one-line labels,
under the rule that it may only add work, never remove it.

### Reproducible outputs

Temperature 0 and a fixed seed make ollama deterministic for one build on
one machine with one thread count. They do not survive an ollama bump, a
kernel change or a different CPU. They are enough to A/B a prompt.

### "Canonical for any Nix-configured LLM machine"

Every option and every catalogue entry so far is shaped by one machine.

### Iterating entirely from a phone

The runner, notifications and PRs make submit, cancel and review possible
from a phone. What remains is judgement.

### Time estimates

The dry run's estimate counts output only and uses a short-prompt rate; on
Bonsai 8B that overstates a long job by a factor of seven. Prefill
dominates on the Pi and is not in any estimate.

### The gateway as security

Bearer keys over TLS on a LAN stop other LAN devices from using oracle and
give per-client identity and revocation. They do not protect against the
user's own machine or against root on oracle. Locally the servers stay
unauthenticated on loopback. `--plaintext-lan` exists for bring-up before a
CA and puts the keys in clear on the wire.

## 8. Risks that are real but ordinary

- Deploying oracle during a job restarts ollama and kills the part.
- winsmuth sleeps; a job started there dies with it. Use `systemd-run
  --user --collect --unit=NAME`, and note that a user unit starts in $HOME,
  so `nix build .#x` becomes `nix build ~/git/open-slop#x`.
- A long custom instruction is not measured against promptOverhead.
- Generated files inflate jobs. Run catsrc per subdirectory until item 19.
- /var/lib/nix-builder/key on winsmuth is outside every persistence
  manifest; it needs a homelab.persist.system entry in hosts/winsmuth.nix.
- With binfmt still on winsmuth, `./build deploy oracle` emulates.
- `services.ollama.loadModels` runs `ollama pull` at every activation.
- Models pulled by hand on oracle are undeclared state; three appeared once
  and one again, both removed with `ollama rm`.
- llmq-grace's 4.6 GB closure is fine on winsmuth and must never reach a
  row. The cabal flag is what prevents it; anything that turns the flag on
  globally undoes that.
- The winsmuth test setup keeps its catalogue and keys in /tmp, which does
  not survive a reboot. The gateway exits at start when either is missing.
- Two stale strings in neoblade-config say roles.llm.backend (singular);
  docs/hailo.md section 13 and hailo.nix's version assertion disagree about
  firmware; the flake.nix comment on configurationRevision is wrong.

## 9. Order of work

1. On oracle, when back: llmq-grace against qwen2.5-coder:7b on one module
   directory, one file per part. That answers question 5 and is the first
   evidence about the Grace chain on hardware that matters.
2. llmq-grace's parser: `-m` optional on resume and taken from meta.json;
   `-r` refusing `-i`, `-c` and `--fresh`, as llmq does.
3. The gateway on oracle: a sops entry for the keys file, `plaintextLan =
   true` behind the LAN firewall rule until a CA exists, then activation.
   Needs modules/system/secrets.nix in front of me.
4. Golden set (30), using the deterministic sampling that now exists.
5. Runner (12), with cancel, notifications, PRs, VM test.
6. The `--json` mode for llmq-grace, once a second stage type exists.

## 10. What to look at first when something is wrong

### llmq

- A part failed as truncated: the budget is too large for that model's real
  bytes-per-token. Start a new job with a smaller --chunk-bytes; resuming
  will fail the same way.
- A stream ended without a final line: the server restarted, the network
  dropped, or --timeout fired. failed/NNNN.raw has whatever arrived.
- "the response is not JSON: server=oatpp": hailo-ollama refused an
  oversized prompt.
- "already running in another llmq": a live process holds the lock.
- No answer from an endpoint: the probe uses an 8-second ceiling and the
  tags route. The server is down or the port is wrong.
- `-P NAME` says OPEN_SLOP_PROMPTS is not set: the binary is running
  outside the home-manager wrapper.
- Output shows U+FFFD: a line longer than the whole budget was cut inside a
  multibyte character (chunker rule 3).
- catalogue-check warns about a model: add an entry under models.<backend>.

### The gateway

- 401 "unknown key": the keys file the unit loaded does not contain that
  key. The file is a credential, so check the unit's journal line at start,
  which prints the client count.
- 404 model_not_found: the id is not a unique suffix of anything the
  backends report. GET /v1/models lists them.
- 400 context_length_exceeded before any generation: the byte pre-check.
  After one: the backend's own prompt count reached the window.
- 400 length_before_schema_complete: a schema-constrained answer stopped at
  the token cap, so the JSON is unfinished by construction. Send fewer
  input bytes, raise max_completion_tokens, or use a model that does not
  repeat itself. Seen on qwen2.5:0.5b, which repeated one sentence for 2048
  tokens on a 19 KB part.
- 400 naming a request field: the gateway refuses fields it cannot honour
  (tools, streaming, n > 1, images, audio) rather than dropping them.
- 502 backend_unreachable: the server behind it is down. The model listing
  is cached for thirty seconds, so an id can resolve after the server dies.

### Grace and llmq-grace

- The stage fails to parse at a record label: Grace's lexer registers
  `file`, `http`, `https` and `env` as URI schemes, so a label `file:`
  starts an import. FileDoc's field is `path` for that reason.
- NotSubtype Text (Optional Text) at load: a field of Grace's prompt record
  is Optional. PartArgs.model is Maybe Text for that reason.
- "Unbound variable" from an `env:` import: the variable is parsed as Grace
  code unless the import is annotated. `env:VAR : Key` and `env:VAR : Text`
  read the raw text.
- "Failed to decode output as JSON": the model's answer did not finish. The
  gateway should have refused it first; if it did not, the cap and the
  schema are the place to look.
- A part failed with a connection error: the gateway is not running. It
  exits at start if its catalogue or keys file is missing, and both live in
  /tmp in the winsmuth test setup, which does not survive a reboot.

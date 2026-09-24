# open-slop

Guardrails that let a small local model do real work: the servers as NixOS
modules, a catalogue of what each model costs, a client that turns long
input into documentation as a resumable job, an authenticated gateway that
constrains what a model may return, and a runner that calls typed Grace
stages so the model's output is checked against a Haskell type before any
of it reaches your code.

Licence: AGPL-3.0-or-later for everything here. The Hailo packages fetch
proprietary blobs and say so in their meta.

## The idea

A 7B model on a Raspberry Pi is unreliable in a specific, boring way: it
wanders off format, stops early, restates its input, and invents detail.
Most tooling answers that with better prompts and hope. This answers it with
machinery:

- **The shape is guaranteed by a grammar, not by the model.** A request with
  a JSON Schema is decoded under that schema by the server. Malformed
  output is unrepresentable.
- **The schema comes from a type.** Grace compiles a result type to the
  schema and checks the answer against it on the way back; llmq-grace
  annotates the Grace file with the Haskell type at load, so a stage whose
  shape disagrees with the program fails before a single request is sent.
- **The caller owns the facts the model should not touch.** The path a
  documented file lives at, the name a signature has, the list of files in
  a part: all attached by the caller from its own parse. An answer about a
  file that does not exist cannot be constructed.
- **Every window is checked twice.** Input bytes before sending, the
  server's own prompt count after. Silent truncation is a failure, not a
  shorter answer.
- **Coverage is a comparison of values.** The runner knows which files were
  in a part and which ones came back; a skipped file is a warning and a
  non-zero exit, not something you notice a week later.

What is left for the model is judgement inside a fixed shape. That is the
part a small model can sometimes do, and the part nothing can verify for
you, which is why the output lands in a file for a person to read.

## Layout

```
flake.nix                        outputs below; nixpkgs Haskell, one compiler
catalogue/default.nix            backends, models, budgets, blurbs: plain data
nix/open-slop.nix                the Haskell package, cabal2nix shape, committed
nix/modules/options.nix          services.open-slop.*: the whole consumer contract
nix/modules/server.nix           ollama on the CPU
nix/modules/pinned.nix           store-pinned GGUFs registered with ollama
nix/modules/hailo.nix            the Hailo-10H stack and hailo-ollama
nix/modules/llama-server.nix     PrismML llama.cpp serving one Bonsai GGUF
nix/modules/gateway.nix          the authenticated OpenAI-compatible endpoint
nix/modules/catalogue-check.nix  warns and asserts against the catalogue
nix/modules/client.nix           home-manager: programs.llmq
nix/packages/                    the fork, the weights, the Hailo packages
haskell/                         the library, llmq, the gateway, llmq-grace
prompts/                         named instructions, shipped with llmq
stages/                          Grace stages, typed against Haskell records
tests/grace/                     one Grace program per prompt path
docs/HANDOFF.md                  state, decisions, open questions, pipe dreams
docs/measurements.md             numbers, only measured ones
docs/latest.md                   the one-screen status
docs/design/chase-stages.md      the three-stage chase pipeline, not yet run
```

## Outputs

- `nixosModules.default`: every server-side module, the gateway included.
  Inert until a `services.open-slop.*` option enables something.
- `homeManagerModules.default`: `programs.llmq`.
- `overlays.default`:
  `pkgs.open-slop.{llmq,llmq-grace,catalogue,llama-cpp-prismml,bonsai,grace}`.
- `packages.<system>.{llmq,llmq-grace,grace,llama-cpp-prismml,bonsai-*}`.
- `apps.<system>.{cabal2nix,gateway,grace}`.
- `lib.catalogue`: the catalogue as data.

`llmq` carries `bin/llmq` and `bin/open-slop-gateway`, about 86 MB of
closure, and is what a row gets. `llmq-grace` carries all three binaries and
4.6 GB, because Grace's closure keeps a reference to the compiler; it is a
workstation tool and is kept off the fleet by the `grace` cabal flag. See
HANDOFF section 4.

The consumer adds the overlay to its package set and imports the modules.
The modules do not set `nixpkgs.overlays` themselves: home-manager running
with `useGlobalPkgs` rejects that from a module.

## Consuming from a fleet configuration

This is how neoblade-config does it, which is the only consumer so far.

In the consumer's flake:

```nix
inputs.open-slop = {
  url = "path:/home/bismuth/git/open-slop";   # a forge URL once pushed
  inputs.nixpkgs.follows = "nixpkgs";
};
```

`inputs.open-slop.overlays.default` goes on the overlay list every package
set is built with. Every NixOS row imports `open-slop.nixosModules.default`;
every home-manager configuration imports
`open-slop.homeManagerModules.default`. Both are inert until enabled.

Which backends a row runs is declared once, on the row, and read twice. In
neoblade-config that is `llm.backends = [ "cpu" "hailo" ];` on oracle's row
in targets.nix, which flake.nix turns into
`services.open-slop.{server,hailo,llamaServer}.enable`, and the lab role
turns, with the row's address, into `programs.llmq.endpoints`.

The rest is the machine's own facts, in its host file:

```nix
services.open-slop = {
  openFirewallFor = [ "192.168.8.0/24" ];
  server = {
    host = "0.0.0.0";
    models = [ "qwen2.5-coder:7b" "llama3.1:8b" ];
    pinnedModels.sully = { url = "..."; hash = "sha256-..."; };
  };
  hailo.models = [ "qwen2.5-instruct:1.5b" "llama3.2:3b" ];
  llamaServer = {
    model = pkgs.open-slop.bonsai."8b-pq2_0";
    alias = "bonsai-8b";
    host = "0.0.0.0";
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

The device tree overlay that enables the Pi's M.2 slot stays in the
consumer's hardware configuration; it is a board fact, not an open-slop one.

A client machine, in home-manager, when not derived from a targets file:

```nix
programs.llmq = {
  enable = true;
  endpoints.oracle = {
    address = "192.168.8.173";
    backends = [ "cpu" "hailo" ];
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

With no `-m`, an fzf menu lists the models the servers report. With no
`-i`, text comes from the X clipboard when stdin is a terminal and from
stdin otherwise. `-i -` refuses a terminal paste: a tty cuts lines at 4095
bytes. `-P reference-docs` names a shipped prompt from prompts/; a name with
a slash or a `.md` suffix is a path. Exit status: 0 done, 1 failed, 2 done
with warnings, 130 interrupted.

**One file per part is the default.** `--packed` fills parts to the budget
instead. Measured: given four files in one part, qwen2.5-coder:7b documented
the first and stopped, with and without an instruction not to; one file per
part documented all four, in less total time, because both rates fall as the
context grows. docs/measurements.md has the curve.

A job lives under `$LLMQ_STATE`, else `$XDG_STATE_HOME/llmq`, else
`~/.local/state/llmq`. Its id hashes model, budget, mode, instruction and
input, so the same command resumes the same job and a changed catalogue
starts a new one. Finished parts are kept.

For a run longer than a terminal session:

```fish
systemd-run --user --collect --unit=llmq-docs llmq -m oracle/cpu/qwen2.5-coder:7b -i ~/input.txt
journalctl --user -fu llmq-docs
```

A user unit starts in `$HOME`, so a `nix build .#x` inside one needs the
full path: `nix build ~/git/open-slop#x`.

## Using the gateway

One authenticated OpenAI-compatible endpoint in front of a row's servers.
Clients send the ids `llmq list` shows.

```fish
open-slop-gateway --catalogue CAT.json --keys KEYS [--host ADDR] [--port N] \
                  [--tls-cert FILE --tls-key FILE] [--plaintext-lan]
```

The keys file is `name key` per line. Keys are held as their sha256. Without
TLS the gateway binds loopback only; a LAN bind needs certificates or the
explicit `--plaintext-lan`.

What it refuses, rather than silently degrading: fields it cannot honour
(tools, streaming, `n > 1`, images, audio) fail the decode by name; input
past the model's window is a 400 before sending; a prompt count that reached
the window is a 400 after; a schema-constrained answer that stopped at the
token cap is a 400, because that JSON cannot be complete; a dead backend is
a 502. Every refusal is an OpenAI error body, so a client built on the
`openai` bindings surfaces the message.

Per backend: ollama gets `/api/chat` with the schema as `format`;
llama-server gets its own `/v1/chat/completions`; hailo-ollama gets
`/api/generate` and is refused any schema, because it cannot constrain
output and reports no prompt count.

## Using llmq-grace

llmq's job machinery with a Grace stage in place of the prose prompt, and a
typed value out.

```fish
llmq-grace --stage stages/reference-docs.ffg --gateway URL --key-file FILE \
           -m ROW/BACKEND/NAME -i INPUT [-o FILE] [-c BYTES] [-n] [--packed] [-r ID]
```

Each part produces `parts/NNNN.grace.json` (the typed value, which is what a
later stage reads) beside `parts/NNNN.md` (rendered from it in Haskell, for
a person). The stage's result type lives in the binary, so a `.ffg` whose
annotation disagrees fails at load with the field named.

Two Grace facts that cost a day to find, both in HANDOFF section 10: `file`
is a URI scheme in Grace's lexer, so a record label `file:` starts an import
(the field is `path`); and `prompt`'s `model` is `Optional Text`, so the
Haskell field is `Maybe Text`.

## Developing

```fish
cd ~/git/open-slop
nix develop
cd haskell
cabal build --flag grace all
cabal test
```

The `grace` flag builds llmq-grace; without it the package is llmq and the
gateway only, which is what the fleet gets.

After editing `haskell/open-slop.cabal`:

```fish
nix run .#cabal2nix
```

and commit `nix/open-slop.nix`. The generator passes `--flag grace` so the
dependency is listed, and strips the `configureFlags` line cabal2nix writes
for it, so the flag stays off by default. The flake builds from that file,
not from cabal2nix at evaluation time, so a consumer never needs
import-from-derivation.

To test a working tree against the fleet without publishing:

```fish
cd ~/neoblade-config
nix flake update open-slop
./build check
./build deploy-native oracle
```

## Where this goes

The point of the guardrails is that they make small models useful for jobs
that normally need a frontier model. What follows is the shape of that,
separated into what is measured, what is a design, and what is a bet.

### Typed stages as the unit of work

A stage is a Grace function from arguments the caller supplies to a result
type the caller owns. That gives four properties at once, and they compose:
the schema constrains decoding, Grace checks the answer against the type,
the caller attaches every fact the model should not invent, and Haskell runs
the loop, the retries and the checks that Grace deliberately cannot express
(Grace has no recursion: every program terminates).

The immediate application is chase annotations, where the frontier model
currently writes the notes the parser cannot derive. Split into three
stages, that becomes: one call per signature for invariants, with the
function's name attached by the parser rather than returned by the model; a
deterministic render in Haskell; one call per module for decisions and open
issues, retried against the drift checker. Nothing in chase's writer or
checker changes. docs/design/chase-stages.md has the design.

### The prefix-cache bet

Stage one above sends the same module bundle in front of a different
signature every time. A server that keeps its KV cache between requests
prefills only the tail after the first call. On the measured rate curve
that is the difference between roughly 84 minutes and roughly 23 for a
20-signature module on qwen2.5-coder:7b. Unmeasured, and the gateway's log
line answers it directly, because ollama reports the prompt tokens it
actually evaluated.

The same bet decides whether Grace's `import prompt` is possible here at
all: its 29 KB grammar is 25 minutes of prefill per call on oracle, and
once per session if the cache holds.

### The NPU as a triage tier

hailo-ollama has no grammar-constrained decoding and reports no prompt
count, so no typed stage can run on it. What it can do is a tiny prompt with
a closed set of answers stated in the prompt, one or two words out, and a
whitelist check in Haskell where anything unrecognised means "unknown". It
is separate silicon, so it overlaps the CPU.

One rule makes that safe: **the NPU may only add work, never remove it.**
An "unknown" or an off-list answer falls through to the expensive path.
Under that rule the useful judgements are triage ("does this signature need
a note beyond its type?"), a second opinion on one claim, and routing.
Never facts the parser already has: purity, arity, what a function calls.

### Typed decisions without generation

The category worth watching is a model that does not generate at all: state
plus typed questions in, a calibrated distribution per question out of one
forward pass, with nothing to parse. Malformed output and invented options
disappear by construction; being wrong does not. Open reproductions exist as
encoder classifiers, and a DeBERTa-large-sized classifier is a fraction of a
second per decision on four A76 cores at int8, with no decode loop and no
2,048-token window. That is a better triage tier than a 1.5B generating the
word "yes", and it needs no NPU.

An ONNX encoder is also the kind of model Hailo's compiler is actually built
for, which is the only realistic path to using the NPU for something chosen
rather than something Hailo shipped. It is a week with a proprietary x86
toolchain and a fixed sequence length baked into the HEF. Measure it on the
CPU first.

A cheaper experiment in the same family, on a model already here:
llama-server returns per-token logprobs, so a one-token answer read off the
logits is a crude typed decision. The gateway refuses `logprobs` today;
allowing it for the llamacpp backend is a small change.

### Fine-tuning, and what it would and would not buy

Filling a Grace-derived schema needs no Grace knowledge at all, so a
fine-tune buys nothing for the pipeline above. Writing Grace needs the
grammar in front of the model, and there the setup is unusually good because
Grace is its own verifier: generate candidates, keep what type-checks, and
the corpus needs no human labelling. A LoRA on a 7 to 8B would improve the
odds that generated Grace type-checks. It would not change the rate curve,
and at 0.5 to 0.7 tok/s at long context a wrong intermediate program still
wastes every level under it.

Before any of that: cache the preamble, and shrink it. An ABNF-only variant
with six worked examples might be 2 to 3K tokens instead of 8,000.

### One concrete fix waiting in the schema path

Grace's `toJSONSchema` emits record properties through a `Map`, so the
schema's `properties` object is alphabetical while `required` keeps
declaration order. Under grammar-constrained decoding the model writes
fields in schema order, so the alphabet decides what it commits to first.
That matters because constraining output can cost reasoning quality: the
model has nowhere to think before committing. The fix inside a constrained
schema is a scratch field the caller throws away, and it only helps if it is
generated first, which means naming it to sort first (`analysis`, not
`notes`). Two lines in the Grace type and the Haskell record. Whether it
improves anything on a 7B is exactly what the golden set is for.

### What none of this fixes

Each part is written with no view of the others, so relationships across
files are missing by construction. A schema guarantees shape, not truth: in
the first end-to-end run a 0.5B filled `interface` with the prompt's own
category words and `reasoning` with a confident falsehood, and every layer
reported success. The output is for a person to read.

## Status

Read docs/HANDOFF.md before touching anything. In one line: the server
modules and llmq are deployed and verified on oracle with real
documentation jobs; the gateway, the Grace fork and llmq-grace are verified
end to end on winsmuth against a local model and are not yet on the fleet;
the runner, the fleet CA and the golden set do not exist.

# open-slop

The tooling for a Nix-configured local LLM machine: the servers as NixOS
modules, a catalogue of what each model costs, and a Haskell client that
turns long input into documentation as a resumable job. A gateway with API
keys and an unattended runner are planned; see docs/HANDOFF.md.

Licence: AGPL-3.0-or-later for everything here. The Hailo packages fetch
proprietary blobs and say so in their meta.

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
nix/modules/catalogue-check.nix  warns and asserts against the catalogue
nix/modules/client.nix           home-manager: programs.llmq
nix/packages/                    the fork, the weights, the Hailo packages
haskell/                         the library and llmq
prompts/                         named instructions, shipped with llmq
docs/HANDOFF.md                  state, decisions, open questions, pipe dreams
docs/measurements.md             numbers, only measured ones
```

## Outputs

- `nixosModules.default`: every server-side module. Inert until a
  `services.open-slop.*` option enables something.
- `homeManagerModules.default`: `programs.llmq`.
- `overlays.default`: `pkgs.open-slop.{llmq,catalogue,llama-cpp-prismml,bonsai,grace}`.
- `packages.<system>.{llmq,grace,llama-cpp-prismml,bonsai-*}`.
- `apps.<system>.cabal2nix`: regenerates nix/open-slop.nix after the cabal file changes.
- `lib.catalogue`: the catalogue as data.

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
    model = pkgs.open-slop.bonsai."2-27b-pq2_0";
    alias = "bonsai-2-27b";
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
llmq [-m NAME] [-i SRC] [-p TEXT | -P NAME|FILE] [-o FILE] [-c BYTES] [-n] [--fresh]
llmq -r ID                     resume a job
```

With no `-m`, an fzf menu lists the models the servers report. With no
`-i`, text comes from the X clipboard when stdin is a terminal and from
stdin otherwise. `-i -` refuses a terminal paste: a tty cuts lines at 4095
bytes. `-P reference-docs` names a shipped prompt from prompts/; a name with
a slash or a `.md` suffix is a path. With no `-p` or `-P`, the shipped
reference-docs prompt is used. Exit status: 0 done, 1 failed, 2 done with
warnings, 130 interrupted.

A job lives under `$LLMQ_STATE`, else `$XDG_STATE_HOME/llmq`, else
`~/.local/state/llmq`. Its id hashes model, budget, instruction and input,
so the same command resumes the same job and a changed catalogue starts a
new one. Finished parts are kept; interrupt with SIGINT or SIGTERM and run
the same command again.

For a run longer than a terminal session:

```fish
systemd-run --user --collect --unit=llmq-docs llmq -m oracle/cpu/qwen2.5-coder:7b -i ~/input.txt
journalctl --user -fu llmq-docs
```

## Developing

```fish
cd ~/git/open-slop
nix develop
cd haskell
cabal build
cabal test
```

Compile and test on the x86 workstation; a change to any Haskell file
rebuilds the whole package on the aarch64 builder when deployed, about ten
minutes on a Pi 5.

After editing `haskell/open-slop.cabal`:

```fish
nix run .#cabal2nix
```

and commit `nix/open-slop.nix`. The flake builds from that file, not from
cabal2nix at evaluation time, so a consumer never needs
import-from-derivation to evaluate open-slop.

To test a working tree against the fleet without publishing:

```fish
cd ~/neoblade-config
nix flake update open-slop
./build check
./build deploy-native oracle
```

The `path:` input picks up the working tree; `nix flake update open-slop`
refreshes the lock's hash of it.

## Status

Read docs/HANDOFF.md before touching anything. In one line: the server
modules and the client are deployed and verified on oracle (2026-09-20),
oracle builds its own aarch64 closure, the Hailo facts are measured; the
gateway, the runner, every Bonsai measurement and the golden set are still
to do.

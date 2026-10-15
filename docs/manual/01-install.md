# Installing

## What the flake provides

`overlays.default` adds `pkgs.open-slop`:

| Attribute | What it is |
|---|---|
| `llmq` | The fleet package. Contains `llmq`, `llmq-models`, `llmq-bench`, `llmq-claims`, `llmq-index` and `open-slop-gateway`. Built from nixpkgs' Haskell set, so every dependency comes from the binary cache. |
| `llmq-grace` | The Grace stage runner. Links Grace and keeps a reference to the compiler, about 4.6 GB. Workstation only. |
| `grace` | The `grace` interpreter, from the same workstation set. |
| `llama-cpp-prismml` | llama-server and friends from PrismML's llama.cpp fork, which has the ternary kernels. |
| `bonsai.*`, `gguf.*` | Model weights fetched by hash: `bonsai.2-27b-pq2_0`, `bonsai.2-27b-ptq1_0`, `bonsai.8b-pq2_0`, `gguf.qwen25-coder-7b`, `gguf.qwen25-coder-1_5b`. |
| `catalogue` | The shipped catalogue as Nix data. |
| `graceHpkgs` | The workstation Haskell set, for anything else that needs Grace. |

Other outputs:

- `nixosModules.default` imports every server-side module. Each is inert until one of its `services.open-slop.*` options is enabled. The individual modules (`options`, `server`, `pinned`, `hailo`, `llama-server`, `gateway`, `catalogue-check`, `rag`) are also exported, but they read each other's options, so import `default`.
- `homeManagerModules.default` is the client: `programs.llmq`.
- `packages.<system>` has `default`, `llmq`, `llmq-grace`, `grace`, `llama-cpp-prismml`, `bonsai-*` and `gguf-*`.
- `apps.<system>` has `default` (llmq), `gateway`, `claims`, `bench`, `grace` and `cabal2nix`.
- `checks.<system>.open-slop-tests` builds the fleet package with its test suite.
- `devShells.default` has cabal, HLS, ghcid, fourmolu, cabal2nix, fzf, xsel, jq and grace.
- `lib.catalogue` is the shipped catalogue as data.

## Why there are two Haskell package sets

`llmq-grace` links Grace, whose closure carries the compiler. Nothing that size should reach a Pi, so that executable is behind the cabal flag `grace`, which is off for the fleet.

Grace also pins its own versions of many Hackage packages. Putting those pins into the global Haskell set would change every package built on every host, nothing would match cache.nixos.org, and aarch64 rows would compile Hackage from source. So the fleet set is plain nixpkgs plus open-slop, and the workstation set (`graceHpkgs`) adds Grace's pins on top. Only `llmq-grace`, `grace` and the dev shell use it.

## Adding it to a NixOS flake

The modules do not set `nixpkgs.overlays` themselves, because home-manager with `useGlobalPkgs` rejects that from a module. Add the overlay yourself.

```nix
{
  inputs.open-slop.url = "github:harryprayiv/open-slop";

  outputs = { nixpkgs, open-slop, ... }: {
    nixosConfigurations.oracle = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        open-slop.nixosModules.default
        ({ pkgs, ... }: {
          nixpkgs.overlays = [ open-slop.overlays.default ];

          services.open-slop = {
            openFirewallFor = [ "192.168.8.0/24" ];
            server = {
              enable = true;
              host = "0.0.0.0";
              models = [ "qwen2.5-coder:7b" "nomic-embed-text" ];
            };
            catalogue.extra.models.cpu."qwen2.5-coder:7b" = {
              summary = "Qwen2.5-Coder 7B, the default for documentation jobs";
              docFit = "usable";
              licence = "Apache-2.0";
              blurb = "Follows the reference-docs format reliably at 16K context.";
            };
          };
        })
      ];
    };
  };
}
```

## Adding the client with home-manager

```nix
{ inputs, ... }:
{
  imports = [ inputs.open-slop.homeManagerModules.default ];

  programs.llmq = {
    enable = true;
    endpoints.oracle = {
      address = "192.168.8.173";
      backends = [ "cpu" "hailo" "llamacpp" ];
    };
    catalogue.extra = { };  # keep this identical to the server side's
    rag = {
      embedAt = "oracle/cpu";
      embedModel = "nomic-embed-text";
      chatAt = "oracle/cpu";
      chatModel = "qwen2.5-coder:7b";
    };
    # keyFile = "/run/secrets/llmq-key";  # only when talking to the gateway
  };
}
```

### What the client module does

It builds a catalogue JSON at evaluation time from the shipped catalogue, your `catalogue.extra`, and one endpoint per row and backend you list. The URL of each endpoint is `http://<address>:<the backend's catalogue port>`. Which models each server actually has is asked of the server at run time, never baked in.

It then wraps every binary in the package so that these variables are set by default:

| Variable | Value |
|---|---|
| `OPEN_SLOP_CATALOGUE` | the catalogue JSON |
| `OPEN_SLOP_PROMPTS` | the shipped `prompts/` directory |
| `OPEN_SLOP_PANDOC` | pandoc, by store path |
| `OPEN_SLOP_PDFTOTEXT` | pdftotext from poppler-utils, by store path |
| `OPEN_SLOP_RAG_DB`, `OPEN_SLOP_RAG_EMBED_AT`, `OPEN_SLOP_RAG_EMBED_MODEL`, `OPEN_SLOP_RAG_CHAT_AT`, `OPEN_SLOP_RAG_CHAT_MODEL` | from `programs.llmq.rag.*`, each only when set |
| `LLMQ_KEY_FILE` | from `programs.llmq.keyFile`, when set |

It also puts `fzf` and `xsel` on the wrapped programs' PATH. Every one of these is a default, so a variable you export yourself wins.

Each row's `backends` list is checked against the catalogue at evaluation, and an unknown backend name fails the build.

## Unfree packages

The Hailo firmware (`hailo10h-firmware`) and the Hailo model zoo (`hailo-gen-ai-model-zoo`) are unfree. open-slop does not allow unfree packages for you. Name them individually in your configuration:

```nix
nixpkgs.config.allowUnfreePredicate = pkg:
  builtins.elem (lib.getName pkg) [ "hailo10h-firmware" "hailo-gen-ai-model-zoo" ];
```

## Persistence on impermanent hosts

The server modules append to `services.open-slop.statePaths`, a list of `{ path, reason }`, every directory that holds state worth keeping. open-slop has no opinion about impermanence; map the list into your own mechanism, for example:

```nix
homelab.persist.system = config.services.open-slop.statePaths;
```

The paths are `/var/lib/private/ollama` (ollama's weights) and `/var/lib/hailo-ollama` (the Hailo zoo and its weights). llama-server keeps nothing; its weights are in the store. The RAG database lives in `services.postgresql.dataDir`, which `rag.nix` does not add, because a host that already runs Postgres already persists it. A host that gets Postgres only from `rag.nix` must persist that directory itself.

On the client side, persist `~/.cache/open-slop` (benchmark results) and `~/.local/state/llmq` and `~/.local/state/open-slop` (jobs and chat transcripts) if your home directory is wiped at boot.

## Developing

```fish
nix develop
cd haskell
cabal build --flag grace all
cabal test
```

After editing `haskell/open-slop.cabal`, regenerate the committed derivation and commit it:

```fish
nix run .#cabal2nix
git add nix/open-slop.nix
```

The derivation is committed so that a consumer evaluating every host never needs import-from-derivation. The script runs cabal2nix with the grace flag (so Grace is in the dependency list), points `src` at `../haskell`, deletes the `configureFlags = [ "-fgrace" ];` line cabal2nix writes (otherwise the fleet build would link Grace), and fails if either step went wrong.

To test a change against the fleet from neoblade-config:

```fish
git push
cd ~/git/neoblade-config
nix flake update open-slop
./build check
./build deploy-native oracle
./build switch winsmuth
```

`deploy-native` builds on oracle itself. `./build deploy oracle` builds on winsmuth through binfmt emulation.

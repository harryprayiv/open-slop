{
  description = "open-slop: a Nix-configured local LLM machine, its catalogue, client, gateway, and typed Grace stages";

  # ==========================================================================
  # SHAPE
  # ==========================================================================
  #
  # nixpkgs' Haskell infrastructure with one compiler pinned, an overlay that
  # adds open-slop, hpkgs.shellFor for the dev shell. Not haskell.nix: this
  # package has thirteen ordinary dependencies and one git input, and
  # haskell.nix would add a hackage index, import-from-derivation and a
  # repackaging of Grace for no gain here.
  #
  # The derivation is COMMITTED at nix/open-slop.nix and regenerated with
  # `nix run .#cabal2nix`, so a consumer (neoblade-config, whose checks
  # evaluate every host) never needs import-from-derivation.
  #
  # ==========================================================================
  # TWO HASKELL PACKAGE SETS, AND WHY THE FLEET NEVER SEES GRACE
  # ==========================================================================
  #
  # llmq-grace links Grace, and that closure keeps a reference to the
  # compiler: 4.6 GB, measured 2026-09-23. Nothing that size goes to a Pi.
  # So the cabal file puts that executable behind the `grace` flag.
  #
  # Grace also brings its own pinned dependency versions, in its
  # dependencies/ directory. Putting those into the global package set
  # replaced the nixpkgs versions for every Haskell package built on every
  # host, so nothing downstream of them matched cache.nixos.org any more and
  # an aarch64 row compiled a slice of Hackage from source on each deploy.
  #
  # So there are two sets:
  #
  #   haskell.packages.ghc96   nixpkgs' set plus open-slop built with
  #                            grace = null. What the fleet gets. No Grace,
  #                            no Grace pins, everything else substitutes.
  #   graceHpkgs               that set extended with Grace's dependencies/
  #                            directory. Used only for llmq-grace, the
  #                            grace binary and the dev shell, on winsmuth.
  #
  #   pkgs.open-slop.llmq        llmq, the gateway, llmq-claims, llmq-bench
  #   pkgs.open-slop.llmq-grace  the Grace stage runner: 4.6 GB, workstation
  #
  # ==========================================================================
  # OUTPUTS A CONSUMER USES
  # ==========================================================================
  #
  #   overlays.default            pkgs.open-slop.{llmq,llmq-grace,catalogue,
  #                               llama-cpp-prismml,bonsai,gguf,grace}
  #   nixosModules.default        every server-side module; inert until a
  #                               services.open-slop.* option enables something
  #   homeManagerModules.default  programs.llmq
  #   lib.catalogue               the catalogue as data
  #
  # THE CONSUMER ADDS THE OVERLAY. The modules do not set nixpkgs.overlays
  # themselves: home-manager under useGlobalPkgs rejects that from a module.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-utils.url = "github:numtide/flake-utils";

    # The fork with OPENAI_BASE_URL in Grace.HTTP.getMethods, so `prompt`
    # reaches the gateway instead of api.openai.com. A path while it is
    # iterated on beside this repo; a forge URL once it is pushed.
    grace = {
      url = "github:harryprayiv/grace";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    llama-cpp-prismml = {
      url = "github:PrismML-Eng/llama.cpp";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      grace,
      llama-cpp-prismml,
    }:
    let
      compiler = "ghc96";

      overlay =
        final: prev:
        let
          hlib = final.haskell.lib;
          hpkgs = final.haskell.packages.${compiler};

          # The workstation set: the fleet's set plus Grace's own pinned
          # dependencies, openai among them. Nothing the fleet builds comes
          # from here.
          graceHpkgs = hpkgs.extend (
            final.lib.composeManyExtensions [
              (hlib.packagesFromDirectory { directory = "${grace}/dependencies"; })
              (hself: hsuper: {
                grace = hlib.dontCheck (hlib.dontHaddock hsuper.grace);
                openai = hlib.dontCheck hsuper.openai;
                open-slop = hsuper.callPackage ./nix/open-slop.nix { };
              })
            ]
          );
        in
        {
          haskell = prev.haskell // {
            packages = prev.haskell.packages // {
              ${compiler} = prev.haskell.packages.${compiler}.override (old: {
                overrides = final.lib.composeExtensions (old.overrides or (_: _: { })) (
                  hself: hsuper: {
                    # grace = null: the fleet build has the flag off and does
                    # not link Grace, and passing null keeps Grace and its
                    # dependency pins out of the fleet's evaluation entirely.
                    open-slop = hsuper.callPackage ./nix/open-slop.nix { grace = null; };
                  }
                );
              });
            };
          };

          open-slop = {
            catalogue = import ./catalogue;

            # What the fleet gets: llmq, the gateway, llmq-claims and
            # llmq-bench, built from the plain set, so every dependency is
            # the nixpkgs version and substitutes from the binary cache.
            llmq = hlib.justStaticExecutables (hlib.dontHaddock hpkgs.open-slop);

            # The Grace stage runner. The GHC check is off because it cannot
            # pass; the size is the known cost of linking Grace, and this is
            # a workstation tool, never part of a row's closure.
            llmq-grace = hlib.overrideCabal (
              hlib.justStaticExecutables (hlib.dontHaddock (hlib.enableCabalFlag graceHpkgs.open-slop "grace"))
            ) (_: { disallowGhcReference = false; });

            grace = hlib.justStaticExecutables (hlib.dontHaddock graceHpkgs.grace);

            # Exposed so the dev shell and anything else that needs Grace on
            # the workstation uses the same set as llmq-grace.
            inherit graceHpkgs;

            llama-cpp-prismml = final.callPackage ./nix/packages/llama-cpp-prismml.nix {
              src = llama-cpp-prismml;
              rev = llama-cpp-prismml.shortRev or "dirty";
              lastModifiedDate = llama-cpp-prismml.lastModifiedDate or "19700101000000";
            };

            bonsai = final.callPackage ./nix/packages/bonsai-weights.nix { };

            # Ordinary community quants of ordinary open-weight models, for
            # llama-server to serve. Separate from bonsai because those are
            # one fork's ternary packs. Added 2026-09-26, when the typed
            # pipeline moved to llama-server and needed the 7B as a declared
            # artifact rather than as a root-owned blob inside ollama.
            gguf = final.callPackage ./nix/packages/gguf-weights.nix { };
          };
        };
    in
    {
      overlays.default = overlay;

      nixosModules = {
        options = ./nix/modules/options.nix;
        server = ./nix/modules/server.nix;
        pinned = ./nix/modules/pinned.nix;
        hailo = ./nix/modules/hailo.nix;
        llama-server = ./nix/modules/llama-server.nix;
        gateway = ./nix/modules/gateway.nix;
        catalogue-check = ./nix/modules/catalogue-check.nix;
        default = {
          imports = [
            ./nix/modules/options.nix
            ./nix/modules/server.nix
            ./nix/modules/pinned.nix
            ./nix/modules/hailo.nix
            ./nix/modules/llama-server.nix
            ./nix/modules/gateway.nix
            ./nix/modules/catalogue-check.nix
          ];
        };
      };

      homeManagerModules.default = ./nix/modules/client.nix;

      lib.catalogue = import ./catalogue;
    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ overlay ];
        };

        hpkgs = pkgs.haskell.packages.${compiler};
        graceHpkgs = pkgs.open-slop.graceHpkgs;
      in
      {
        packages = {
          default = pkgs.open-slop.llmq;
          llmq = pkgs.open-slop.llmq;
          llmq-grace = pkgs.open-slop.llmq-grace;
          grace = pkgs.open-slop.grace;
          llama-cpp-prismml = pkgs.open-slop.llama-cpp-prismml;
        }
        // nixpkgs.lib.mapAttrs' (n: v: nixpkgs.lib.nameValuePair "bonsai-${n}" v) pkgs.open-slop.bonsai
        // nixpkgs.lib.mapAttrs' (n: v: nixpkgs.lib.nameValuePair "gguf-${n}" v) pkgs.open-slop.gguf;

        apps = {
          default = {
            type = "app";
            program = "${pkgs.open-slop.llmq}/bin/llmq";
          };

          gateway = {
            type = "app";
            program = "${pkgs.open-slop.llmq}/bin/open-slop-gateway";
          };

          claims = {
            type = "app";
            program = "${pkgs.open-slop.llmq}/bin/llmq-claims";
          };

          bench = {
            type = "app";
            program = "${pkgs.open-slop.llmq}/bin/llmq-bench";
          };

          grace = {
            type = "app";
            program = "${pkgs.open-slop.grace}/bin/grace";
          };

          # Regenerates nix/open-slop.nix from haskell/open-slop.cabal. Run
          # after editing the cabal file; commit the result.
          #
          # --flag grace, so the generated dependency list includes Grace:
          # without it the llmq-grace derivation, which turns the flag on,
          # configures with a dependency the package set was never told
          # about and fails with "missing or private dependencies: grace".
          # The fleet build passes grace = null, so listing it costs the
          # fleet nothing.
          #
          # The configureFlags line cabal2nix writes for that flag is then
          # removed, because it would turn the flag on for EVERY build from
          # this derivation, including the fleet's llmq, which would link
          # Grace and drag the compiler into a Pi's closure. The flag is
          # turned on per package by enableCabalFlag in the overlay.
          cabal2nix = {
            type = "app";
            program = toString (
              pkgs.writeShellScript "open-slop-cabal2nix" ''
                set -euo pipefail
                cd "$(git rev-parse --show-toplevel)"
                ${pkgs.cabal2nix}/bin/cabal2nix --flag grace ./haskell > nix/open-slop.nix.new
                # cabal2nix writes src = ./haskell (or ./. when run from inside
                # it); this file lives in nix/, one directory over.
                sed -i -E 's@src = \./(haskell|\.);@src = ../haskell;@' nix/open-slop.nix.new
                sed -i -E '/^  configureFlags = \[ "-fgrace" \];$/d' nix/open-slop.nix.new
                if grep -q 'fgrace' nix/open-slop.nix.new; then
                  echo "cabal2nix wrote the grace flag somewhere unexpected; check nix/open-slop.nix.new" >&2
                  exit 1
                fi
                if ! grep -q '^, grace,\|[ ,]grace[ ,]' nix/open-slop.nix.new; then
                  echo "grace is missing from the generated dependency list" >&2
                  exit 1
                fi
                mv nix/open-slop.nix.new nix/open-slop.nix
                echo "wrote nix/open-slop.nix"
              ''
            );
          };
        };

        checks = {
          open-slop-tests = hpkgs.open-slop;
        };

        # The workstation shell: the Grace set, so `cabal build --flag grace`
        # finds Grace and its pinned dependencies.
        devShells.default = graceHpkgs.shellFor {
          packages = _: [ graceHpkgs.open-slop ];

          nativeBuildInputs = with graceHpkgs; [
            cabal-install
            haskell-language-server
            ghcid
            fourmolu
            pkgs.cabal2nix
            pkgs.fzf
            pkgs.xsel
            pkgs.jq
            pkgs.open-slop.grace
          ];

          withHoogle = true;
        };
      }
    );
}
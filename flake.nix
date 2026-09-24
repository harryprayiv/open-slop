{
  description = "open-slop: a Nix-configured local LLM machine, its catalogue, client, gateway, and typed Grace stages";

  # ==========================================================================
  # SHAPE
  # ==========================================================================
  #
  # nixpkgs' Haskell infrastructure with one compiler pinned, an overlay that
  # adds Grace's package set, hpkgs.shellFor for the dev shell. Not
  # haskell.nix: this package has thirteen ordinary dependencies and one git
  # input, and haskell.nix would add a hackage index, import-from-derivation
  # and a repackaging of Grace for no gain here.
  #
  # The derivation is COMMITTED at nix/open-slop.nix and regenerated with
  # `nix run .#cabal2nix`, so a consumer (neoblade-config, whose checks
  # evaluate every host) never needs import-from-derivation.
  #
  # ==========================================================================
  # WHY THERE ARE TWO PACKAGES FROM ONE CABAL FILE
  # ==========================================================================
  #
  # llmq-grace links Grace, and that closure keeps a reference to the
  # compiler: 4.6 GB, measured 2026-09-23. Nothing that size goes to a Pi.
  # So the cabal file puts that executable behind the `grace` flag, off by
  # default:
  #
  #   pkgs.open-slop.llmq        llmq and the gateway, no Grace, small
  #   pkgs.open-slop.llmq-grace  the stage runner, with Grace, large
  #
  # The generated derivation is made with the flag ON (`cabal2nix --flag
  # grace`), so Grace is in the dependency list for both; the flag-off build
  # does not link it, and Grace being a build input costs time rather than
  # closure.
  #
  # ==========================================================================
  # OUTPUTS A CONSUMER USES
  # ==========================================================================
  #
  #   overlays.default            pkgs.open-slop.{llmq,llmq-grace,catalogue,
  #                               llama-cpp-prismml,bonsai,grace}
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
      url = "path:/home/bismuth/git/grace";
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
        in
        {
          haskell = prev.haskell // {
            packages = prev.haskell.packages // {
              ${compiler} = prev.haskell.packages.${compiler}.override (old: {
                overrides = final.lib.composeExtensions (old.overrides or (_: _: { })) (
                  hself: hsuper: {
                    grace = hlib.dontCheck (
                      hlib.dontHaddock (hsuper.callPackage "${grace}/dependencies/grace.nix" { })
                    );
                    open-slop = hsuper.callPackage ./nix/open-slop.nix { };
                  }
                );
              });
            };
          };

          open-slop = {
            catalogue = import ./catalogue;

            # What the fleet gets: llmq and the gateway, the `grace` flag at
            # its default of off, so nothing here links Grace and
            # justStaticExecutables' GHC check passes as it should.
            llmq = hlib.justStaticExecutables (hlib.dontHaddock hpkgs.open-slop);

            # The Grace stage runner. The GHC check is off because it cannot
            # pass; the size is the known cost of linking Grace, and this is
            # a workstation tool, never part of a row's closure.
            llmq-grace = hlib.overrideCabal (
              hlib.justStaticExecutables (hlib.dontHaddock (hlib.enableCabalFlag hpkgs.open-slop "grace"))
            ) (_: { disallowGhcReference = false; });

            grace = hlib.justStaticExecutables (hlib.dontHaddock hpkgs.grace);

            llama-cpp-prismml = final.callPackage ./nix/packages/llama-cpp-prismml.nix {
              src = llama-cpp-prismml;
              rev = llama-cpp-prismml.shortRev or "dirty";
              lastModifiedDate = llama-cpp-prismml.lastModifiedDate or "19700101000000";
            };
            bonsai = final.callPackage ./nix/packages/bonsai-weights.nix { };
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
          overlays = [
            grace.overlays.${compiler}
            overlay
          ];
        };

        hpkgs = pkgs.haskell.packages.${compiler};
      in
      {
        packages = {
          default = pkgs.open-slop.llmq;
          llmq = pkgs.open-slop.llmq;
          llmq-grace = pkgs.open-slop.llmq-grace;
          grace = pkgs.open-slop.grace;
          llama-cpp-prismml = pkgs.open-slop.llama-cpp-prismml;
        }
        // nixpkgs.lib.mapAttrs' (n: v: nixpkgs.lib.nameValuePair "bonsai-${n}" v) pkgs.open-slop.bonsai;

        apps = {
          default = {
            type = "app";
            program = "${pkgs.open-slop.llmq}/bin/llmq";
          };

          gateway = {
            type = "app";
            program = "${pkgs.open-slop.llmq}/bin/open-slop-gateway";
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

        devShells.default = hpkgs.shellFor {
          packages = _: [ (hpkgs.open-slop.override { }) ];

          nativeBuildInputs = with hpkgs; [
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
{
  description = "open-slop: a Nix-configured local LLM machine, its catalogue, client, and (later) gateway and runner";

  # ==========================================================================
  # SHAPE
  # ==========================================================================
  #
  # Same conventions as chase: flake-utils.eachDefaultSystem, nixpkgs'
  # Haskell infrastructure with one compiler pinned, an overlay that adds
  # Grace's package set, hpkgs.shellFor for the dev shell.
  #
  # One difference, on purpose. chase builds itself with callCabal2nix, which
  # runs cabal2nix at evaluation time (import-from-derivation). open-slop is
  # imported by a fleet configuration whose checks evaluate every host, so
  # its derivation is COMMITTED at nix/open-slop.nix and regenerated with
  # `nix run .#cabal2nix` after the cabal file changes. A consumer evaluates
  # open-slop without building anything first.
  #
  # ==========================================================================
  # OUTPUTS A CONSUMER USES
  # ==========================================================================
  #
  #   overlays.default            pkgs.open-slop.{llmq,catalogue,
  #                               llama-cpp-prismml,bonsai,grace}
  #   nixosModules.default        every server-side module; inert until a
  #                               services.open-slop.* option enables something
  #   homeManagerModules.default  programs.llmq
  #   lib.catalogue               the catalogue as data
  #
  # THE CONSUMER ADDS THE OVERLAY. The modules do not set nixpkgs.overlays
  # themselves: a home-manager configuration running with useGlobalPkgs
  # rejects nixpkgs.overlays from a module, and the same overlay set twice
  # (once by a module, once by the consumer) would apply it twice. So the
  # contract is two lines: add overlays.default to the package set, import
  # the modules.
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-utils.url = "github:numtide/flake-utils";

    grace = {
      url = "github:Gabriella439/grace";
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

      # Defined once, outside eachDefaultSystem, so a consumer can apply it
      # on any system.
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
            llmq = hlib.justStaticExecutables hpkgs.open-slop;
            grace = hlib.justStaticExecutables hpkgs.grace;
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
        catalogue-check = ./nix/modules/catalogue-check.nix;
        default = {
          imports = [
            ./nix/modules/options.nix
            ./nix/modules/server.nix
            ./nix/modules/pinned.nix
            ./nix/modules/hailo.nix
            ./nix/modules/llama-server.nix
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
          grace = pkgs.open-slop.grace;
          llama-cpp-prismml = pkgs.open-slop.llama-cpp-prismml;
        }
        // nixpkgs.lib.mapAttrs' (n: v: nixpkgs.lib.nameValuePair "bonsai-${n}" v) pkgs.open-slop.bonsai;

        apps = {
          default = {
            type = "app";
            program = "${pkgs.open-slop.llmq}/bin/llmq";
          };

          # Regenerates nix/open-slop.nix from haskell/open-slop.cabal. Run
          # after editing the cabal file; commit the result.
          cabal2nix = {
            type = "app";
            program = toString (
              pkgs.writeShellScript "open-slop-cabal2nix" ''
                set -euo pipefail
                cd "$(git rev-parse --show-toplevel)"
                ${pkgs.cabal2nix}/bin/cabal2nix ./haskell > nix/open-slop.nix.new
                # cabal2nix writes src = ./haskell (or ./. when run from inside
                # it); this file lives in nix/, one directory over.
                sed -i -E 's@src = \./(haskell|\.);@src = ../haskell;@' nix/open-slop.nix.new
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
          packages = _: [ hpkgs.open-slop ];

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
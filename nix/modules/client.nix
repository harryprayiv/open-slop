# The client side: llmq on PATH, with the catalogue and this machine's
# endpoints baked into its environment.
#
# A home-manager module. The consumer says which rows serve which backends
# and at what address; open-slop turns that plus the catalogue into the JSON
# llmq reads, and wraps the binary so $OPEN_SLOP_CATALOGUE points at it. Nothing
# in open-slop knows an address; every one comes from `endpoints` here.
#
# ============================================================================
# THE CATALOGUE JSON IS BUILT AT EVALUATION, THE MODEL LIST AT RUNTIME
# ============================================================================
#
# Ports, budgets and blurbs are eval-time facts. What a server actually has
# loaded is asked of the server every time llmq runs, because the consumer's
# NixOS configuration for an inference row is not visible to this
# home-manager evaluation, and because what SHOULD be pulled and what IS are
# different questions.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.llmq;
  inherit (lib) types;

  catalogue = lib.recursiveUpdate (import ../../catalogue) cfg.catalogue.extra;

  endpoints = lib.concatLists (
    lib.mapAttrsToList (
      row: r:
      map (backend: {
        inherit row backend;
        url = "http://${r.address}:${toString catalogue.backends.${backend}.port}";
      }) r.backends
    ) cfg.endpoints
  );

  catalogueJson = pkgs.writeText "open-slop-catalogue.json" (
    builtins.toJSON {
      inherit (catalogue) backends models;
      inherit endpoints;
    }
  );

  wrapped = pkgs.symlinkJoin {
    name = "llmq";
    paths = [ cfg.package ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/llmq \
        --set-default OPEN_SLOP_CATALOGUE ${catalogueJson} \
        --prefix PATH : ${lib.makeBinPath [ pkgs.fzf pkgs.xsel ]} \
        ${lib.optionalString (cfg.keyFile != null) "--set-default LLMQ_KEY_FILE ${lib.escapeShellArg cfg.keyFile}"}
    '';
  };
in
{
  options.programs.llmq = {
    enable = lib.mkEnableOption "llmq, the open-slop client";

    package = lib.mkOption {
      type = types.package;
      default = pkgs.open-slop.llmq;
      defaultText = "pkgs.open-slop.llmq";
    };

    endpoints = lib.mkOption {
      type = types.attrsOf (
        types.submodule {
          options = {
            address = lib.mkOption {
              type = types.str;
              example = "192.168.8.173";
              description = "Where the row's inference servers listen. Ports come from the catalogue.";
            };
            backends = lib.mkOption {
              type = types.listOf types.str;
              example = [ "cpu" "hailo" ];
              description = "Which catalogue backends this row runs. Each becomes one endpoint.";
            };
          };
        }
      );
      default = { };
      description = "Inference rows this machine may talk to, keyed by row name.";
    };

    keyFile = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Bearer key file for the gateway, once there is one. Unused until then.";
    };

    catalogue.extra = lib.mkOption {
      type = types.attrs;
      default = { };
      description = "Merged over the shipped catalogue with lib.recursiveUpdate. Keep it equal to the server side's.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = lib.mapAttrsToList (row: r: {
      assertion = lib.all (b: catalogue.backends ? ${b}) r.backends;
      message = "programs.llmq.endpoints.${row}.backends names a backend the catalogue does not have: ${lib.concatStringsSep ", " (lib.filter (b: !(catalogue.backends ? ${b})) r.backends)}";
    }) cfg.endpoints;

    home.packages = [ wrapped ];
  };
}

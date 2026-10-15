# The client side: llmq on PATH, with the catalogue and this machine's
# endpoints baked into its environment.
#
# A home-manager module. The consumer says which rows serve which backends
# and at what address; open-slop turns that plus the catalogue into the JSON
# llmq reads, and wraps the binary so $OPEN_SLOP_CATALOGUE points at it and
# $OPEN_SLOP_PROMPTS at the shipped prompts/ directory. llmq-index also gets
# pandoc and pdftotext by store path and its rag defaults. Nothing
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

  # llmq-index's defaults, each only when set, so a flag or an exported
  # variable still wins.
  ragFlags = lib.concatStringsSep " " (
    lib.mapAttrsToList (var: v: "--set-default ${var} ${lib.escapeShellArg v}") (
      lib.filterAttrs (_: v: v != null) {
        OPEN_SLOP_RAG_DB = cfg.rag.db;
        OPEN_SLOP_RAG_EMBED_AT = cfg.rag.embedAt;
        OPEN_SLOP_RAG_EMBED_MODEL = cfg.rag.embedModel;
        OPEN_SLOP_RAG_CHAT_AT = cfg.rag.chatAt;
        OPEN_SLOP_RAG_CHAT_MODEL = cfg.rag.chatModel;
      }
    )
  );

  wrapped = pkgs.symlinkJoin {
    name = "llmq";
    paths = [ cfg.package ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    # Every binary in the package is wrapped, not only llmq. llmq-bench and
    # llmq-claims read the same catalogue and were started without it, so
    # each run needed --catalogue and a store path found by hand.
    postBuild = ''
      for bin in $out/bin/*; do
        wrapProgram "$bin" \
          --set-default OPEN_SLOP_CATALOGUE ${catalogueJson} \
          --set-default OPEN_SLOP_PROMPTS ${../../prompts} \
          --prefix PATH : ${lib.makeBinPath [ pkgs.fzf pkgs.xsel ]} \
          --set-default OPEN_SLOP_PANDOC ${lib.getExe pkgs.pandoc} \
          --set-default OPEN_SLOP_PDFTOTEXT ${lib.getBin pkgs.poppler-utils}/bin/pdftotext \
          ${ragFlags} \
          ${lib.optionalString (cfg.keyFile != null) "--set-default LLMQ_KEY_FILE ${lib.escapeShellArg cfg.keyFile}"}
      done
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

    # llmq-index's defaults. The database is on whichever machine has
    # services.open-slop.rag; llmq-index runs there and reaches it over the
    # local socket. The servers are named row/backend, as llmq shows them,
    # and must be in `endpoints` above.
    rag = {
      db = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "dbname=llmq_rag";
        description = "libpq connection string. Unset means dbname=llmq_rag on the local socket.";
      };
      embedAt = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "oracle/cpu";
        description = "The endpoint that embeds chunks and questions.";
      };
      embedModel = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "nomic-embed-text";
        description = "Embedding model. Changing it means re-ingesting; the old vectors stay until llmq-index prune --model.";
      };
      chatAt = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "oracle/cpu";
        description = "The endpoint llmq-index ask sends sources and the question to.";
      };
      chatModel = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "qwen2.5:7b";
        description = "Chat model for llmq-index ask.";
      };
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
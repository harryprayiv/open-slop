# The client side: llmq on PATH, with the catalogue and this machine's
# endpoints baked into its environment.
#
# On the machine that holds llmq-index's database it can also run the
# gateway that serves the index and its web page, as a user service
# (indexGateway below). It runs as the user because the database lets its
# owner in over the local socket and no one else.
#
# A home-manager module. The consumer says which rows serve which backends
# and at what address; open-slop turns that plus the catalogue into the JSON
# llmq reads, and wraps the binary so $OPEN_SLOP_CATALOGUE points at it and
# $OPEN_SLOP_PROMPTS at the shipped prompts/ directory. llmq-index also gets
# pandoc and pdftotext by store path and its rag defaults, the reranker
# among them, and chase by store path when `chase` is given; llmq-agent gets git, its model defaults and, when given,
# tricorder by store path. Nothing in open-slop knows an address; every one
# comes from `endpoints` here.
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
  ig = cfg.indexGateway;
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
        OPEN_SLOP_RAG_RERANK_AT = cfg.rag.rerankAt;
        OPEN_SLOP_RAG_RERANK_MODEL = cfg.rag.rerankModel;
        OPEN_SLOP_AGENT_CHAT_AT = cfg.agent.chatAt;
        OPEN_SLOP_AGENT_MODEL = cfg.agent.model;
        TRICORDER = if cfg.agent.tricorder == null then null else lib.getExe' cfg.agent.tricorder "tricorder";
        OPEN_SLOP_CHASE = if cfg.chase == null then null else lib.getExe' cfg.chase "chase";
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
          --prefix PATH : ${lib.makeBinPath [ pkgs.fzf pkgs.xsel pkgs.git ]} \
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

    # chase is taken from its own flake, as tricorder is, and only where
    # llmq-index ingests: building it builds Grace and ghc-lib-parser, which
    # no Pi row should have to. Without it, a root's .inference/.llmqchase
    # finds chase on PATH or makes no bundles, and says so.
    chase = lib.mkOption {
      type = types.nullOr types.package;
      default = null;
      example = lib.literalExpression "inputs.chase.packages.\${pkgs.system}.chase";
      description = "chase, which llmq-index ingest runs over a root that has a .inference/.llmqchase file, so the index holds bundles made from the same code. Unset means whatever chase is on PATH.";
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
      rerankAt = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "oracle/rerank";
        description = "The reranking llama-server (services.open-slop.reranker on that row). Unset means sources are chosen by similarity alone.";
      };
      rerankModel = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "bge-reranker-v2-m3";
        description = "The reranker's alias, as services.open-slop.reranker.alias sets it.";
      };
    };

    # llmq-agent's defaults. Without its own settings it uses the rag chat
    # model. tricorder is taken from its own flake, which builds with
    # haskell.nix; see docs/manual/13-llmq-agent.md for the input and the
    # binary caches it needs.
    agent = {
      chatAt = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "oracle/llamacpp";
        description = "The endpoint llmq-agent asks for decisions. Unset means rag.chatAt.";
      };
      model = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "qwen2.5-coder:7b";
        description = "The model llmq-agent uses. Unset means rag.chatModel.";
      };
      tricorder = lib.mkOption {
        type = types.nullOr types.package;
        default = null;
        example = lib.literalExpression "inputs.tricorder.packages.\${pkgs.system}.tricorder";
        description = "tricorder, the build oracle for Haskell. Unset means whatever tricorder is on PATH when llmq-agent runs.";
      };
    };

    catalogue.extra = lib.mkOption {
      type = types.attrs;
      default = { };
      description = "Merged over the shipped catalogue with lib.recursiveUpdate. Keep it equal to the server side's.";
    };

    # The gateway that serves the index, on the machine with the database
    # (services.open-slop.rag). It is not services.open-slop.gateway: that
    # one fronts an inference row's own backends as a DynamicUser, and the
    # database admits only its owner. This one runs as that owner, with this
    # machine's catalogue (the inference rows in `endpoints`) and the rag
    # settings above, so its answers come from the same servers as
    # llmq-index ask. The page asks for a key from keysFile and sends it on
    # every call.
    #
    # A user service runs while the user has a session, unless lingering is
    # on: users.users.NAME.linger = true in the NixOS configuration keeps it
    # running from boot.
    indexGateway = {
      enable = lib.mkEnableOption "open-slop-gateway --index as a user service, serving the index and its web page";

      host = lib.mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Bind address. On loopback, reach it from another machine with ssh -L. Anything else needs plaintextLan, since this service has no TLS settings.";
      };

      port = lib.mkOption {
        type = types.port;
        default = 8443;
      };

      plaintextLan = lib.mkOption {
        type = types.bool;
        default = false;
        description = "Bind a LAN address without TLS. Keys then cross the network in clear.";
      };

      keysFile = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "/run/secrets/llmq-index-gateway-keys";
        description = ''
          One `name key` per line, keys of 24 characters or more. A path
          outside the store that this user can read, for example a sops
          secret with owner set to the user.
        '';
      };

      web = lib.mkOption {
        type = types.nullOr types.package;
        default = null;
        example = lib.literalExpression "inputs.open-slop.packages.\${pkgs.system}.web";
        description = "The built web page (open-slop's web output), served at /. Unset means the API alone.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions =
      lib.mapAttrsToList (row: r: {
        assertion = lib.all (b: catalogue.backends ? ${b}) r.backends;
        message = "programs.llmq.endpoints.${row}.backends names a backend the catalogue does not have: ${lib.concatStringsSep ", " (lib.filter (b: !(catalogue.backends ? ${b})) r.backends)}";
      }) cfg.endpoints
      ++ lib.optionals ig.enable [
        {
          assertion = ig.keysFile != null;
          message = "programs.llmq.indexGateway needs keysFile: the page and every client send a key from it.";
        }
        {
          assertion = lib.all (v: v != null) [ cfg.rag.embedAt cfg.rag.embedModel cfg.rag.chatAt cfg.rag.chatModel ];
          message = "programs.llmq.indexGateway answers with the rag settings; set programs.llmq.rag.embedAt, embedModel, chatAt and chatModel.";
        }
        {
          assertion = lib.elem ig.host [ "127.0.0.1" "::1" "localhost" ] || ig.plaintextLan;
          message = "programs.llmq.indexGateway binds ${ig.host} without TLS; set plaintextLan = true to accept that keys cross the network in clear, or bind loopback and use ssh -L.";
        }
      ];

    home.packages = [ wrapped ];

    systemd.user.services.llmq-index-gateway = lib.mkIf ig.enable {
      Unit.Description = "open-slop gateway serving llmq-index on ${ig.host}:${toString ig.port}";
      Service = {
        ExecStart = lib.escapeShellArgs (
          [
            "${wrapped}/bin/open-slop-gateway"
            "--catalogue"
            "${catalogueJson}"
            "--keys"
            ig.keysFile
            "--host"
            ig.host
            "--port"
            (toString ig.port)
            "--index"
          ]
          ++ lib.optionals (ig.web != null) [
            "--web"
            "${ig.web}"
          ]
          ++ lib.optional ig.plaintextLan "--plaintext-lan"
        );
        Restart = "on-failure";
        RestartSec = 5;
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
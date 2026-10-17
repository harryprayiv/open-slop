# A second llama-server, started with --reranking, for llmq-index.
#
# One of open-slop's NixOS modules. Inert until
# services.open-slop.reranker.enable.
#
# ============================================================================
# WHAT IT IS FOR
# ============================================================================
#
# llmq-index finds candidates by embedding and full-text search, then sends
# the best few here with the question. A cross-encoder reads the question
# and each chunk together and scores whether the chunk answers it. See
# haskell/src/OpenSlop/Rag/Rerank.hs for why the embedding alone cannot.
#
# ============================================================================
# A SEPARATE INSTANCE, NOT THE llamacpp ONE
# ============================================================================
#
# llama-server loads one model at start, and --reranking changes what the
# server does: it pools to a single relevance score and serves /v1/rerank
# instead of chat. So this is its own unit, its own user and its own port,
# the catalogue's `rerank` backend, beside the chat server on `llamacpp`.
#
# ============================================================================
# UPSTREAM llama.cpp BY DEFAULT, RESIDENT BY DEFAULT
# ============================================================================
#
# The package defaults to nixpkgs' llama-cpp rather than PrismML's fork.
# The fork exists for its ternary kernels, which a reranker does not use,
# and upstream is where /v1/rerank is maintained; nixpkgs also has it built
# for aarch64 in the binary cache.
#
# A reranker of about 600 MB is small next to the chat models, and every
# question that uses it pays the start time if it is not running, so it
# starts at boot unless autoStart is false.
#
# ============================================================================
# BATCH SIZE IS THE DOCUMENT LIMIT
# ============================================================================
#
# A reranker is a non-causal model: the question and one whole document go
# through it in a single physical batch, so --ubatch-size is the longest
# question-plus-document it can score. ctx, --batch-size and --ubatch-size
# are all set from the catalogue's rerank ctx, and llmq-index cuts each
# document to 2,400 characters, which is well inside it.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.open-slop;
  rcfg = cfg.reranker;
  catalogue = lib.recursiveUpdate (import ../../catalogue) cfg.catalogue.extra;
  backend = catalogue.backends.rerank;
  inherit (lib) types;
in
{
  options.services.open-slop.reranker = {
    enable = lib.mkEnableOption "a reranking llama-server for llmq-index";

    package = lib.mkOption {
      type = types.package;
      default = pkgs.llama-cpp;
      defaultText = "pkgs.llama-cpp";
      description = "The llama.cpp build to run. Upstream's; the reranker needs no ternary kernels.";
    };

    model = lib.mkOption {
      type = types.package;
      example = lib.literalExpression ''pkgs.fetchurl { url = "..."; hash = "..."; }'';
      description = "A reranker GGUF in the store, declared by the consumer.";
    };

    alias = lib.mkOption {
      type = types.str;
      example = "bge-reranker-v2-m3";
      description = "The model name clients send, and what llmq-index's rag.rerankModel names.";
    };

    host = lib.mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = ''
        Bind address. 0.0.0.0 with services.open-slop.openFirewallFor serves
        the LAN, the same arrangement as the other backends.
      '';
    };

    threads = lib.mkOption {
      type = types.ints.positive;
      default = 4;
      description = "CPU threads. A Pi 5 has four cores.";
    };

    autoStart = lib.mkOption {
      type = types.bool;
      default = true;
      description = "Start at boot and keep running. Off means started on demand.";
    };

    extraArgs = lib.mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Appended to the llama-server command line.";
    };
  };

  config = lib.mkIf rcfg.enable {
    users.users.llama-reranker = {
      isSystemUser = true;
      group = "llama-reranker";
      description = "llama-server reranking endpoint";
    };
    users.groups.llama-reranker = { };

    systemd.services.llama-reranker = {
      description = "llama-server reranker (${rcfg.alias}) on ${rcfg.host}:${toString backend.port}";
      wantedBy = lib.optional rcfg.autoStart "multi-user.target";
      after = [ "network.target" ];

      serviceConfig = {
        ExecStart = lib.escapeShellArgs (
          [
            (lib.getExe' rcfg.package "llama-server")
            "--model"
            "${rcfg.model}"
            "--alias"
            rcfg.alias
            "--host"
            rcfg.host
            "--port"
            (toString backend.port)
            "--reranking"
            "--ctx-size"
            (toString backend.ctx)
            "--batch-size"
            (toString backend.ctx)
            "--ubatch-size"
            (toString backend.ctx)
            "--threads"
            (toString rcfg.threads)
            "--n-gpu-layers"
            "0"
            "--parallel"
            "1"
            "--no-warmup"
          ]
          ++ rcfg.extraArgs
        );
        Restart = "on-failure";
        RestartSec = 5;
        User = "llama-reranker";
        Group = "llama-reranker";
        TimeoutStartSec = 300;

        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
      };
    };

    networking.firewall.extraCommands = lib.mkIf (rcfg.host != "127.0.0.1") (
      lib.concatMapStrings (range: ''
        iptables -A nixos-fw -p tcp -s ${range} --dport ${toString backend.port} -j nixos-fw-accept
      '') cfg.openFirewallFor
    );

    assertions = [
      {
        assertion = !(lib.elem backend.port [ 11434 8000 catalogue.backends.llamacpp.port ]);
        message = "the catalogue's rerank port collides with ollama (11434), hailo-ollama (8000) or the llamacpp backend.";
      }
    ];
  };
}

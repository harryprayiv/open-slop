# llama-server from PrismML's fork, serving one store-pinned GGUF.
#
# One of open-slop's NixOS modules.
#
# One model per instance, because llama-server loads its model at start and
# its context length is a start-time flag, not a request field. A second
# model is a second instance on a second port; this module runs one. The
# port and context come from the catalogue's llamacpp backend, so llmq and
# the server agree on both by construction.
#
# ============================================================================
# NOT RESIDENT BY DEFAULT
# ============================================================================
#
# A 27B ternary model holds 6 to 7 GB for as long as the server runs, and a
# 16 GB row also runs ollama, whose models take 5 GB each while loaded. With
# autoStart = false the unit exists and starts on `systemctl start`, so a job
# can bring it up and stop it, and measuring can be done with ollama stopped.
#
# ============================================================================
# LOOPBACK ONLY
# ============================================================================
#
# The server has no authentication. It binds 127.0.0.1 and the gateway is
# what the LAN talks to. Until the gateway exists, reach it over an ssh port
# forward; llmq's endpoint for it is then http://127.0.0.1:<port> on the
# forwarding machine.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.open-slop;
  lcfg = cfg.llamaServer;
  catalogue = lib.recursiveUpdate (import ../../catalogue) cfg.catalogue.extra;
  backend = catalogue.backends.llamacpp;
  inherit (lib) types;
in
{
  options.services.open-slop.llamaServer = {
    enable = lib.mkEnableOption "llama-server from PrismML's llama.cpp fork";

    package = lib.mkOption {
      type = types.package;
      default = pkgs.open-slop.llama-cpp-prismml;
      defaultText = "pkgs.open-slop.llama-cpp-prismml";
      description = "The llama.cpp build to run. Must carry the ternary kernels.";
    };

    model = lib.mkOption {
      type = types.package;
      example = lib.literalExpression ''pkgs.open-slop.bonsai."2-27b-pq2_0"'';
      description = "A GGUF file in the store. Use an entry of pkgs.open-slop.bonsai.";
    };

    alias = lib.mkOption {
      type = types.str;
      example = "bonsai-2-27b";
      description = ''
        The name clients use in the model field, and the key the catalogue's
        models.llamacpp entry is looked up by. llama-server would otherwise
        report the file name.
      '';
    };

    threads = lib.mkOption {
      type = types.ints.positive;
      default = 4;
      description = "CPU threads. A Pi 5 has four cores; more than that only adds contention.";
    };

    reasoning = lib.mkOption {
      type = types.enum [ "on" "off" "auto" ];
      default = "off";
      description = ''
        Bonsai thinks by default at its highest effort, and every thinking
        token comes out of the same slow decode as the answer. Off for batch
        work; on for the REPL if you want to see it reason.
      '';
    };

    autoStart = lib.mkOption {
      type = types.bool;
      default = false;
      description = "Start at boot and keep running. Off means started on demand.";
    };

    extraArgs = lib.mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "--reasoning-budget" "1024" ];
      description = "Appended to the llama-server command line.";
    };
  };

  config = lib.mkIf lcfg.enable {
    users.users.llama-server = {
      isSystemUser = true;
      group = "llama-server";
      description = "llama-server inference endpoint";
    };
    users.groups.llama-server = { };

    systemd.services.llama-server = {
      description = "llama-server (${lcfg.alias}) on 127.0.0.1:${toString backend.port}";
      wantedBy = lib.optional lcfg.autoStart "multi-user.target";
      after = [ "network.target" ];

      serviceConfig = {
        ExecStart = lib.escapeShellArgs (
          [
            (lib.getExe' lcfg.package "llama-server")
            "--model"
            "${lcfg.model}"
            "--alias"
            lcfg.alias
            "--host"
            "127.0.0.1"
            "--port"
            (toString backend.port)
            "--ctx-size"
            (toString backend.ctx)
            "--threads"
            (toString lcfg.threads)
            "--n-gpu-layers"
            "0"
            "--flash-attn"
            "on"
            "--jinja"
            "--reasoning"
            lcfg.reasoning
            # One request at a time. Parallel slots each hold a context.
            "--parallel"
            "1"
            "--no-warmup"
          ]
          ++ lcfg.extraArgs
        );
        Restart = "on-failure";
        RestartSec = 5;
        User = "llama-server";
        Group = "llama-server";

        # The whole model is read at start; give it time on an SD card.
        TimeoutStartSec = 600;

        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        # llama.cpp mmaps the weights from the store, which is world-readable.
        # Nothing here needs a state directory.
      };
    };

    environment.systemPackages = [ lcfg.package ];

    assertions = [
      {
        assertion = backend.port != 11434 && backend.port != 8000;
        message = "the catalogue's llamacpp port collides with ollama (11434) or hailo-ollama (8000).";
      }
    ];
  };
}

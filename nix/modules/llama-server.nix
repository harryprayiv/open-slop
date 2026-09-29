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
# WHO MAY START AND STOP IT
# ============================================================================
#
# Starting an on-demand server needs root, and a sudo password prompt cannot
# be answered by anything unattended: an overnight benchmark, a job, a
# command run over ssh from another machine. On 2026-09-28 that is what
# kept llama-server out of every benchmark run.
#
# `controlledBy` names the users who may run exactly
#   sudo systemctl start|stop|restart llama-server.service
# without a password, and nothing else. The rule is written out in full for
# each verb, so it cannot be widened by an argument.
#
# ============================================================================
# THE BIND ADDRESS IS AN OPTION, LOOPBACK BY DEFAULT
# ============================================================================
#
# The server has no authentication, like ollama and hailo-ollama. Those two
# bind the LAN on oracle behind one firewall rule per allowed range, and
# until the gateway exists this backend is reachable the same way when
# `host` is set to 0.0.0.0. The default stays 127.0.0.1: a consumer that
# does not say otherwise gets a server nothing outside the machine can
# reach, and llmq on another machine reports it as no answer rather than
# talking to it. Measured 2026-09-20: with the default, llmq's probe from
# winsmuth timed out at eight seconds and the model was not listed.
#
# ============================================================================
# SAMPLING IS DETERMINISTIC BY DEFAULT
# ============================================================================
#
# llama-server's command-line sampling settings become the defaults for any
# request that does not set its own. Grace sends neither a temperature nor
# a seed, so without these flags every Grace call sampled at the server's
# built-in temperature and two runs of the same prompt differed.
#
# That made every comparison between prompt versions meaningless: on
# 2026-09-26 one chase annotation run produced five invariants for
# Pelotero.DB.Pool and the next, with a changed template, produced two, and
# there was no way to say whether the template or the dice caused the drop.
#
# The temperature comes from the catalogue's llamacpp backend, so the
# catalogue remains the one place that states a backend's sampling. The
# seed is fixed. A client that sends its own values, as llmq and the
# gateway do, still overrides both; this only sets what a silent client
# gets.
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
      example = lib.literalExpression ''pkgs.fetchurl { url = "..."; hash = "..."; }'';
      description = "A GGUF file in the store, declared by the consumer.";
    };

    host = lib.mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = ''
        Bind address. 0.0.0.0 with services.open-slop.openFirewallFor serves
        the LAN, the same arrangement as the ollama and hailo backends.
      '';
    };

    alias = lib.mkOption {
      type = types.str;
      example = "qwen2.5-coder-7b";
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

    temperature = lib.mkOption {
      type = types.nullOr types.float;
      default = backend.temperature;
      defaultText = lib.literalExpression "catalogue.backends.llamacpp.temperature";
      description = ''
        Default sampling temperature for requests that do not set one. The
        catalogue's value by default, which is 0.0: deterministic. null
        leaves llama-server's built-in default in force.
      '';
    };

    seed = lib.mkOption {
      type = types.nullOr types.int;
      default = 1;
      description = ''
        Default seed for requests that do not set one. Fixed so that a
        client which sends no sampling parameters, such as Grace, gets the
        same answer to the same prompt. null leaves llama-server's random
        default in force.
      '';
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

    controlledBy = lib.mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "bismuth" ];
      description = ''
        Users who may start, stop and restart llama-server.service with sudo
        and no password, and do nothing else with it. For an on-demand server
        that an unattended job or a remote command has to bring up.
      '';
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
      description = "llama-server (${lcfg.alias}) on ${lcfg.host}:${toString backend.port}";
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
            lcfg.host
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
          ++ lib.optionals (lcfg.temperature != null) [
            "--temp"
            (toString lcfg.temperature)
          ]
          ++ lib.optionals (lcfg.seed != null) [
            "--seed"
            (toString lcfg.seed)
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

    # Exact commands only. sudo compares the full path of what is run, and
    # `systemctl` on a user's PATH resolves to /run/current-system/sw/bin.
    # Both spellings of the unit are listed because both are what people
    # type.
    security.sudo.extraRules = lib.mkIf (lcfg.controlledBy != [ ]) [
      {
        users = lcfg.controlledBy;
        commands = lib.concatMap (verb: [
          {
            command = "/run/current-system/sw/bin/systemctl ${verb} llama-server.service";
            options = [ "NOPASSWD" ];
          }
          {
            command = "/run/current-system/sw/bin/systemctl ${verb} llama-server";
            options = [ "NOPASSWD" ];
          }
        ]) [ "start" "stop" "restart" ];
      }
    ];

    environment.systemPackages = [ lcfg.package ];

    # ONE RULE PER SOURCE RANGE, and none when the server is loopback-only.
    networking.firewall.extraCommands = lib.mkIf (lcfg.host != "127.0.0.1") (
      lib.concatMapStrings (range: ''
        iptables -A nixos-fw -p tcp -s ${range} --dport ${toString backend.port} -j nixos-fw-accept
      '') cfg.openFirewallFor
    );

    assertions = [
      {
        assertion = backend.port != 11434 && backend.port != 8000;
        message = "the catalogue's llamacpp port collides with ollama (11434) or hailo-ollama (8000).";
      }
    ];
  };
}
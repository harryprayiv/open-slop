# open-slop-gateway: one authenticated, OpenAI-compatible endpoint in front
# of this row's inference servers.
#
# One of open-slop's NixOS modules.
#
# The gateway reads a catalogue whose endpoints are this row's own servers
# on loopback, built here from the backends this row enables, so a backend
# is behind the gateway exactly when it runs. Clients send the ids llmq
# shows (row/backend/name) and a bearer key.
#
# ============================================================================
# SECRETS ARRIVE AS SYSTEMD CREDENTIALS
# ============================================================================
#
# The keys file and the TLS private key are paths outside the store (a sops
# output, normally), readable by root. The unit runs as a DynamicUser and
# receives them through LoadCredential, so they are readable by this one
# process under $CREDENTIALS_DIRECTORY and by no user on the machine, and no
# file mode or owner has to be kept right by hand.
#
# ============================================================================
# NO TLS MEANS LOOPBACK, UNLESS SAID OTHERWISE BY NAME
# ============================================================================
#
# The binary refuses a non-loopback bind without TLS. The assertion below
# catches the same thing at evaluation, before a deploy.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.open-slop;
  gcfg = cfg.gateway;
  catalogue = lib.recursiveUpdate (import ../../catalogue) cfg.catalogue.extra;
  inherit (lib) types;

  enabledBackends =
    lib.optional cfg.server.enable "cpu"
    ++ lib.optional cfg.hailo.enable "hailo"
    ++ lib.optional cfg.llamaServer.enable "llamacpp";

  catalogueJson = pkgs.writeText "open-slop-gateway-catalogue.json" (
    builtins.toJSON {
      inherit (catalogue) backends models;
      endpoints = map (b: {
        row = config.networking.hostName;
        backend = b;
        url = "http://127.0.0.1:${toString catalogue.backends.${b}.port}";
      }) enabledBackends;
    }
  );

  loopback = lib.elem gcfg.host [
    "127.0.0.1"
    "::1"
    "localhost"
  ];
  tls = gcfg.tlsCertFile != null && gcfg.tlsKeyFile != null;
in
{
  options.services.open-slop.gateway = {
    enable = lib.mkEnableOption "the OpenAI-compatible gateway in front of this row's backends";

    package = lib.mkOption {
      type = types.package;
      default = pkgs.open-slop.llmq;
      defaultText = "pkgs.open-slop.llmq";
      description = "The package carrying bin/open-slop-gateway. Today that is the llmq package, which builds both executables.";
    };

    host = lib.mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Bind address. Anything but loopback needs TLS, or plaintextLan.";
    };

    port = lib.mkOption {
      type = types.port;
      default = 8443;
    };

    keysFile = lib.mkOption {
      type = types.str;
      example = "/run/secrets/open-slop-gateway-keys";
      description = ''
        One `name key` per line. A path outside the store, readable by root;
        the unit receives it as a credential. A key shorter than 24
        characters, a repeated name, or a file with no keys stops the
        gateway at start.
      '';
    };

    tlsCertFile = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Certificate chain, PEM. With tlsKeyFile, turns TLS on.";
    };

    tlsKeyFile = lib.mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Private key, PEM, outside the store; passed as a credential.";
    };

    plaintextLan = lib.mkOption {
      type = types.bool;
      default = false;
      description = ''
        Serve a non-loopback address without TLS. Bearer keys then cross the
        network in clear. For bring-up before the fleet CA exists, and named
        so it is not the default by accident.
      '';
    };
  };

  config = lib.mkIf gcfg.enable {
    systemd.services.open-slop-gateway = {
      description = "open-slop gateway on ${gcfg.host}:${toString gcfg.port}";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        ExecStart = lib.escapeShellArgs (
          [
            (lib.getExe' gcfg.package "open-slop-gateway")
            "--catalogue"
            "${catalogueJson}"
            "--keys"
            "%d/keys"
            "--host"
            gcfg.host
            "--port"
            (toString gcfg.port)
          ]
          ++ lib.optionals tls [
            "--tls-cert"
            "%d/tls-cert"
            "--tls-key"
            "%d/tls-key"
          ]
          ++ lib.optional gcfg.plaintextLan "--plaintext-lan"
        );

        LoadCredential =
          [ "keys:${gcfg.keysFile}" ]
          ++ lib.optionals tls [
            "tls-cert:${gcfg.tlsCertFile}"
            "tls-key:${gcfg.tlsKeyFile}"
          ];

        DynamicUser = true;
        Restart = "on-failure";
        RestartSec = 5;

        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        CapabilityBoundingSet = [ "" ];
        SystemCallFilter = [ "@system-service" ];
      };
    };

    networking.firewall.extraCommands = lib.mkIf (!loopback) (
      lib.concatMapStrings (range: ''
        iptables -A nixos-fw -p tcp -s ${range} --dport ${toString gcfg.port} -j nixos-fw-accept
      '') cfg.openFirewallFor
    );

    assertions = [
      {
        assertion = (gcfg.tlsCertFile == null) == (gcfg.tlsKeyFile == null);
        message = "services.open-slop.gateway: tlsCertFile and tlsKeyFile go together.";
      }
      {
        assertion = loopback || tls || gcfg.plaintextLan;
        message = ''
          services.open-slop.gateway binds ${gcfg.host} on ${config.networking.hostName}
          without TLS. Bearer keys would cross the network in clear. Set
          tlsCertFile and tlsKeyFile, or plaintextLan = true to accept that.
        '';
      }
      {
        assertion = enabledBackends != [ ];
        message = "services.open-slop.gateway is enabled on ${config.networking.hostName}, which runs no backend for it to front.";
      }
      {
        assertion = !(lib.elem gcfg.port (map (b: b.port) (lib.attrValues catalogue.backends)));
        message = "services.open-slop.gateway.port ${toString gcfg.port} is a backend's port in the catalogue.";
      }
    ];
  };
}

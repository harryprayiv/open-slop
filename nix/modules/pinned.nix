# GGUF models fetched into the store and registered with ollama by name.
#
# One of open-slop's NixOS modules.
#
# ============================================================================
# WHY THIS EXISTS ALONGSIDE services.open-slop.server.models
# ============================================================================
#
# services.ollama.loadModels runs `ollama pull <tag>`, which resolves the tag
# against a registry at activation time. No hash, no pin, and the bytes can
# change or vanish. The tensorblock abliterated repo lists eight quants on its
# model card and hosts two.
#
# Here the .gguf is a fixed-output derivation. Same bytes on every machine,
# buildable offline, unaffected by anything upstream doing.
#
# ============================================================================
# HOW REGISTRATION WORKS
# ============================================================================
#
# ollama will not read a model from an arbitrary path at inference time. It
# wants the weights in its own blob layout under OLLAMA_MODELS, referenced by
# a manifest. `ollama create` does that conversion, given a Modelfile whose
# FROM line points at the .gguf.
#
# So this copies the weights a second time, into /var/lib/ollama. A 4 GB model
# occupies 8 GB total. On a 118 GB card that is acceptable; on the 32 GB card
# the Pi shipped with it would not be.
#
# The guard is `ollama show`: registration is skipped if the name already
# resolves. Changing the URL or hash changes the store path, which changes
# this unit, which makes systemd restart it. The guard then finds the existing
# name and skips, so A BUMP NEEDS THE OLD NAME REMOVED BY HAND:
#
#   ollama rm <name>
#
# Left as manual because the alternative is a unit that deletes model weights
# on its own initiative.
#
# ============================================================================
# EVERYTHING ABOUT THE SERVER IS READ FROM services.ollama
# ============================================================================
#
# The port, the models directory, and the binary. This unit talks to the
# server llm.nix configured, so it asks that configuration rather than
# repeating 11434 or naming a package llm.nix might not have chosen. On
# aarch64 pkgs.ollama and pkgs.ollama-cpu are the same derivation today; on a
# row where they differ, the CLI still matches the server.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.open-slop;
  ollama = config.services.ollama;
  endpoint = "127.0.0.1:${toString ollama.port}";

  fetched = lib.mapAttrs (
    _name: m:
    pkgs.fetchurl {
      inherit (m) url hash;
    }
  ) cfg.server.pinnedModels;
in
{
  config = lib.mkIf (cfg.server.enable && cfg.server.pinnedModels != { }) {
    systemd.services.ollama-pinned-models = {
      description = "Register store-pinned GGUF models with ollama";
      wantedBy = [ "multi-user.target" ];
      after = [ "ollama.service" ];
      requires = [ "ollama.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "ollama";
        Group = "ollama";
        RuntimeDirectory = "ollama-pinned";
      };

      path = [
        ollama.package
        pkgs.curl
      ];

      environment = {
        OLLAMA_HOST = endpoint;
        # The CLI panics with "$HOME is not defined" without one of these.
        # It resolves its model directory from $HOME when OLLAMA_MODELS is
        # unset, and a systemd unit has no $HOME.
        #
        # OLLAMA_MODELS must match what services.ollama uses, or `ollama
        # create` writes the blob somewhere the server will not look and the
        # registration succeeds while the model stays invisible.
        OLLAMA_MODELS = ollama.modelsDir;
        HOME = "/var/lib/ollama";
      };

      script = ''
        # ollama answers a moment after the unit starts, and `after` orders
        # the start rather than readiness.
        for _ in $(seq 30); do
          curl -sf http://${endpoint}/api/tags > /dev/null && break
          sleep 2
        done

        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (name: drv: ''
            if ollama show ${lib.escapeShellArg name} > /dev/null 2>&1; then
              echo "${name} already registered"
            else
              echo "registering ${name} from ${drv}"
              printf 'FROM %s\n' ${drv} > "$RUNTIME_DIRECTORY/Modelfile"
              ollama create ${lib.escapeShellArg name} -f "$RUNTIME_DIRECTORY/Modelfile"
            fi
          '') fetched
        )}
      '';
    };
  };
}

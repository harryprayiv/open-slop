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
# THE CLI DOES NOT TOUCH THE MODELS DIRECTORY. `ollama create` reads the
# Modelfile, computes the GGUF's digest, uploads the bytes to the server
# through /api/blobs, and asks the server to create the model. The server
# writes the blob and the manifest, as whatever user it runs as. So this unit
# needs a route to the server and a readable store path, and nothing else:
# no OLLAMA_MODELS, no matching user, no write access to /var/lib.
#
# An earlier version ran as User = "ollama" with OLLAMA_MODELS set to match
# the server, on the belief that the CLI wrote blobs directly. That user
# exists only when services.ollama.user is set; the nixpkgs module runs
# ollama under DynamicUser by default, and the unit failed at start with
# "Failed to determine credentials for user 'ollama'" on 2026-09-20 after a
# nixpkgs bump. Running under its own DynamicUser removes the coupling.
#
# So this copies the weights a second time, into the server's blob store. A
# 4 GB model occupies 8 GB total. On a 118 GB card that is acceptable; on the
# 32 GB card the Pi shipped with it would not be.
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

        # Its own transient user. It talks to the server over loopback and
        # reads a world-readable store path; it owns nothing on disk beyond
        # the runtime directory below.
        DynamicUser = true;
        RuntimeDirectory = "ollama-pinned";
      };

      path = [
        ollama.package
        pkgs.curl
      ];

      environment = {
        OLLAMA_HOST = endpoint;
        # The CLI panics with "$HOME is not defined" without one. It keeps
        # its own config there and nothing else; the runtime directory is
        # writable by the dynamic user and gone after the unit stops.
        HOME = "/run/ollama-pinned";
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
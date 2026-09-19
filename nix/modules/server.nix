# ollama on the CPU, declared.
#
# One of open-slop's NixOS modules. Imported through the flake's nixosModules;
# reads services.open-slop.* from options.nix and nothing else about the row.
#
# ============================================================================
# WHAT THIS REPLACES
# ============================================================================
#
# The usual recipe is `curl -fsSL https://ollama.com/install.sh | sh`, which
# writes a systemd unit, a user, and a binary into /usr/local, none of which
# any config knows about. Then `ollama run phi3` once, by hand, on the machine,
# and the model set is whatever someone typed months ago.
#
# Here the service is a role, the models are a list, and the machine can be
# wiped and redeployed without anyone remembering what was on it.
#
# ============================================================================
# WHAT IS AND IS NOT REPRODUCIBLE
# ============================================================================
#
# The ollama binary and its unit: fully, like anything else in the store.
#
# The model weights: NOT. services.open-slop.server.models names tags, ollama resolves them
# against its registry at activation, and there is no hash. See the option's
# description for why that compromise is deliberate rather than an oversight.
# `ollama list` on the target is the only source of truth for what is actually
# loaded, the same way `transmission-remote -l` is for torrents.
#
# ============================================================================
# THE PORT COMES FROM THE CATALOGUE
# ============================================================================
#
# So does llmq's. Changing it there moves the server, its firewall hole and
# every client together. pinned.nix reads it back from services.ollama.port,
# which is what the server was actually given.
#
# ============================================================================
# THE CONTEXT LENGTH IS A SERVER DEFAULT TOO
# ============================================================================
#
# OLLAMA_CONTEXT_LENGTH is set from the catalogue's cpu ctx. ollama's own
# default for a machine without a large GPU is 4K, and a client on the
# OpenAI-compatible route (Grace, anything else that speaks that dialect) has
# no way to ask for more per request. With the default matching what llmq
# requests through num_ctx, no request causes a model reload for a changed
# window. OLLAMA_NUM_PARALLEL=1: a second slot would hold a second KV cache,
# 2 GiB for an 8B at 16K, and the CPU serves one request at a time anyway.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.open-slop;
  catalogue = lib.recursiveUpdate (import ../../catalogue) cfg.catalogue.extra;
  inherit (catalogue.backends.cpu) port ctx;
in
{
  config = lib.mkIf cfg.server.enable {

    services.ollama = {
      enable = true;
      host = cfg.server.host;
      inherit port;

      # Pulled at activation by the module's own oneshot unit. A fresh
      # machine arrives with its models rather than needing a human.
      loadModels = cfg.server.models;

      environmentVariables = {
        OLLAMA_CONTEXT_LENGTH = toString ctx;
        OLLAMA_NUM_PARALLEL = "1";
      };

      # CPU build, explicitly. `acceleration` used to be an option and is now
      # expressed as a package choice: pkgs.ollama-cuda, -rocm, -vulkan, -cpu.
      # There is nothing to accelerate with on a Pi, and the plain `ollama`
      # attribute may pull a GPU variant depending on what nixpkgs decides is
      # the default for the platform.
      package = pkgs.ollama-cpu;
    };

    # ONE RULE PER SOURCE RANGE, not `openFirewall = true`.
    #
    # ollama's API has no authentication. Anything that reaches this port can
    # load a model, run a prompt, and occupy the machine's CPU for as long as
    # it likes. On a LAN that is an acceptable trade; on anything wider it is
    # an open compute endpoint.
    networking.firewall.extraCommands = lib.concatMapStrings (range: ''
      iptables -A nixos-fw -p tcp -s ${range} --dport ${toString port} -j nixos-fw-accept
    '') cfg.openFirewallFor;

    # Model weights, and they are large. A consumer with impermanence maps
    # statePaths into its persistence; without this a wiped row re-downloads
    # every model on every boot.
    services.open-slop.statePaths = [
      {
        path = "/var/lib/private/ollama";
        reason = "Model weights. Gigabytes each, re-downloadable but slowly, and the machine is unusable while it happens.";
      }
    ];

    assertions = [
      {
        assertion = cfg.server.host == "127.0.0.1" -> cfg.openFirewallFor == [ ];
        message = ''
          services.open-slop on ${config.networking.hostName} opens the firewall to
          ${lib.concatStringsSep ", " cfg.openFirewallFor} but ollama is bound
          to 127.0.0.1, so nothing outside the machine can reach it regardless.

          Either set services.open-slop.server.host = "0.0.0.0" or drop openFirewallFor. A
          firewall hole in front of a loopback-bound service is a rule that
          looks like access and grants none, which is exactly the kind of
          thing this config exists to make loud.
        '';
      }
    ];
  };
}

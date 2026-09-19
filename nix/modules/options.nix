# The options a consumer sets. Every module in this directory reads from
# here and nothing else about the consumer's world.
#
# This is the contract between open-slop and the fleet that imports it. open-slop
# knows backends, models, engines, keys and jobs. The consumer knows machines:
# addresses, which backends a row runs, where secrets are, what to persist.
# Everything that crosses is an option below.
#
# ============================================================================
# statePaths IS AN OUTPUT
# ============================================================================
#
# open-slop's modules append to services.open-slop.statePaths the directories that
# hold model weights. open-slop has no opinion about impermanence; a consumer with
# it maps the list into its own persistence mechanism, for example
#
#   homelab.persist.system = config.services.open-slop.statePaths;
#
# and a consumer without it ignores the list.
{ lib, ... }:
let
  inherit (lib) types;
in
{
  options.services.open-slop = {
    openFirewallFor = lib.mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "192.168.8.0/24" ];
      description = ''
        Source ranges allowed to reach the inference ports. One iptables rule
        per range. Nothing here has authentication, so a range wider than the
        LAN is an open compute endpoint.
      '';
    };

    server = {
      enable = lib.mkEnableOption "ollama on the CPU";

      host = lib.mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Bind address for ollama. 0.0.0.0 with openFirewallFor to serve the LAN.";
      };

      models = lib.mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "qwen2.5-coder:7b" ];
        description = ''
          Tags pulled by ollama at activation. Resolved against the registry
          with no hash; see catalogue/default.nix for what each one costs.
        '';
      };

      pinnedModels = lib.mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              url = lib.mkOption { type = types.str; };
              hash = lib.mkOption { type = types.str; };
            };
          }
        );
        default = { };
        description = ''
          GGUF files fetched into the store by hash and registered with
          ollama under the attribute name. Same bytes on every deploy.
        '';
      };
    };

    hailo = {
      enable = lib.mkEnableOption "hailo-ollama on a Hailo-10H NPU";

      models = lib.mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "qwen2.5-instruct:1.5b" ];
        description = "Zoo names pulled through /api/pull once hailo-ollama answers.";
      };
    };

    statePaths = lib.mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            path = lib.mkOption { type = types.str; };
            reason = lib.mkOption { type = types.str; };
          };
        }
      );
      default = [ ];
      description = "Directories open-slop's services keep model weights in. Set by open-slop; read by the consumer's persistence.";
    };

    catalogue = {
      extra = lib.mkOption {
        type = types.attrs;
        default = { };
        description = ''
          Merged over catalogue/default.nix with lib.recursiveUpdate. For a
          model this fleet serves that the shipped catalogue does not describe.
        '';
      };
    };
  };
}

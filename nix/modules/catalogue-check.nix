# Keeps the catalogue honest against what a row declares.
#
# One of open-slop's NixOS modules. Declares nothing and configures nothing. It
# evaluates, on rows with any open-slop service enabled, the facts the catalogue
# claims and nothing else can check.
#
# ============================================================================
# WHY A MISSING CATALOGUE ENTRY IS A WARNING AND NOT AN ASSERTION
# ============================================================================
#
# The catalogue is what llmq shows a person choosing a model. A declared model
# with no entry still works everywhere: the server pulls it, llmq lists it as
# NO CATALOGUE ENTRY and gives it the backend's default budget. Refusing to
# deploy the inference box because a client-side description is missing would
# couple the server to its documentation. So it warns until the entry exists,
# which is a warning with one obvious fix: services.open-slop.catalogue.extra, or
# an entry in catalogue/default.nix.
#
# ============================================================================
# WHY THE HAILO PORT IS PINNED BY A LITERAL
# ============================================================================
#
# hailo-ollama 5.1.1 takes its listen address from the JSON it ships in
# etc/xdg/hailo-ollama/. Nothing here sets it, and reading that file at
# evaluation time is import-from-derivation. So the catalogue's value is a
# description, and the assertion below is the tripwire that stops someone
# editing the description and moving the firewall rule, the pull unit and
# llmq away from a server that did not move.
#
# The real check is a build-time one: a system.checks derivation that reads
# the port out of the shipped JSON and fails the build on a mismatch. That
# needs the JSON's shape, which has not been looked at yet:
#   ssh <user>@<row> \
#     'jq . /run/current-system/sw/etc/xdg/hailo-ollama/hailo-ollama.json'
# Once it is known, this literal should go.
{ config, lib, ... }:
let
  cfg = config.services.open-slop;
  catalogue = lib.recursiveUpdate (import ../../catalogue) cfg.catalogue.extra;
  host = config.networking.hostName;

  # pinnedModels are registered under their attribute name, so that is the
  # name the server reports and the name the catalogue is keyed by.
  declared = {
    cpu = lib.optionals cfg.server.enable (cfg.server.models ++ lib.attrNames cfg.server.pinnedModels);
    hailo = lib.optionals cfg.hailo.enable cfg.hailo.models;
    llamacpp = lib.optionals cfg.llamaServer.enable [ cfg.llamaServer.alias ];
  };

  uncatalogued =
    backend:
    lib.filter (m: !(lib.hasAttr m (catalogue.models.${backend} or { }))) (declared.${backend} or [ ]);

  enabledBackends =
    lib.optional cfg.server.enable "cpu"
    ++ lib.optional cfg.hailo.enable "hailo"
    ++ lib.optional cfg.llamaServer.enable "llamacpp";

  unknownBackends = lib.filter (b: !(lib.hasAttr b catalogue.backends)) enabledBackends;

  hailoPortAsShipped = 8000;
in
{
  config = lib.mkIf (enabledBackends != [ ]) {
    assertions = [
      {
        assertion = unknownBackends == [ ];
        message = ''
          ${host} enables ${lib.concatStringsSep ", " unknownBackends}, which
          the catalogue does not describe.

          The catalogue is where a backend's port lives, so a backend missing
          from it has no port for its own module or for llmq to use. Add an
          entry under `backends` with at least engine, port, streams,
          acceptsOptions, ctx, predict, promptOverhead, charsPerToken,
          temperature and blurb.
        '';
      }
      {
        # Guarded on the entry existing, so a missing hailo backend is
        # reported by the assertion above rather than by an attribute error
        # from this one.
        assertion =
          cfg.hailo.enable && catalogue.backends ? hailo
          -> catalogue.backends.hailo.port == hailoPortAsShipped;
        message = ''
          The catalogue gives the hailo backend port
          ${toString (catalogue.backends.hailo.port or null)}, but hailo-ollama 5.1.1 listens on
          ${toString hailoPortAsShipped}, the address in its own shipped JSON.

          The catalogue value does not move the server. It moves the firewall
          rule, the model-pull unit and llmq, all to a port nothing listens on.
          Put it back, or change what the server binds first and then both
          numbers here.
        '';
      }
    ];

    warnings = lib.concatMap (
      backend:
      let
        missing = uncatalogued backend;
      in
      lib.optional (lib.elem backend enabledBackends && missing != [ ]) ''
        ${host} declares ${backend} models with no entry in the catalogue:
        ${lib.concatStringsSep ", " missing}

        They are served as normal. llmq lists them as NO CATALOGUE ENTRY, with
        the ${backend} backend's default budget and no description of what
        they cost. Add an entry under models.${backend}, in
        catalogue/default.nix or services.open-slop.catalogue.extra.
      ''
    ) (lib.attrNames declared);
  };
}

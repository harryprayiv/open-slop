# The Hailo-10H NPU: driver, firmware, and the inference server on top.
#
# One of open-slop's NixOS modules. Gated on services.open-slop.hailo.enable,
# so a row without the NPU evaluates none of it.
#
# The port comes from the catalogue, which describes the port hailo-ollama
# binds rather than setting it. See the note on it there, and the assertion
# in catalogue-check.nix that pins it.
#
# The device tree overlay that enables the M.2 slot is NOT here: it is a
# property of the board, not of this service, and lives with the consumer's
# hardware configuration.
#
# ============================================================================
# THE STACK, BOTTOM UP
# ============================================================================
#
#   device tree overlay      the consumer's hardware config, enables the slot
#     -> hailo1x_pci.ko      ../packages/hailo/driver.nix
#     -> firmware blobs      ../packages/hailo/firmware.nix, 3 stages, ~2.1s
#     -> /dev/hailo0
#     -> libhailort          ../packages/hailo/runtime.nix
#     -> hailo-ollama :8000  ../packages/hailo/gen-ai-zoo.nix
#
# Every layer verified on real hardware 2026-09-12. `hailortcli fw-control
# identify` reports Device Architecture: HAILO10H, and the server answers
# /api/generate at roughly 6.5 tok/s on qwen2.5-instruct:1.5b.
#
# ============================================================================
# A FAILED FIRMWARE LOAD NEEDS A POWER CYCLE, NOT A REBOOT
# ============================================================================
#
# Learned the hard way. If stage 2 or 3 fails, the chip is left mid-boot with
# its SCU running and waiting. rmmod/insmod then times out at stage 1 with
# -110 (ETIMEDOUT) and boot_status ffffffff, which looks like a different and
# worse bug. It is not. The chip holds state across a warm reset. Pull power
# for ten seconds.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.open-slop;
  catalogue = lib.recursiveUpdate (import ../../catalogue) cfg.catalogue.extra;
  inherit (catalogue.backends.hailo) port;

  hailoFirmware = pkgs.callPackage ../packages/hailo/firmware.nix { };

  # Built against THIS row's kernel, so a kernel bump rebuilds it rather
  # than silently loading a module compiled for something else.
  hailoDriver = config.boot.kernelPackages.callPackage ../packages/hailo/driver.nix { };

  hailort = pkgs.callPackage ../packages/hailo/runtime.nix { };
  hailoZoo = pkgs.callPackage ../packages/hailo/gen-ai-zoo.nix { inherit hailort; };
in
{
  config = lib.mkIf cfg.hailo.enable {
    boot.extraModulePackages = [ hailoDriver ];
    boot.kernelModules = [ "hailo1x_pci" ];

    # Ships 51-hailo-udev.rules, which sets MODE="0666" on the hailo_chardev
    # subsystem. No group, no ownership change: the node is world read-write,
    # which is how any non-root caller reaches it, including the hailo-ollama
    # system user this service runs as.
    #
    # Worth being clear-eyed about: 0666 means any local user can open the
    # NPU and run inference on it. That is Hailo's choice, not one made here,
    # and on a single-user headless box it is not much of an exposure. On a
    # machine with untrusted local users it would be, and the fix would be a
    # replacement rule setting a group instead.
    services.udev.packages = [ hailoDriver ];

    hardware.firmware = [ hailoFirmware ];

    # hailortcli, for `fw-control identify` and for diagnosing by hand.
    environment.systemPackages = [
      hailort
      hailoZoo
    ];

    users.users.hailo-ollama = {
      isSystemUser = true;
      group = "hailo-ollama";
      description = "Hailo NPU inference endpoint";
    };
    users.groups.hailo-ollama = { };

    systemd.services.hailo-ollama = {
      # The chip runs its own pci_ep driver, loaded from the firmware blobs,
      # and it must match the host driver's version. When it does not, the
      # firmware loads fine, /dev/hailo0 appears, and every ioctl fails with
      # EINVAL: hailortcli reports "Failed soc_connect" and the API returns
      # 500 "LLM not loaded" for every generate. Nothing says "version
      # mismatch" except one dmesg line at boot.
      #
      # THIS IS THE CHECK THAT CATCHES A STALE HASH. The eval assertion
      # compares version strings; this compares what actually got loaded.
      preStart = ''
        if ${pkgs.util-linux}/bin/dmesg | grep -q "driver_compatible is false"; then
          echo "Hailo driver and on-chip pci_ep driver versions disagree." >&2
          echo "dmesg says:" >&2
          ${pkgs.util-linux}/bin/dmesg | grep -i "Mismatch Driver version" >&2
          echo "" >&2
          echo "The firmware derivation and the driver derivation are out of" >&2
          echo "step. Check that BOTH the version and the hash moved in" >&2
          echo "nix/packages/hailo/firmware.nix." >&2
          exit 1
        fi
      '';

      description = "Hailo NPU inference endpoint, ollama-compatible API";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      # The device must exist before this starts. The driver's probe takes
      # about two seconds to push firmware, so on a cold boot this unit can
      # otherwise lose the race and fail with "Failed to create VDevice",
      # which reads like a Hailo problem and is an ordering one.
      unitConfig.ConditionPathExists = "/dev/hailo0";

      serviceConfig = {
        ExecStart = lib.getExe hailoZoo;
        Restart = "on-failure";
        RestartSec = 5;

        WorkingDirectory = "/var/lib/hailo-ollama";
        # A FIXED USER, NOT DynamicUser.
        #
        # DynamicUser allocates a transient UID per start, and systemd maps
        # StateDirectory to it at runtime. That works for a service whose
        # state is opaque to everything else, and it does not work here:
        # hailo-ollama writes model weights into a directory that has to be
        # seeded by ExecStartPre first, and anything the seed chowns is owned
        # by the wrong UID by the time the service runs. The symptom was a
        # tree owned by nobody:nogroup that the service could not write into.
        User = "hailo-ollama";
        Group = "hailo-ollama";

        # The binary resolves its models directory relative to itself, in the
        # store, and writes pulled weights there. XDG_DATA_DIRS gets it the
        # config and not this. Bind the writable copy over the store path so
        # the compiled-in assumption lands somewhere it may write.
        #
        # Contained to this unit: ProtectSystem = "strict" already gives the
        # service a private mount namespace, so nothing else on the machine
        # sees a store path shadowed.
        # BindPaths = [
        #   "/var/lib/private/hailo-ollama/hailo-ollama:${hailoZoo}/share/hailo-ollama"
        # ];

        # Model weights, pulled through /api/pull from dev-public.hailo.ai.
        StateDirectory = "hailo-ollama";

        # From strace: the data search is $XDG_DATA_HOME used DIRECTLY,
        # then each $XDG_DATA_DIRS entry + "/share/hailo-ollama". So the
        # writable copy goes in XDG_DATA_HOME, which needs no /share level
        # and is checked first.
        #
        # XDG_CONFIG_DIRS is not set here: the wrapper's value already works,
        # and the strace shows it finding hailo-ollama.json through
        # /run/current-system/sw/etc/xdg because the package is in
        # environment.systemPackages.
        Environment = [
          "HOME=/var/lib/hailo-ollama"
          "XDG_CONFIG_HOME=/var/lib/hailo-ollama/.config"
          "XDG_DATA_DIRS=/var/lib/hailo-ollama"
        ];

        DeviceAllow = [ "/dev/hailo0 rw" ];
        PrivateDevices = false;
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
      };
    };

    systemd.services.hailo-ollama-seed = {
      description = "Seed hailo-ollama's writable model directory";
      wantedBy = [ "multi-user.target" ];
      before = [ "hailo-ollama.service" ];
      requiredBy = [ "hailo-ollama.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      # Runs as root with NO namespacing, which is the point: hailo-ollama's
      # own ProtectSystem = "strict" is set up before an ExecStartPre inside
      # that unit would run, so a pre-hook there is already inside the
      # namespace it is trying to prepare. This has to be a separate unit.
      #
      # ======================================================================
      # THE LAYOUT IS $XDG_DATA_DIRS/hailo-ollama, NOT .../share/hailo-ollama
      # ======================================================================
      #
      # strace shows the data search appending "/share/hailo-ollama" to each
      # XDG_DATA_DIRS entry, which is true for the STORE fallback and not for
      # the writable copy: the server reads $XDG_DATA_DIRS/hailo-ollama
      # directly. Seeding into share/hailo-ollama produced a server that
      # ignored the writable tree entirely, fell through to the store, and
      # aborted with "Read-only file system" on models/blob.
      #
      # ======================================================================
      # THE GUARD IS VERSION-AWARE, AND THAT IS NOT OPTIONAL
      # ======================================================================
      #
      # An earlier version guarded on "does the directory exist", so it seeded
      # once and never again. A zoo bump then left 5.1.1's manifests under a
      # 5.3.0 server: GET /hailo/v1/list advertised llama3.2:3b and
      # qwen2.5-instruct, which 5.3.0 does not have, while POST /api/pull
      # returned 404 for qwen3:1.7b, which it does. Every model present in
      # only one version failed and the one present in both worked, which
      # looked like an intermittent network problem for an hour.
      #
      # The zoo's VERSION is stamped into the directory, so a version change
      # re-seeds. That discards pulled weights too, which is correct: they are
      # compiled per-runtime and 5.1.1's blobs are not valid for 5.3.0.
      #
      # THE VERSION, NOT THE STORE PATH. The stamp used to be ${hailoZoo}, and
      # a nixpkgs bump on 2026-09-20 rebuilt the same 5.1.1 tarball into a
      # new path, mismatched the stamp, wiped 9 GB of blobs and re-pulled
      # them all. The path changes whenever stdenv does; the version changes
      # when Hailo ships something new, which is the only time a wipe is
      # wanted.
      #
      # ======================================================================
      # THE RECURSIVE chown IS INSIDE THE IF, DELIBERATELY
      # ======================================================================
      #
      # It used to run unconditionally over all of /var/lib/hailo-ollama,
      # which walks every pulled model blob. On an SD card with a few
      # gigabytes of weights that takes minutes and makes every activation
      # look like it has frozen. Inside the if it only ever touches the
      # manifest tree this unit just wrote, which is a few hundred bytes per
      # file. Blobs pulled later are created by the service as its own user
      # and never need chowning.
      script = ''
        stamp=/var/lib/hailo-ollama/.zoo-version

        # Migration from the store-path stamp. A stamp naming a zoo package of
        # THIS version is the same runtime, so it is rewritten rather than
        # treated as a change. Remove after every row has activated once.
        case "$(cat "$stamp" 2>/dev/null)" in
          /nix/store/*-hailo-gen-ai-model-zoo-${hailoZoo.version})
            echo "${hailoZoo.version}" > "$stamp"
            ;;
        esac

        if [ "$(cat "$stamp" 2>/dev/null)" != "${hailoZoo.version}" ]; then
          echo "zoo version changed to ${hailoZoo.version}; re-seeding and discarding pulled weights"
          # .local TOO. The server writes pulled weights to
          # $HOME/.local/share/hailo-ollama/models/blob, which this unit does
          # not otherwise manage. A version change left 5.3.0's weights there
          # after everything else had reverted, and the server failed on them
          # with the manifests looking correct. Wipe both or neither.
          rm -rf /var/lib/hailo-ollama/hailo-ollama /var/lib/hailo-ollama/.local
          mkdir -p /var/lib/hailo-ollama
          cp -r --no-preserve=mode,ownership \
            ${hailoZoo}/share/hailo-ollama \
            /var/lib/hailo-ollama/hailo-ollama
          chown -R hailo-ollama:hailo-ollama /var/lib/hailo-ollama/hailo-ollama
          chmod -R u+w /var/lib/hailo-ollama/hailo-ollama
          echo "${hailoZoo.version}" > "$stamp"
        fi

        mkdir -p /var/lib/hailo-ollama/.config
        chown hailo-ollama:hailo-ollama \
          /var/lib/hailo-ollama \
          /var/lib/hailo-ollama/.config
      '';
    };

    # Pull the row's declared models once hailo-ollama is answering.
    #
    # ========================================================================
    # THE WEIGHTS ARE NOT IN THE STORE, AND CANNOT BE
    # ========================================================================
    #
    # /api/pull fetches from dev-public.hailo.ai with no hash and no version
    # pin. Making these a fixed-output derivation would mean a multi-gigabyte
    # hash per model, regenerated every time Hailo republishes. So this unit
    # is convergence, not reproduction: the row declares what it should have
    # and this makes it so, the same compromise the CPU backend's
    # services.ollama.loadModels makes.
    #
    # `hailo-ollama list` on the target is the only source of truth for what
    # is actually resident.
    #
    # ========================================================================
    # IT RE-RUNS WHEN THE ZOO VERSION OR THE MODEL LIST CHANGES, AND PULLS
    # ONLY WHAT THE SERVER DOES NOT HAVE
    # ========================================================================
    #
    # The zoo's version is in the script, so a version bump changes the unit
    # and systemd restarts it on the next activation. That matters because
    # weights are compiled for a specific runtime: 5.1.1's blobs are not
    # necessarily valid for 5.3.0, and a stale cache produces a model that
    # pulls instantly and then fails at generate.
    #
    # The version, NOT the store path, for the same reason as the seed unit's
    # stamp: the path moves with every nixpkgs bump and the unit re-ran on
    # each one. And each run used to pull every declared model whether or
    # not the server had it, which the server answered by downloading it
    # again. GET /api/tags is what the server has; a model listed there is
    # skipped. The same guard as pinned.nix's `ollama show`.
    #
    # If a bump leaves models broken, wipe and let this re-pull:
    #   systemctl stop hailo-ollama
    #   rm -rf /var/lib/hailo-ollama/hailo-ollama/models/blob
    #   systemctl start hailo-ollama hailo-ollama-models
    systemd.services.hailo-ollama-models = lib.mkIf (cfg.hailo.models != [ ]) {
      description = "Pull the declared Hailo NPU models";
      wantedBy = [ "multi-user.target" ];
      after = [ "hailo-ollama.service" ];
      requires = [ "hailo-ollama.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };

      path = [
        pkgs.curl
        pkgs.jq
      ];

      script = ''
        # Built against zoo ${hailoZoo.version}, so this unit changes with it.

        # hailo-ollama binds and answers a moment after the unit starts, and
        # `after` only orders the start, not readiness. Poll rather than
        # sleep a fixed amount.
        for _ in $(seq 30); do
          curl -sf http://127.0.0.1:${toString port}/hailo/v1/list > /dev/null && break
          sleep 2
        done

        have=$(curl -sf http://127.0.0.1:${toString port}/api/tags | jq -r '.models[]?.name' || true)

        ${lib.concatMapStringsSep "\n" (m: ''
          if printf '%s\n' "$have" | grep -qx ${lib.escapeShellArg m}; then
            echo "${m} already present"
          else
            echo "pulling ${m}"
            curl -sf http://127.0.0.1:${toString port}/api/pull \
              -H 'Content-Type: application/json' \
              -d '{"model":"${m}","stream":false}' \
              || echo "FAILED to pull ${m}, continuing" >&2
          fi
        '') cfg.hailo.models}
      '';
    };

    # ONE RULE PER SOURCE RANGE. hailo-ollama has no authentication: anything
    # that reaches port 8000 can pull models and run prompts. On a LAN that is
    # an acceptable trade and on anything wider it is an open compute endpoint.
    networking.firewall.extraCommands = lib.concatMapStrings (range: ''
      iptables -A nixos-fw -p tcp -s ${range} --dport ${toString port} -j nixos-fw-accept
    '') cfg.openFirewallFor;

    # /var/lib/hailo-ollama, NOT /var/lib/private/hailo-ollama. The private
    # path is where StateDirectory lands under DynamicUser, which this unit
    # stopped using; with a fixed User it is /var/lib/<name>, which is where
    # the seed unit writes. The old entry named a directory nothing uses.
    # It has no effect until this row has impermanence. With impermanence,
    # the old entry would have discarded every pulled model on every boot.
    services.open-slop.statePaths = [
      {
        path = "/var/lib/hailo-ollama";
        reason = "int4 model weights compiled for the Hailo-10H. Re-downloadable, slowly, and the endpoint is dead while it happens.";
      }
    ];

    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.system == "aarch64-linux";
        message = ''
          services.open-slop.hailo is enabled on ${config.networking.hostName},
          but this row is ${pkgs.stdenv.hostPlatform.system}.

          Only the aarch64 h10-hailort package is packaged here, because the
          only board this has run on is a Raspberry Pi 5. An x86_64 host with
          a Hailo M.2 card is plausible and would need the amd64 deb, which
          is a different URL and a different hash.
        '';
      }
      {
        assertion =
          let
            v = hailoZoo.version;
          in
          hailoDriver.version == v && hailort.version == v && hailoFirmware.version == v;
        message = ''
          The Hailo components disagree on version:

            driver    ${hailoDriver.version}
            firmware  ${hailoFirmware.version}
            runtime   ${hailort.version}
            zoo       ${hailoZoo.version}

          All four are one matched set. The zoo is the constraint, because it
          is the only thing that provides hailo-ollama and it exists at
          exactly the versions Hailo publishes it at.

          THIS ASSERTION CANNOT CATCH A STALE HASH. A derivation whose
          version says 5.3.0 while its hash points at 5.1.1's tarball builds
          cleanly, installs, and loads, because a fixed-output derivation is
          keyed on the hash and Nix has no way to look inside it at eval. Both
          halves of every bump have to move together, and the only check is at
          runtime: see the mismatch note in ../packages/hailo/firmware.nix.
        '';
      }
    ];
  };
}
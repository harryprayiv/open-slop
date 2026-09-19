# The Hailo PCIe kernel driver, out of tree.
#
# ============================================================================
# VERSION LOCKED TO 5.1.1, AND 5.3.0 DOES NOT WORK ON THIS HARDWARE
# ============================================================================
#
# Hailo ships driver, runtime, model zoo and FIRMWARE as a matched set. All
# four must agree, and there is a fifth component that does not come from any
# of them: the pci_ep driver running ON THE CHIP.
#
# A full 5.3.0 upgrade was attempted 2026-09-13 and failed. Every host-side
# component was genuinely 5.3.0 (verified: driver's HAILO_DRV_VER_* constants
# read 5.3.0, the firmware tarball's image-fs and fitImage differ by sha256
# from 5.1.1's, all eighteen firmware files installed), the firmware loaded
# through all three stages, the device node appeared, and the chip answered a
# live QUERY_DRIVER_INFO with 5:1:1:
#
#   hailo1x: Mismatch Driver version pcie driver 5:3:0 pci_ep driver 5:1:1
#   hailo1x: driver_compatible is false
#
# Every ioctl then fails with EINVAL. hailortcli reports "Failed soc_connect",
# the API returns 500 "LLM not loaded", and even `hailortcli logs` cannot read
# the chip's own log because that path also goes through soc_connect.
#
# hailortcli on the H10 has no fw-update subcommand, so whatever updates the
# on-chip endpoint driver is not in any public Hailo package. The likely
# explanation is flash-resident firmware with a separate update mechanism,
# unconfirmed.
#
# DO NOT BUMP THIS WITHOUT RESOLVING THAT. The question to ask Hailo:
# "Pi 5 + AI HAT+ 2, driver 5.3.0, firmware 5.3.0, chip still reports
# pci_ep 5.1.1: how is the endpoint driver updated?"
#
# ============================================================================
# A STALE HASH GIVES YOU THE OLD SOURCE UNDER THE NEW NAME
# ============================================================================
#
# fetchFromGitHub is a fixed-output derivation, keyed on the HASH, not the
# URL or the rev. Bumping `version` and `rev` while leaving the old hash in
# place produces a derivation called hailo-pcie-driver-5.3.0 that contains
# 5.1.1's source, builds cleanly, installs, loads, and logs "driver version
# 5.1.1" at boot. Nothing errors anywhere.
#
# That cost an evening on top of the above. When bumping, re-prefetch:
#
#   nix-prefetch-url --unpack https://github.com/hailo-ai/hailort-drivers/archive/refs/tags/<TAG>.tar.gz
#   nix hash convert --hash-algo sha256 --to sri <result>
#
# The check that catches it is `dmesg | grep "Init module"` after a POWER
# CYCLE, which reports the version the running module actually is.
#
# ============================================================================
# WHAT THIS PRODUCES
# ============================================================================
#
# hailo1x_pci.ko, NOT hailo_pci.ko. boot.kernelModules in
# nix/modules/hailo.nix must match.
#
# Plus 51-hailo-udev.rules, shipped in the 5.1.1 source tree at
# linux/pcie/. It sets MODE="0666" on SUBSYSTEM=="hailo_chardev". Without it
# the node is root-only and hailo-ollama, which does not run as root, cannot
# open it.
#
# NOTE: 5.3.0 ships no rules file and renames the class to "hailo1x", so a
# future bump has to write the rule rather than install it.
#
# ============================================================================
# THE KERNEL IS A PARAMETER
# ============================================================================
#
# `kernel` comes from boot.kernelPackages, so this rebuilds on every kernel
# bump and cannot silently be built against the wrong tree. 5.1.1 compiles
# clean against 6.18.39 with no patches, despite its version guards topping
# out around 6.5.
#
# NOTE ON RELOADING: a `switch` cannot swap this module out from under a live
# PCIe device, and `modprobe` after a switch loads from the BOOTED
# generation's depmod index, not the current one. Deploying a new driver
# means a power cycle. Not a reboot: the chip holds firmware state across a
# warm reset.
{
  stdenv,
  lib,
  fetchFromGitHub,
  kernel,
}:
stdenv.mkDerivation rec {
  pname = "hailo-pcie-driver";
  version = "5.1.1";

  src = fetchFromGitHub {
    owner = "hailo-ai";
    repo = "hailort-drivers";
    rev = "v${version}";
    hash = "sha256-fPLyDTuOxFDOj6Sj1jVAQ+GpQyXSmMma05Rw1PwzmIc=";
  };

  nativeBuildInputs = kernel.moduleBuildDependencies;

  # NO sourceRoot = "linux/pcie". The Makefile there reaches up into
  # ../../common, ../vdma and ../utils for most of its sources, and with the
  # build directory set to the pcie subdirectory those paths land outside it
  # and the compiler cannot write its dependency files.
  #
  # Build from the tree root, cd in for the make. Note KERNEL_DIR with the
  # underscore: KERNELDIR is ignored silently and the build then fails on
  # /lib/modules/$(uname -r)/build, which reads like a missing kernel rather
  # than a wrong variable name.
  buildPhase = ''
    runHook preBuild
    make -C linux/pcie all \
      KERNEL_DIR=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -D -m444 linux/pcie/hailo1x_pci.ko \
      $out/lib/modules/${kernel.modDirVersion}/extra/hailo1x_pci.ko

    # services.udev.packages looks in lib/udev/rules.d.
    install -D -m444 linux/pcie/51-hailo-udev.rules \
      $out/lib/udev/rules.d/51-hailo-udev.rules

    runHook postInstall
  '';

  meta = {
    description = "PCIe driver for Hailo AI accelerators";
    homepage = "https://github.com/hailo-ai/hailort-drivers";
    license = lib.licenses.gpl2Only;
    platforms = [
      "aarch64-linux"
      "x86_64-linux"
    ];
  };
}


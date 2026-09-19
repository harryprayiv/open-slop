# Hailo-10H firmware blobs.
#
# The PCIe driver pushes these onto the chip at probe, in three stages, and
# without them the probe fails with -2 (ENOENT) and no device node appears.
#
# ============================================================================
# PINNED TO 5.1.1 WITH THE REST OF THE STACK. SEE driver.nix.
# ============================================================================
#
# The chip runs its own pci_ep driver and it must match the host driver's
# version. A 5.3.0 attempt on 2026-09-13 loaded 5.3.0's firmware successfully
# and the chip still reported pci_ep 5:1:1, after which every ioctl failed
# with EINVAL. driver.nix's header has the full account.
#
# ============================================================================
# WHAT THE DRIVER ASKS FOR, AND IN WHAT ORDER
# ============================================================================
#
# Observed on the real board:
#
#   stage 1   customer_certificate.bin
#             scu_fw.bin              -> chip boots its SCU, logs over PCIe
#   stage 2   u-boot-<SKU>.dtb.signed -> SKU read FROM THE CHIP at probe
#   stage 3   u-boot-spl.bin, u-boot-tfa.itb, fitImage, image-fs
#             batch-programmed over vDMA, then "triggering boot"
#
# THE SKU IS NOT KNOWN AHEAD OF TIME. The driver reads it from the board
# ("Board SKU-ID is: 6" on this one) and then asks for the matching DTB.
#
# u-boot-tfa.itb is READ BY THE DRIVER but is not a separate file in the
# tarball. It is presumably inside fitImage; the load succeeds either way.
#
# ============================================================================
# INSTALL EVERYTHING. DO NOT LIST FILES BY NAME.
# ============================================================================
#
# An earlier version hardcoded 5.1.1's file set, which meant a version bump
# silently installed a subset: 5.3.0's tarball ships eighteen files, adding
# u-boot-{9,10,11,12,13,14} and u-boot-default.dtb.signed, and the hardcoded
# list dropped them while still building cleanly because every name it did
# list still existed.
#
# A board whose SKU is one of the dropped numbers would then fail at stage 2
# with ENOENT on a DTB that shipped in the tarball and never reached the
# store. Glob the lot: the tarball is the source of truth.
#
# ============================================================================
# BOTH THE VERSION AND THE HASH MOVE TOGETHER
# ============================================================================
#
# A fixed-output derivation is keyed on the hash, so a new version string
# with an old hash builds cleanly and serves the old content under the new
# name. Same trap as driver.nix.
#
#   nix-prefetch-url https://hailo-hailort.s3.eu-west-2.amazonaws.com/Hailo10H/<V>/FW/hailo10h_fw.tar.gz
#   nix hash convert --hash-algo sha256 --to sri <result>
#
# The check is `dmesg | grep Mismatch` after a POWER CYCLE. Not a reboot: the
# chip holds firmware state across a warm reset.
{
  stdenvNoCC,
  fetchurl,
}:
stdenvNoCC.mkDerivation rec {
  pname = "hailo10h-firmware";
  version = "5.1.1";

  # The same URL linux/pcie/download_firmware_hailo10h.sh fetches, pinned.
  # Public: no Developer Zone login, unlike most of Hailo's downloads.
  src = fetchurl {
    url = "https://hailo-hailort.s3.eu-west-2.amazonaws.com/Hailo10H/${version}/FW/hailo10h_fw.tar.gz";
    hash = "sha256-S+rbzR9coXt/RgFojkLH/5MKwXcEDNaHuDpFZ7W+Ufw=";
  };

  sourceRoot = ".";

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/firmware/hailo/hailo10h
    install -m444 -t $out/lib/firmware/hailo/hailo10h *
    runHook postInstall
  '';

  meta = {
    description = "Firmware for the Hailo-10H AI accelerator";
    homepage = "https://hailo.ai";
    # Vendor blobs. No source, redistribution terms unstated.
    license = { free = false; };
    platforms = [ "aarch64-linux" ];
  };
}


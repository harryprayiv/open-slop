# HailoRT: the userspace runtime that talks to the device node.
#
# ============================================================================
# PINNED TO 5.1.1 WITH THE REST OF THE STACK. SEE driver.nix.
# ============================================================================
#
# ============================================================================
# THE DEB, NOT THE SOURCE
# ============================================================================
#
# hailo-ai/hailort tags v5.1.1 on GitHub, so building from source is possible
# and would avoid every autoPatchelf concern below. It is not done here for
# one reason: the GenAI model zoo ships hailo-ollama as a PREBUILT BINARY
# linked against this runtime's ABI. A source build that differed in compiler
# or flags would be a second, subtly different libhailort for that binary to
# find, and the failure mode is a runtime symbol error rather than a build
# error.
#
# ============================================================================
# WHERE IT COMES FROM, AND WHY THE PACKAGE NAME HAS A PREFIX
# ============================================================================
#
# archive.raspberrypi.com, not Hailo's own S3: Hailo's bucket returns 403 for
# the runtime at this version, while Raspberry Pi mirror it in their apt repo.
# Public, versioned, hashable.
#
# h10-hailort is the HAILO-10H package at 5.1.1. Plain `hailort` in that same
# repo is 4.23.0 and is for the Hailo-8, a different chip with a different
# driver; the two metapackages explicitly cannot coexist.
#
# NOTE FOR A FUTURE BUMP: at 5.x Hailo merged the two product lines, so 5.3.0
# is published as plain `hailort` on dev-public.hailo.ai and the Raspberry Pi
# archive still carries only the old split naming at 5.1.1. The URL shape
# changes with the version.
{
  stdenv,
  lib,
  fetchurl,
  dpkg,
  autoPatchelfHook,
  openssl,
}:
stdenv.mkDerivation rec {
  pname = "hailort";
  version = "5.1.1";

  src = fetchurl {
    url = "https://archive.raspberrypi.com/debian/pool/main/h/h10-hailort/h10-hailort_${version}_arm64.deb";
    hash = "sha256-bRnKJHAw1KsvDt4/6ffElZ8SwJJNPX0dc2jOzaRQsr8=";
  };

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
  ];

  # Determined by running the patched binary and reading each failure in turn,
  # on the real board. 5.3.0 additionally needs libusb1; 5.1.1 does not.
  buildInputs = [
    stdenv.cc.cc.lib # libstdc++.so.6
    openssl # libssl.so.3
  ];

  unpackPhase = ''
    runHook preUnpack
    dpkg -x $src .
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -r usr/bin $out/bin
    cp -r usr/lib $out/lib

    # DROP THE GSTREAMER PLUGIN. libgsthailo.so is a video-pipeline element
    # for vision inference, wanting the whole GStreamer and GLib stack. This
    # row runs an LLM: nothing loads it, nothing needs it, and carrying it
    # means carrying gstreamer, gst-plugins-base and glib on a Pi for a file
    # that is never opened.
    #
    # If this config ever grows vision work on a Hailo, add those to
    # buildInputs and delete this line rather than working around its absence.
    rm -rf $out/lib/aarch64-linux-gnu

    runHook postInstall
  '';

  meta = {
    description = "Hailo runtime library and CLI for the Hailo-10H";
    homepage = "https://github.com/hailo-ai/hailort";
    license = lib.licenses.mit;
    platforms = [ "aarch64-linux" ];
    mainProgram = "hailortcli";
  };
}


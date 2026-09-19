# The Hailo GenAI model zoo, which is where hailo-ollama actually lives.
#
# ============================================================================
# PINNED TO 5.1.1 WITH THE REST OF THE STACK. SEE driver.nix.
# ============================================================================
#
# A 5.3.0 upgrade was attempted 2026-09-13 and failed on the chip's own
# pci_ep driver, not on anything here. The 5.3.0 zoo is fetchable, works, and
# offers qwen3:1.7b which 5.1.1 does not; it is unreachable until the
# endpoint-driver question is answered. driver.nix has the account.
#
# ============================================================================
# THIS IS THE ONLY THING THAT PROVIDES hailo-ollama
# ============================================================================
#
# Not the runtime, not the driver. hailo-ollama is a binary inside this deb,
# and it is what serves the ollama-compatible API on port 8000. Everything
# else in this directory is version-pinned BY this file.
#
# THE DATE SEGMENT IN THE URL IS NOT DERIVABLE FROM THE VERSION. Hailo files
# each release under a release-month directory, discovered by probing:
#
#   5.1.1 -> 2025_12
#   5.2.0 -> 2026_01
#   5.3.0 -> 2026_04
#
# So a version bump is not a matter of changing ${version}. Probe first:
#
#   for d in 2026_05 2026_06 2026_07; for v in 5.4.0 5.5.0
#     echo -n "$d/$v: "
#     curl -sI "https://dev-public.hailo.ai/$d/Hailo10/hailo_gen_ai_model_zoo_$v"_arm64.deb | head -1
#   end; end
#
# ============================================================================
# IT FINDS ITS CONFIG THROUGH XDG
# ============================================================================
#
# 5.1.1 ships etc/xdg/hailo-ollama/hailo-ollama.json and aborts with
# `hailo-ollama directory not found` if it cannot locate it, so
# XDG_CONFIG_DIRS is load-bearing. The shipped JSON binds 0.0.0.0:8000 and
# points the model library at dev-public.hailo.ai:443, which is where
# /api/pull fetches weights from.
#
# NOTE FOR A FUTURE BUMP: 5.3.0 ships no config at all and reads OLLAMA_HOST
# instead, defaulting to the same 0.0.0.0:8000. The etc/xdg copy below is
# conditional so this file survives that either way.
#
# ============================================================================
# XDG_DATA_DIRS IS LOAD-BEARING TOO, AND --set-default IS NOT OPTIONAL
# ============================================================================
#
# The model manifests live in share/hailo-ollama/models. The service module
# overrides XDG_DATA_DIRS to point at a WRITABLE copy, because hailo-ollama
# writes pulled model weights into that directory and the store is read-only.
#
# A plain --set here wins over the unit's Environment= and the service then
# fails with "Read-only file system" on a path inside the store. That cost an
# evening. --set-default lets the unit win.
{
  stdenv,
  lib,
  fetchurl,
  dpkg,
  autoPatchelfHook,
  makeWrapper,
  openssl,
  hailort,
}:
stdenv.mkDerivation rec {
  pname = "hailo-gen-ai-model-zoo";
  version = "5.1.1";

  # Public, no Developer Zone login, unlike most of Hailo's downloads.
  src = fetchurl {
    url = "https://dev-public.hailo.ai/2025_12/Hailo10/hailo_gen_ai_model_zoo_${version}_arm64.deb";
    hash = "sha256-F9W0djILcuwZkDLnp7h7pyy1ExHVap8GBCE7epBW3rk=";
  };

  nativeBuildInputs = [
    dpkg
    autoPatchelfHook
    makeWrapper
  ];

  buildInputs = [
    stdenv.cc.cc.lib # libstdc++.so.6
    openssl # libssl.so.3
    hailort # libhailort.so.5.1.1
  ];

  unpackPhase = ''
    runHook preUnpack
    dpkg -x $src .
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/share
    cp -r usr/share/* $out/share/

    # Conditional: 5.1.1 has this, 5.3.0 does not. See the header.
    if [ -d etc/xdg ]; then
      mkdir -p $out/etc/xdg
      cp -r etc/xdg/* $out/etc/xdg/
    fi

    install -m755 usr/bin/hailo-ollama $out/bin/.hailo-ollama-unwrapped

    makeWrapper $out/bin/.hailo-ollama-unwrapped $out/bin/hailo-ollama \
      --set-default XDG_CONFIG_DIRS $out/etc/xdg \
      --set-default XDG_DATA_DIRS $out/share

    runHook postInstall
  '';

  meta = {
    description = "Hailo GenAI model zoo, providing the hailo-ollama server";
    homepage = "https://hailo.ai";
    license = { free = false; };
    platforms = [ "aarch64-linux" ];
    mainProgram = "hailo-ollama";
  };
}


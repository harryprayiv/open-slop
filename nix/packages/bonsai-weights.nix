# Bonsai GGUF weights as fixed-output derivations.
#
# Same bytes on every machine, buildable offline once cached, and a version
# bump is a URL and a hash moving together. This is the pinnedModels
# discipline applied to the models the fork serves.
#
# A lib.fakeHash entry fails its first build with the real hash in the
# error; paste it in and rebuild. Build through the aarch64 builder
# (--option extra-platforms "") so the download lands on oracle's card.
#
# ============================================================================
# WHICH PACK
# ============================================================================
#
# PQ2_0 for every model. The fork at f0a2b5d and later reads "Q2_0" as the
# official group-64 format and refuses the first-generation files that used
# that name for Prism's group-128 layout (2026-09-20: "this file matches the
# legacy Prism Q2_0 layout ... use the PQ2_0 version"). The PQ2_0 file of
# each model is the same weights in the layout the fork has an ARM NEON
# kernel for. File names verified against the Hugging Face repos on
# 2026-09-20.
{ lib, fetchurl }:
let
  hf = repo: file: "https://huggingface.co/prism-ml/${repo}/resolve/main/${file}";

  weight =
    {
      name,
      repo,
      file,
      hash,
      bytes,
      pack,
    }:
    fetchurl {
      inherit name hash;
      url = hf repo file;
      passthru = {
        inherit pack bytes;
        modelCard = "https://huggingface.co/prism-ml/${repo}";
      };
      meta = {
        description = "${repo} (${pack})";
        license = lib.licenses.asl20;
      };
    };
in
{
  # Bonsai 2, Qwen3.5-based hybrid attention. Measured on oracle 2026-09-20:
  # prefill 0.98 tok/s, decode 0.66 tok/s. Kept for the record; not a
  # working model on a Pi 5.
  "2-27b-pq2_0" = weight {
    name = "Ternary-Bonsai-2-27B-PQ2_0.gguf";
    repo = "Ternary-Bonsai-2-27B-gguf";
    file = "Ternary-Bonsai-2-27B-PQ2_0.gguf";
    hash = "sha256-OQfcFljbH3ipgmv41by43GXbDUZjiJN69X8ilPrmLsE=";
    bytes = 7206168928;
    pack = "PQ2_0";
  };

  # Dense trits, 1.2 GB smaller, generic CPU kernel on ARM as of f0a2b5d.
  "2-27b-ptq1_0" = weight {
    name = "Ternary-Bonsai-2-27B-PTQ1_0.gguf";
    repo = "Ternary-Bonsai-2-27B-gguf";
    file = "Ternary-Bonsai-2-27B-PTQ1_0.gguf";
    hash = "sha256-PI1wRwpdl+WiuUEN3Ymct0ARZZFGJibGDLL+rWRI9gs=";
    bytes = 5946648928;
    pack = "PTQ1_0";
  };

  # First-generation Bonsai 8B, Qwen3-8B dense, in the PQ2_0 pack. The
  # legacy "Ternary-Bonsai-8B-Q2_0.gguf" in the same repo does not load in
  # the current fork.
  "8b-pq2_0" = weight {
    name = "Ternary-Bonsai-8B-PQ2_0.gguf";
    repo = "Ternary-Bonsai-8B-gguf";
    file = "Ternary-Bonsai-8B-PQ2_0.gguf";
    hash = "sha256-E3b5QqqQ5g97VwwdgbORb+oTFf+FqhxNGQBq9o+0uSI=";
    bytes = 2180000000;
    pack = "PQ2_0";
  };
}
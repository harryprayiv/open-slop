# Bonsai GGUF weights as fixed-output derivations.
#
# Same bytes on every machine, buildable offline once cached, and a version
# bump is a URL and a hash moving together. This is the pinnedModels
# discipline applied to the models the fork serves.
#
# The hashes below are lib.fakeHash until the first build. Nix prints the real
# one in the mismatch error; paste it in and rebuild. Do that on the machine
# with the fastest link, since each is several gigabytes.
#
# File names are taken from the Hugging Face model cards on 2026-09-18. The 8B
# entry's file name is a best reading of the Bonsai 8B card and is marked
# unverified; the first fetch confirms or corrects it.
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
  # The one to measure first on a Pi 5: the fork has an ARM NEON kernel for
  # this pack.
  "2-27b-pq2_0" = weight {
    name = "Ternary-Bonsai-2-27B-PQ2_0.gguf";
    repo = "Ternary-Bonsai-2-27B-gguf";
    file = "Ternary-Bonsai-2-27B-PQ2_0.gguf";
    hash = "sha256-OQfcFljbH3ipgmv41by43GXbDUZjiJN69X8ilPrmLsE=";
    bytes = 7210000000;
    pack = "PQ2_0";
  };

  # Dense trits, 1.2 GB smaller, generic CPU kernel on ARM as of f0a2b5d.
  "2-27b-ptq1_0" = weight {
    name = "Ternary-Bonsai-2-27B-PTQ1_0.gguf";
    repo = "Ternary-Bonsai-2-27B-gguf";
    file = "Ternary-Bonsai-2-27B-PTQ1_0.gguf";
    hash = lib.fakeHash;
    bytes = 5950000000;
    pack = "PTQ1_0";
  };

  # First-generation Bonsai 8B. [?] file name unverified.
  "8b-q2_0" = weight {
    name = "Ternary-Bonsai-8B-Q2_0.gguf";
    repo = "Ternary-Bonsai-8B-gguf";
    file = "Ternary-Bonsai-8B-Q2_0.gguf";
    hash = "sha256-PI1wRwpdl+WiuUEN3Ymct0ARZZFGJibGDLL+rWRI9gs=";
    bytes = 2200000000;
    pack = "Q2_0";
  };
}

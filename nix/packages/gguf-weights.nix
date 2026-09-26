# Plain GGUF weights fetched by hash, for llama-server to serve.
#
# Separate from bonsai-weights.nix because those are one research fork's
# ternary packs with their own naming. These are ordinary community quants
# of ordinary open-weight models.
#
# WHY THESE EXIST AT ALL. ollama keeps its own blobs under /var/lib/ollama,
# owned by root and named by digest, with no declared provenance. Nothing
# else on the machine can read them (measured 2026-09-26: permission denied
# for a user process), and nothing in the configuration says which bytes
# they are. A model llama-server serves is pinned here instead, so the
# fleet's copy is the same bytes on every row and a change shows up in a
# diff.
#
# NO DOTS IN THE KEYS. A flake attribute path splits on dots, so a package
# named gguf-qwen2.5-coder-7b is looked up as gguf-qwen2 then 5-coder-7b and
# fails with a confusing message. The version goes in the name without its
# separator.
#
# FILLING A HASH. Set it to lib.fakeHash, build, and copy the hash Nix
# prints. A 404 shows up the same way, as a hash mismatch on an HTML error
# page, so check the size in the build log before trusting a hash.
{
  lib,
  fetchurl,
}:
{
  qwen25-coder-7b = fetchurl {
    name = "Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf";
    url = "https://huggingface.co/bartowski/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/Qwen2.5-Coder-7B-Instruct-Q4_K_M.gguf";
    hash = "sha256-FmT8yrc0Z0pQdjSQqMaTG3Dj8vjsEAMbVIBtMOX5VrY=";
    meta = {
      description = "Qwen2.5-Coder 7B Instruct, Q4_K_M, about 4.7 GB";
      license = lib.licenses.asl20;
    };
  };

  # The draft model from the speculative-decoding experiment of 2026-09-26.
  # Kept because the experiment is worth repeating against upstream
  # llama.cpp: the PrismML fork loads a draft model and then reports no
  # draft statistics and no speedup, with or without a grammar.
  qwen25-coder-1_5b = fetchurl {
    name = "Qwen2.5-Coder-1.5B-Instruct-Q4_K_M.gguf";
    url = "https://huggingface.co/bartowski/Qwen2.5-Coder-1.5B-Instruct-GGUF/resolve/main/Qwen2.5-Coder-1.5B-Instruct-Q4_K_M.gguf";
    hash = "sha256-9TBwXUR2YKQzbDKZga8WS0cbYLl0sdgI1X6Oyf4jsjk=";
    meta = {
      description = "Qwen2.5-Coder 1.5B Instruct, Q4_K_M, about 1.0 GB";
      license = lib.licenses.asl20;
    };
  };
}
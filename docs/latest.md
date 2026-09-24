# Where the project actually stands

Updated 2026-09-24. The previous version of this file (2026-09-20) said the
client had never done its real job. It has since done it many times, and
three more layers exist. HANDOFF.md is the detailed version; this is the
one-screen answer.

| Planned | State |
|---|---|
| llmq: menu, catalogue, chunking, jobs, resume, lock, warnings | Exists, deployed, and has run real documentation jobs on oracle. One file per part by default, after an A/B that the prompt could not fix. |
| Prompts shipped, selected by name | Exists, used on real jobs. |
| Three server backends declared and deployed | All three deployed on oracle: cpu, hailo, llamacpp (llama-server on demand, Bonsai 8B). |
| Native aarch64 builds | Working. oracle is the fleet's builder. |
| Bonsai 27B/8B | Measured, and the answer is no for the 27B (0.98/0.66 tok/s). The 8B is the fastest short-prompt model here and slower than the 7B at documentation length. Two of three weight hashes filled. |
| Gateway, API keys, TLS | **Written, tested, not deployed.** The binary and its NixOS module exist and are verified against mocks and a real local model. Nothing in neoblade-config enables it: it needs a sops entry for the keys file, and there is no fleet CA. Both servers on oracle are still open to the LAN. |
| Grace | **Forked and working.** One-function change (OPENAI_BASE_URL) so `prompt` reaches the gateway. All three prompt paths verified against a local model. |
| Typed stages | **Exists as llmq-grace.** Stage type-checked against a Haskell record at load, schema constrained by the server, typed value out, coverage checked by field comparison. Verified end to end on a 1,350-byte part. Never run on oracle. |
| A queue / runner / cancel from a phone | **Does not exist.** A job is a `systemd-run --user` unit on winsmuth. |
| Golden set, verification, per-file cache | **Nothing**, and the golden set is now the gate on every prompt change. Deterministic sampling landed for it. |

## The one thing to do next

Run llmq-grace against qwen2.5-coder:7b on oracle, one module directory,
one file per part. Everything above it is verified on a 0.5B on a laptop,
which proves the machinery and nothing about the work. That run answers the
only open question that matters for the design: how many output tokens a
documentation-sized typed value actually needs, against the 2048 the
catalogue reserves.

## What exists versus what was planned

| Planned | State |
|---|---|
| llmq: menu, catalogue, chunking, jobs, resume, lock, warnings | Exists. Tested against mocks. **Never run a real documentation job on oracle.** |
| Prompts shipped, selected by name | Exists. Never used on a real job. |
| Three server backends declared and deployed | cpu and hailo deployed and answering. llamacpp written, never built, never activated. |
| Native aarch64 builds | Working as of this morning. |
| A queue / runner / cancel from a phone | **Does not exist.** A job is a foreground process, or a `systemd-run --user` unit on winsmuth. There is no spool, no runner on oracle, no `llmq cancel`. |
| Gateway, API keys, TLS | **Does not exist.** Both servers are open to the LAN. |
| Bonsai 27B/8B | Fork packaged, never built. Weights have placeholder hashes. **Nothing measured.** |
| Grace | Pinned as an input, still points at OpenAI. Not used for anything. |
| Golden set, verification, per-file cache | Nothing. |

So: a client and two servers exist; the unattended and the quality layers do not. The client has never done its actual job. That is the test to run first.

# Files, variables and exit codes

## Environment variables

| Variable | Read by | Meaning |
|---|---|---|
| `OPEN_SLOP_CATALOGUE` | llmq, llmq-models, llmq-bench, llmq-index | The catalogue JSON. Set by the client wrapper. |
| `OPEN_SLOP_MEASURED` | llmq, llmq-models, llmq-bench | The measurements file. Default `$XDG_CACHE_HOME/open-slop/measured.json`. |
| `OPEN_SLOP_PROMPTS` | llmq | The shipped prompts directory. Set by the wrapper. |
| `LLMQ_STATE` | llmq, llmq-grace | Job root. Default `$XDG_STATE_HOME/llmq`. |
| `LLMQ_KEY_FILE` | llmq, llmq-grace | Bearer key for the gateway. |
| `LLMQ_BENCH_SSH_KEY` | llmq-bench | Use only this ssh key for `--control`. |
| `OPENAI_BASE_URL` | llmq-grace (through Grace) | The gateway URL. Set by `--gateway`. |
| `OPEN_SLOP_RAG_DB` | llmq-index | libpq connection string. |
| `OPEN_SLOP_RAG_EMBED_AT`, `OPEN_SLOP_RAG_EMBED_MODEL` | llmq-index | Embedding server and model. |
| `OPEN_SLOP_RAG_CHAT_AT`, `OPEN_SLOP_RAG_CHAT_MODEL` | llmq-index | Chat server and model for `ask`. |
| `OPEN_SLOP_PANDOC`, `OPEN_SLOP_PDFTOTEXT` | llmq-index | Converters. Set by the wrapper; PATH otherwise. |
| `DISPLAY` | llmq | Needed for `-i clip`. |
| `XDG_CACHE_HOME`, `XDG_STATE_HOME`, `HOME`, `TMPDIR` | several | Standard locations. |

## Files

| Path | Written by | Contents |
|---|---|---|
| `~/.cache/open-slop/measured.json` | llmq-bench | Measurements, kept until you delete them. |
| `~/.local/state/llmq/<id>/` | llmq, llmq-grace | Jobs. See [llmq](03-llmq.md). |
| `~/.local/state/open-slop/chats/*.md` | llmq-models | Chat transcripts. |
| `claims-out/` | llmq-claims | Claims per file and `claims.md`. |
| Postgres `llmq_rag` | llmq-index | Tables `rag_documents`, `rag_chunks`, `rag_embeddings`, `rag_sessions`, `rag_turns`. |
| `/var/lib/private/ollama` | ollama | Weights. |
| `/var/lib/hailo-ollama` | hailo-ollama | Zoo data and weights. |

## Ports

| Port | Service |
|---|---|
| 11434 | ollama (cpu) |
| 8000 | hailo-ollama |
| 8081 | llama-server |
| 8443 | open-slop-gateway |
| 9100 | node exporter, read by llmq-models and llmq-bench |

## Units

| Unit | Module |
|---|---|
| `ollama.service` | server |
| `ollama-pinned-models.service` | pinned |
| `llama-server.service` | llama-server |
| `hailo-ollama.service`, `hailo-ollama-seed.service`, `hailo-ollama-models.service` | hailo |
| `open-slop-gateway.service` | gateway |
| `open-slop-rag-db.service` | rag |

## Exit codes

| Program | 0 | 1 | 2 | 130 |
|---|---|---|---|---|
| llmq | done | failed | done with warnings | interrupted |
| llmq-grace | done | failed | done with warnings | interrupted |
| llmq-claims | some claims accepted | input or warm-up failed | no claim accepted | |
| llmq-bench | done | a check or a fatal step failed | | |
| llmq-index | done | failed, with the reason on stderr | | |

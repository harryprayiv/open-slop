# llmq-index

`llmq-index` keeps a searchable index of your own files and answers questions from it, one at a time or as a conversation, citing the file and lines each answer came from. It refuses to send any text to a server that is not on loopback or your LAN.

## Where it stands against private-gpt

private-gpt is now a Python server that follows the Anthropic Messages API, with a demonstration web UI, retrieval with citations, tools (web search, web fetch, code execution), MCP connectors, skills, database and CSV analysis, and extended thinking, in front of any OpenAI-compatible inference server.

| Capability | private-gpt | llmq-index |
|---|---|---|
| Ingest files, chunk, embed, store | yes | yes: incremental by content hash, heading-aware chunks, PDFs cited by page, docx, odt, epub, HTML, org, rst, RTF, LaTeX, Markdown, text and source code |
| Retrieval | vector search, agentic RAG | hybrid: vector search and full-text search fused by rank, so exact names and identifiers are found |
| Cited answers | yes | yes, and an answer that cites nothing or cites a source it was not given is flagged |
| Conversations | yes | yes: `llmq-index chat`, stored by session name in the database, follow-up questions rewritten to stand alone before searching |
| Streaming answers | yes | yes, in `ask` and `chat` |
| Restrict a question to some documents | yes | yes: `--under PATH`, and `/under` inside a chat |
| List and remove documents | yes | yes: `docs`, `forget`, `prune` |
| Limits that follow the model and hardware | defers to the server | yes: the window, characters per token and prefill rate come from the server and the benchmark (see [Capacity](12-capacity.md)); answers are not capped |
| Web UI | yes | no |
| API for other programs | yes | no: the gateway has no retrieval route and does not stream yet |
| Tools, MCP, code execution, web fetch | yes | no |
| Database and CSV analysis | yes | no |
| Extended thinking shown separately | yes | no |
| Text kept on the LAN, enforced in code | by configuration | by type: a server outside the LAN is refused before a request exists |
| Typed, verified output | no | elsewhere in open-slop: llmq-grace and llmq-claims |

The missing rows are the work that remains: streaming and a retrieval route on the gateway, a web UI, tools, and showing a reasoning model's thinking.

## How one question is answered

1. **Rewrite.** In a conversation, the chat model first rewrites the new question so that it stands alone ("and the keys?" becomes "how are the gateway's keys stored?"), because the search sees only the question. The rewritten question is printed as `searching for: ...`. A first question is searched as asked.
2. **Search.** The question is embedded and searched two ways at once: the nearest vectors, and Postgres full-text search for any of its words. The two lists are fused by reciprocal rank, so a chunk found both ways ranks highest. `--depth` candidates are taken from each half, within the scope if one is set.
3. **Cut.** Hits that ranked outside the top ten of both halves are dropped, so a large window is not filled with weak matches.
4. **Pack.** As many of the remaining hits as fit are kept, best first. What fits is the chat model's window, less a quarter kept for the answer, less the conversation, at the model's characters per token. A model with a 128K window gets many more sources than one with 8K. `--max-wait SECS` limits the prompt further so that it should be read within that time at the model's measured prefill rate.
5. **Answer.** The instructions and numbered sources go as the system message, then the earlier turns that fit (at most half the prompt, oldest dropped first), then the question. The answer streams to the terminal and is not capped: it runs until the model stops or the window is full.
6. **Check.** The cited numbers are read back out. The sources are listed with the cited ones marked `*`, and a warning is printed when the answer cites nothing or cites a number it was not given.
7. **Learn.** The server's prompt token count refines the model's characters per token for the rest of the session.

The first line of `ask` and `chat` shows the capacity in use and where each figure came from, for example `window 16384 tokens (trained context within the catalogue's limit), 3.41 chars/token (measured by llmq-bench), prefill 38.2 tok/s, decode 4.1 tok/s`.

## How files are indexed

1. **Extract.** Markdown, text and source code are read as they are, so line numbers are the file's own. Org, reStructuredText, docx, odt, epub, HTML, RTF and LaTeX go through pandoc to Markdown, keeping their headings. PDFs go through pdftotext, and each page becomes a "Page n" heading so citations name the page.
2. **Split.** Headings outside code fences start sections, and the heading path ("Install > NixOS") goes with every chunk from that section. Paragraphs are packed to about 1600 characters (`--chunk-chars`), and no chunk exceeds one and a half times that.
3. **Embed.** Each chunk, with its heading path, becomes a vector from an embedding model on your LAN.
4. **Store.** Documents, chunks and vectors go into Postgres with pgvector, in one transaction per file.

Ingestion is incremental. A file whose content hash and vectors are already stored is skipped. A changed file is replaced whole. A file that has disappeared is removed at the end of a run over its directory.

## Privacy

Every server `llmq-index` sends text to is checked first. It must be loopback, a private address (10/8, 172.16/12, 192.168/16, 169.254/16, IPv6 unique-local or link-local), a single-label hostname, or a name ending in `.lan`, `.local`, `.internal` or `.home.arpa`. Anything else is refused before a request is built. Address literals, which the fleet uses, are the stronger guarantee.

## Setting it up

On the machine that will hold the index (blade in the reference fleet):

```nix
services.open-slop.rag = {
  enable = true;
  owner = "bismuth";
};
```

On the machine serving models, pull an embedding model as well as the chat model:

```nix
services.open-slop.server.models = [ "nomic-embed-text" "qwen2.5-coder:7b" ];
```

In the home-manager configuration of the owner on the index machine:

```nix
programs.llmq = {
  enable = true;
  endpoints.oracle = { address = "192.168.8.173"; backends = [ "cpu" ]; };
  rag = {
    embedAt = "oracle/cpu";
    embedModel = "nomic-embed-text";
    chatAt = "oracle/cpu";
    chatModel = "qwen2.5-coder:7b";
  };
};
```

Then:

    systemctl status open-slop-rag-db.service --no-pager
    llmq-index init
    llmq-index stats

Run `llmq-bench` over the chat model before relying on the limits, so that its characters per token and prefill rate are measured rather than guessed. Until then the first line of `ask` and `chat` says it is using the catalogue's guess, and the session learns a better figure from the first answer.

## Commands

| Command | Meaning |
|---|---|
| `llmq-index init` | Create the tables. Every command does this first, so it is only needed to check the database. |
| `llmq-index ingest DIR...` | Index every file under each directory. |
| `llmq-index search QUESTION` | Show what a question retrieves, with scores and whether each hit came from the vector half, the word half, or both. |
| `llmq-index ask QUESTION` | One answer, streamed, with numbered sources. |
| `llmq-index chat [--session NAME]` | A conversation. With a name, it continues that conversation; without one, it starts a new one named by the date and time. |
| `llmq-index sessions` | The stored conversations, with their turn counts. |
| `llmq-index docs [--under PATH]...` | The indexed documents: path, kind, size, chunks and when indexed. |
| `llmq-index forget FILE...` | Remove documents from the index. |
| `llmq-index stats` | Documents, chunks, vectors per embedding model, documents per directory. |
| `llmq-index prune --model NAME` | Remove one embedding model's vectors. |
| `llmq-index prune --root DIR` | Remove everything indexed under a directory. |

### Options for every command

These go before the command name.

| Option | Default | Meaning |
|---|---|---|
| `--db CONNINFO` | `$OPEN_SLOP_RAG_DB`, else `dbname=llmq_rag` | libpq connection string. |
| `--catalogue FILE` | `$OPEN_SLOP_CATALOGUE` | |
| `--embed-at ROW/BACKEND` | `$OPEN_SLOP_RAG_EMBED_AT` | Embedding server. |
| `--embed-model NAME` | `$OPEN_SLOP_RAG_EMBED_MODEL` | Embedding model. |

### ask and chat options

| Option | Default | Meaning |
|---|---|---|
| `--chat-at ROW/BACKEND` | `$OPEN_SLOP_RAG_CHAT_AT` | Chat server. |
| `--model NAME` | `$OPEN_SLOP_RAG_CHAT_MODEL` | Chat model. |
| `--under PATH` | everything | Only documents under this path. Repeat for several. |
| `--max-wait SECS` | none | Keep the prompt small enough to be read within this time at the measured prefill rate. Ignored for a model with no measured rate. |
| `--depth N` | 40 | Candidates taken from each half of the search. |
| `--session NAME` | a new session | chat only. |

### Inside a chat

| Input | Action |
|---|---|
| a question | answer it, using the conversation so far |
| `/sources` | print the last answer's sources in full |
| `/under PATH...` | search only under these paths from now on |
| `/under` | search everything again |
| `/scope` | show the current scope |
| `/new` | start a new session |
| `/quit`, `/exit`, end of input | leave |
| ctrl-c while answering | stop the answer |

Every question and answer is stored with the session, with the sources the answer was given and the model that wrote it. A conversation can be continued from any machine that reaches the database.

### ingest options

| Option | Default | Meaning |
|---|---|---|
| `--batch N` | 16 | Chunks per embedding request. |
| `--max-bytes N` | 20971520 | Skip files larger than this. |
| `--chunk-chars N` | 1600 | Characters a chunk is packed to. The hard limit is one and a half times this. |
| `--dry-run` | | Walk and split, print each file's kind and chunk count, write nothing. |

Directories whose names start with `.` are skipped, along with `dist-newstyle`, `.stack-work`, `node_modules` and `.spago`. Symbolic links are not followed. Files with a NUL byte in their first 8 KiB are refused as binary.

### search options

| Option | Default | Meaning |
|---|---|---|
| `--under PATH` | everything | As for ask. |
| `--depth N` | 40 | Candidates from each half. |
| `--limit N` | 8 | Hits shown. |

## Embedding models

Any ollama embedding model works, and llama-server started with `--embedding`. hailo-ollama has none. `nomic-embed-text`, `mxbai-embed-large`, `bge-*` and `snowflake-arctic-embed` get the task prefixes they were trained with; other models get none.

Vectors are stored per model, and a search reads only the asked model's vectors. To change models, ingest again with the new one (each file is replaced, which drops its old vectors), then `prune --model OLD` to remove what remains.

## Database tables

| Table | Holds |
|---|---|
| `rag_documents` | one row per file: root, path, content hash, kind, size, when indexed |
| `rag_chunks` | the chunks of each document, with heading path, line range and a full-text vector |
| `rag_embeddings` | one vector per chunk per embedding model, with an HNSW index per model |
| `rag_sessions` | conversation names |
| `rag_turns` | each question and answer, the sources given, and the model |

## Examples

    llmq-index ingest --dry-run ~/notes
    llmq-index ingest ~/notes /mnt/nas/documents
    llmq-index search "which port does the gateway listen on"
    llmq-index ask "how do I bump the hailo driver?"
    llmq-index ask --under ~/git/neoblade-config --max-wait 120 "where is the sops key for blade defined?"
    llmq-index chat --session homelab
    llmq-index sessions
    llmq-index docs --under ~/notes
    llmq-index forget ~/notes/old-draft.md
    llmq-index --embed-model mxbai-embed-large ingest ~/notes
    llmq-index prune --model nomic-embed-text

Embedding a large collection on a Pi's CPU takes hours. Run the first ingest as a user unit, and not while a benchmark is running:

    systemd-run --user --collect --unit=llmq-index-first llmq-index ingest /mnt/nas/documents
    journalctl --user -fu llmq-index-first

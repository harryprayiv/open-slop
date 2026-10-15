# llmq-index

`llmq-index` keeps a searchable index of your own files and answers questions from it, citing the file and lines each answer came from. It does what private-gpt does, in Haskell and Nix, and refuses to send any text to a server that is not on loopback or your LAN.

## How it works

1. **Extract.** Markdown, text and source code are read as they are, so line numbers are the file's own. Org, reStructuredText, docx, odt, epub, HTML, RTF and LaTeX go through pandoc to Markdown, keeping their headings. PDFs go through pdftotext, and each page becomes a "Page n" heading so citations name the page.
2. **Split.** Headings outside code fences start sections, and the heading path ("Install > NixOS") goes with every chunk from that section. Paragraphs are packed to about 1600 characters, and nothing exceeds the hard limit.
3. **Embed.** Each chunk, with its heading path, becomes a vector from an embedding model on your LAN.
4. **Store.** Documents, chunks and vectors go into Postgres with pgvector, in one transaction per file.
5. **Search.** A question is embedded and searched two ways at once: the nearest vectors, and Postgres full-text search for its words. The two lists are fused by reciprocal rank, so a chunk found both ways ranks highest. Exact names and identifiers, which vector search alone misses, are found by the word half.
6. **Answer.** The best chunks are numbered and sent with the question to a chat model, which is told to answer only from them and cite them by number. The citations are read back out and checked: an answer that cites nothing, or cites a number it was not given, is flagged.

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

On the machine serving models, pull an embedding model:

```nix
services.open-slop.server.models = [ "nomic-embed-text" ];
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

## Commands

| Command | Meaning |
|---|---|
| `llmq-index init` | Create the tables. `ingest` also does this. |
| `llmq-index ingest DIR...` | Index every file under each directory. |
| `llmq-index search QUESTION` | Show what a question retrieves, with scores and whether each hit came from the vector half, the word half, or both. |
| `llmq-index ask QUESTION` | Answer from the index, with numbered sources. Sources the answer cites are marked `*`. |
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

### ingest options

| Option | Default | Meaning |
|---|---|---|
| `--batch N` | 16 | Chunks per embedding request. |
| `--max-bytes N` | 20971520 | Skip files larger than this. |
| `--chunk-chars N` | 1600 | Characters a chunk is packed to. The hard limit is one and a half times this. |
| `--dry-run` | | Walk and split, print each file's kind and chunk count, write nothing. |

Directories whose names start with `.` are skipped, along with `dist-newstyle`, `.stack-work`, `node_modules` and `.spago`. Symbolic links are not followed. Files with a NUL byte in their first 8 KiB are refused as binary.

### search and ask options

| Option | Default | Meaning |
|---|---|---|
| `--depth N` | 40 | Candidates taken from each half of the search. |
| `--limit N` | 8 for search, 6 for ask | Hits shown, or sources given to the model. |
| `--chat-at ROW/BACKEND` | `$OPEN_SLOP_RAG_CHAT_AT` | ask only. |
| `--model NAME` | `$OPEN_SLOP_RAG_CHAT_MODEL` | ask only. |
| `--ctx N` | 8192 | ask only: the window asked of ollama. |

## Embedding models

Any ollama embedding model works, and llama-server started with `--embedding`. hailo-ollama has none. `nomic-embed-text`, `mxbai-embed-large`, `bge-*` and `snowflake-arctic-embed` get the task prefixes they were trained with; other models get none.

Vectors are stored per model, and a search reads only the asked model's vectors. To change models, ingest again with the new one (each file is replaced, which drops its old vectors), then `prune --model OLD` to remove what remains.

## Examples

    llmq-index ingest --dry-run ~/notes
    llmq-index ingest ~/notes /mnt/nas/documents
    llmq-index search "which port does the gateway listen on"
    llmq-index ask "how do I bump the hailo driver?"
    llmq-index --embed-model mxbai-embed-large ingest ~/notes
    llmq-index prune --model nomic-embed-text

Embedding a large collection on a Pi's CPU takes hours. Run the first ingest as a user unit, and not while a benchmark is running:

    systemd-run --user --collect --unit=llmq-index-first llmq-index ingest /mnt/nas/documents
    journalctl --user -fu llmq-index-first

## Not built yet

An evaluation set and an embedding benchmark, a retrieval route on the gateway, `/ask` inside the llmq-models chat, a Grace retrieval stage, re-ranking, and query rewriting.

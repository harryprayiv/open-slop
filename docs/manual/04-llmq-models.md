# llmq-models

`llmq-models` shows every model in the catalogue with its measured numbers, and opens a chat with one model or several at once for comparison. It reads the catalogue with your measurements laid over it.

## Synopsis

    llmq-models [--catalogue FILE] [--sort KEY]
    llmq-models --tui [--catalogue FILE] [--sort KEY]

`--sort` is one of `decode`, `prefill`, `load`, `params`, `restraint`, `name`; the default is `decode`. Without `--tui` the table is printed once at a width of 120, and if any served model needs measuring, the offer and the commands to run are printed to stderr.

## The interactive screen

Top to bottom: a title bar with the three views (table, graph, answers), the model count and the sort; a status line for the serving machine; an offer line when models need measuring; the view; and a key bar.

### Keys

| Key | Action |
|---|---|
| `j`, Down | next row |
| `k`, Up | previous row |
| `g`, `G` | first, last row |
| `s` | next sort column: decode, prefill, load, params, restraint, name |
| `r` | reverse the sort |
| `v` | table or graph |
| `p` | answers view, or back to the table |
| `b` | pending-measurements view, or back to the table |
| `y` | graph axis: decode or prefill |
| `m` | mark or unmark the row for a comparison chat |
| `c` | clear all marks |
| Enter, `a` | open a chat with the marked rows, or the selected row if none are marked |
| `q`, Esc | back to the table from answers or pending; otherwise quit |

### The table

| Column | Meaning |
|---|---|
| (marker) | `▶` the selected row, `+` marked for comparison |
| backend | cpu, hailo or llamacpp, with a coloured dot |
| model | the name; `◉` means it is in memory right now |
| params | parameter count; `~` means it was read from the name, not reported by the server |
| decode | tokens per second while writing, with a bar relative to the fastest model |
| prefill | tokens per second reading the prompt, at the largest measured size |
| load | seconds to load into memory |
| restraint | `●` for each probe refused, `○` for each answered; green at 0 refusals, yellow at 1, red at 2 or more |
| feel | conversational (5 tok/s or more), readable (2 to 5), batch (under 2), or unmeasured |

Unmeasured rows always sort last. The panel under the table shows the selected model in detail: speeds, warm re-read time, load time, parameters, quantisation, family, size on disk, window, whether it honours a JSON schema, licence, each restraint probe, an estimate of a typical question cold and warm, the catalogue summary, and any problems the last benchmark recorded.

### The graph

Parameters on a log scale across, decode or prefill rate up. Each model is a number coloured by its feel band, with a dotted line at 5 tok/s for decode. The selected model is drawn in reverse video. Models without the data are listed as "not plotted".

### The answers view

The first 300 characters of each restraint probe's answer, as the benchmark stored them, with whether it was judged a refusal.

### The status line

Read over HTTP from the first endpoint's host every 3 seconds: whether ollama, the NPU and llama-server answer (llama-server shows ok, busy or idle), the models in memory and for how long, load against cores, free memory, temperature (yellow at 65 C, red at 75 C), and the age of the reading. Load, memory and temperature come from a Prometheus node exporter on port 9100; without one the line says "no telemetry".

### Measurement offers

Every 10 minutes, and at start, the screen asks each server what it serves and compares that with your measurements using the same rules as `llmq-bench --pending`. When something needs measuring, the offer line says how many, and `b` shows each model with the reason and the two commands to run. Nothing is ever started for you. See [llmq-bench](05-llmq-bench.md).

## Chat

Enter opens a chat with the selected model, or with every marked model. With several models, each message goes to each model in turn, and each keeps its own history. The whole history is sent with every message, and the oldest messages are dropped when it would not fit the model's window.

### Chat keys and commands

| Input | Action |
|---|---|
| Enter | send |
| Esc, Ctrl-D on an empty line, Ctrl-C at the input | leave the chat |
| Ctrl-C while a model answers | stop it; the partial answer is kept, marked `[stopped]` |
| Backspace, Ctrl-U | delete a character, clear the line |
| PgUp, PgDn, Up, Down, mouse wheel | scroll, also while a model answers |
| Home, End | start of the conversation, newest line |
| `/back`, `/b`, `/q`, `/quit` | leave the chat |
| `/clear` | empty every history and start over |
| `/start`, `/stop` | start or stop llama-server by hand |

Mouse reporting is on, so hold Shift while dragging to select text.

After each answer a line shows the total time, the wait for the first words, the token count and the rate. Each answer is limited to 512 tokens. Reasoning models show "thinking" until their visible answer starts; their reasoning text is not displayed.

### llama-server in a chat

If a chat includes llama-server and it is not running, the chat starts it over ssh (`sudo -n systemctl start llama-server.service` on the endpoint's host, as your user) and waits up to 240 seconds for it. When you leave, it stops the server only if this chat started it. Your user must be in `services.open-slop.llamaServer.controlledBy` on that host.

### The hailo backend in a chat

The chat first tries hailo-ollama's chat route. If that answers 404 or 500, it switches for the rest of the chat to the generate route with a plain transcript, and says so once.

### Transcripts

Every chat is appended as it happens to `$XDG_STATE_HOME/open-slop/chats/YYYY-MM-DD-HHMMSS.md` (default `~/.local/state/open-slop/chats/`). The file name is shown at the right of the key bar.

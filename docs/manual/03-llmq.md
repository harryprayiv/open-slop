# llmq

`llmq` sends text to one model. A short question is one request. A long input is cut into parts that each fit the model's window, sent one at a time, kept on disk, and assembled into one document. An interrupted job resumes at the first unfinished part.

## Synopsis

    llmq [GLOBAL OPTIONS] [run] [RUN OPTIONS]
    llmq [GLOBAL OPTIONS] list
    llmq [GLOBAL OPTIONS] jobs
    llmq [GLOBAL OPTIONS] ask [-m MODEL] QUESTION

`run` is the default, so `llmq -m NAME -i file.txt` is a run. Global options go before the subcommand.

## Global options

| Option | Default | Meaning |
|---|---|---|
| `--catalogue FILE` | `$OPEN_SLOP_CATALOGUE` | The catalogue JSON. The client wrapper sets the variable. |
| `-s`, `--state DIR` | see below | Where jobs live. |
| `--key-file FILE` | `$LLMQ_KEY_FILE` | A bearer key, sent as `Authorization: Bearer`. Only needed when an endpoint is the gateway. |
| `-t`, `--timeout SECS` | 14400 | Ceiling for one request. A CPU prefill of a large part can take most of an hour. |

The job root is the first of: `--state`, `$LLMQ_STATE`, `$XDG_STATE_HOME/llmq`, `~/.local/state/llmq`.

## llmq list

Asks every endpoint which models it serves and prints a card for each: id, summary, blurb, window and output reserve, bytes per request, measured generation rate if there is one, docs fit and licence. Endpoints that do not answer, and catalogue models no server has, are listed on stderr as `unavailable`.

## llmq ask

    llmq ask -m qwen2.5-coder:7b "What does lib.recursiveUpdate do?"

One request, no job. The answer goes to stdout and the token statistics to stderr. Exit 1 if the answer was truncated by the window, 2 if it was kept with warnings.

## llmq run

| Option | Meaning |
|---|---|
| `-m`, `--model MODEL` | `ROW/BACKEND/NAME`, `BACKEND/NAME` or `NAME`. Without it, an fzf menu opens. |
| `-i`, `--input SRC` | `clip` (the X clipboard through xsel), `-` (stdin), or a file. Default: `clip` at a terminal, `-` when piped. |
| `-p`, `--prompt TEXT` | The instruction. |
| `-P`, `--prompt-file NAME` | A shipped prompt by name (`reference-docs`), or a path if it contains `/` or ends in `.md`. |
| `-o`, `--out FILE` | Also copy the result here. |
| `-c`, `--chunk-bytes N` | Override the model's byte budget per part. At least 1024. |
| `-r`, `--resume ID` | Continue a job. Uses the job's stored input, model, instruction and budget. |
| `-n`, `--dry-run` | Print the part plan and send nothing. |
| `--fresh` | Delete this input's existing job and start over. |
| `--packed` | Pack several files into one part instead of starting a new part at each file. |

### Choosing the instruction

`-p` and `-P` are exclusive. With neither, a dry run or piped stdin uses the default instruction, and an interactive terminal asks for one (Enter takes the default). The default is `$OPEN_SLOP_PROMPTS/reference-docs.md`, or a built-in copy when that variable is unset. It asks for one `##` heading per file with Purpose, Interface, Behaviour, Reasoning and Open questions sections.

### Choosing the model

Without `-m`, llmq asks every endpoint for its models and opens fzf with a preview of each model's card. Selecting nothing exits 0. Without a terminal, `-m` is required. A name matches when it equals a model id (ignoring `:latest`) or is a suffix of one at a `/`. A name that matches more than one model is refused with a request to use `ROW/BACKEND/NAME`.

### How input is cut into parts

Input in catsrc form has marker lines such as `# Start of ./hosts/oracle.nix` (also with `--`, `//`, `;`, `%`, `<!--`, `/*`, `'`, `REM`, `(*`, `{-` or `###` as the comment lead). By default every file starts a new part, and a file larger than the budget is split. With `--packed`, lines are packed up to the budget, and a part is cut before a file marker if the part is at least a quarter full, else before a paragraph break if it is at least half full, else before the line that would overflow. A single line longer than the budget is cut into pieces.

Each part is sent with a header saying which part it is, which file it begins partway through, and which files begin in it.

### The job directory

A job id is the first 12 hex characters of a hash over the model, the budget, the chunking mode, the instruction and the input. Running the same command again names the same job, so it resumes. Changing any of those starts a new job.

    <root>/<id>/
      meta.json              model, source, budget, part count, created
      input.txt              the input as received
      instruction.txt
      manifest.json          per part: bytes, file it continues, files it starts
      chunks/0001.txt        the text of each part
      parts/0001.md          the answer for each part; its existence marks the part done
      parts/0001.json        timings and token counts for each part
      failed/0001.raw        raw response of a failed attempt
      failed/0001.body.json  the request that failed
      output.md              the assembled document
      lock                   held while a run is in progress

Every write is atomic, so an interruption never leaves a half-written part. Two runs of the same job at once are refused by the lock.

### Checks on each part

A part fails, and the job stops, when the server returns an error, nothing, malformed JSON, only whitespace, or no answer within `--timeout`, or when the prompt filled the window (the server reported truncation, or prompt tokens reached ctx minus 16). A failure that is not caused by the window can be resumed with `llmq -r ID`. A window failure will fail again with the same parts; start a new job with a smaller `--chunk-bytes`.

Answers are not capped: ollama is sent `num_predict: -2` and llama-server `n_predict: -1`, so an answer runs until the model stops or the window is full. The catalogue's `predict` is the room the budget keeps free for the answer when sizing parts, not a limit. A part is kept with a warning when the answer filled the window, the prompt ate into the output reserve, prompt plus output exceeded the window, the text tokenised much denser than the catalogue assumes, or a file that starts in the part has no `##` heading naming it.

### Long runs

Run a long job as a user unit so it survives closing the terminal:

    systemd-run --user --collect --unit=llmq-docs llmq -m oracle/cpu/qwen2.5-coder:7b -i ~/input.txt
    journalctl --user -fu llmq-docs

### llmq jobs

Lists every job under the root with its id, parts done and total, model, input size, creation time, and either the path of `output.md` or `incomplete`.

## Examples

    llmq list
    llmq -m oracle/cpu/qwen2.5-coder:7b -i dump.txt -n
    llmq -m oracle/cpu/qwen2.5-coder:7b -i dump.txt -P reference-docs -o docs.md
    catsrc . | llmq -m qwen2.5-coder:7b -p "Summarise each file in two sentences."
    llmq -t 3600 -m qwen2.5-coder:7b -i dump.txt --packed -c 20000
    llmq -r 3f9a1c0b2d4e
    llmq jobs

## Exit status

0 finished, 1 failed, 2 finished with warnings, 130 interrupted. On interruption, finished parts are kept.

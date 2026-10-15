# llmq-claims

`llmq-claims` reads a catsrc dump and asks a model for two or three claims about each file: what it is for, its interface, its behaviour, the reasons its comments give, and what it marks as open. Every claim must quote its evidence from that file, and code checks each claim before it is accepted. Nothing checks that a claim is true; the checks make an unsupported claim hard to produce.

It needs an OpenAI-style endpoint that supports JSON-schema output and a prefix cache: llama-server directly, or the gateway.

## Synopsis

    llmq-claims -e URL -i DUMP [options]

| Option | Default | Meaning |
|---|---|---|
| `-e`, `--endpoint URL` | required | Base URL. Requests go to `URL/v1/chat/completions`. |
| `-m`, `--model ID` | | Sent as `model`; needed for the gateway. |
| `--key-file FILE` | | Bearer key. There is no environment fallback. |
| `-i`, `--input FILE` | required | A catsrc dump with `Start of` markers. |
| `-o`, `--out DIR` | `claims-out` | |
| `--min-claims N` | 2 | |
| `--max-claims N` | 3 | |
| `--max-tokens N` | 500 | Output cap per file. |
| `--instruction FILE` | built in | Replace the instruction. |
| `-t`, `--timeout SECS` | 600 | Per request. |
| `--only SUBSTR` | | Only files whose name contains SUBSTR. |
| `-n`, `--dry-run` | | Print the JSON schema and exit. |

## How it runs

The whole dump is the shared prefix of every request, so the server reads it once. A warm-up request fills the cache and reports how many prompt tokens were already cached. Then each file gets one request: the dump, the instruction, and the name of the file. The answer is constrained by a schema: two to three claims, each with the subject (one of the file names), a kind (purpose, interface, behaviour, reason, openIssue), one or two quotes of 12 to 160 characters, and a statement of 20 to 400 characters.

## The checks

Each claim is rejected at the first check it fails:

1. It repeats an earlier claim.
2. Its statement is empty.
3. Its statement does not end a sentence.
4. Its subject is not one of the files.
5. A quote does not occur in that file's own source, after normalising whitespace. A quote ending in `.` or `…` also matches by its first 20 or more characters.
6. It names an identifier that appears nowhere in the dump.
7. None of its identifiers appears in its quotes.
8. It gives a reason that is not quoted from a comment.

A claim whose evidence includes a comment is marked `stated`; otherwise `inferred`.

## Output

| File | Contents |
|---|---|
| `OUT/<file>.json` | accepted claims with resolved evidence offsets, and rejected claims with the reason |
| `OUT/<file>.raw.json` | the raw answer when it did not parse |
| `OUT/claims.md` | the accepted claims, grouped by file and kind, sorted, with `[inferred]` marked |

If an answer hits the token cap before the schema is complete, it is not valid JSON; raise `--max-tokens` or lower `--max-claims`.

Exit 0 when any claim was accepted, 2 when none was, 1 when the input or warm-up failed.

## Examples

    llmq-claims -e http://192.168.8.173:8081 -i dump.txt
    llmq-claims -e http://192.168.8.173:8081 -i dump.txt --only homebeacon/default.nix
    llmq-claims -e https://oracle:8443 -m oracle/llamacpp/qwen2.5-coder-7b --key-file ~/.config/llmq/key -i dump.txt -o out --max-claims 4 --max-tokens 700

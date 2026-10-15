# llmq-grace

`llmq-grace` runs a Grace program, called a stage, over the parts of a job. The stage declares the type of its answer. Grace turns that type into a JSON schema, the server is constrained to produce JSON of that shape, and Grace checks the answer against the type before it is kept. llmq-grace also checks the stage itself against the Haskell type it expects, when it loads, so a stage whose shape disagrees with the program fails before any request is sent.

It talks to the model through the gateway, so it needs a running gateway and a key.

## Synopsis

    llmq-grace --stage FILE.ffg -m MODEL -i INPUT [options]
    llmq-grace --stage FILE.ffg -m MODEL -r ID

| Option | Default | Meaning |
|---|---|---|
| `--stage FILE` | required | The Grace program. |
| `--gateway URL` | `$OPENAI_BASE_URL` | The gateway's base URL. |
| `--key-file FILE` | `$LLMQ_KEY_FILE` | Required. |
| `-m`, `--model ID` | required | Passed to the stage. Required also when resuming. |
| `-i`, `--input FILE` | | Required unless resuming. |
| `-o`, `--out FILE` | | Copy the result here. |
| `-s`, `--state DIR` | same as llmq | |
| `-c`, `--chunk-bytes N` | 12000 | Part size. |
| `-r`, `--resume ID` | | |
| `-n`, `--dry-run` | | List the parts. Creates the job directory. |
| `--fresh` | | Discard the existing job first. |
| `--packed` | | Pack files into parts, as in llmq. |

Jobs use the same directory layout and resume rules as `llmq`. The stage's source is stored as the job's instruction, so editing the stage starts a new job. Each part also gets `parts/NNNN.grace.json` with the typed value.

## The stage contract

A stage is a function from the part to a `Docs` value:

    args : { key: Key, model: Optional Text, path: Text, source: Text, part: Natural, parts: Natural }

    result : { files: List { path: Text, purpose: Text, interface: List Text,
                             behaviour: List Text, reasoning: List Text,
                             openQuestions: List Text } }

`path` is the first file that starts in the part. `source` is the part's text. The field is called `path` rather than `file` because Grace reads `file` as the start of a URI.

The shipped stage is `stages/reference-docs.ffg`. It asks for the same five sections as llmq's default prompt, through Grace's `prompt` with the result annotated by the type above.

Each returned file is rendered as Markdown: a `##` heading with the path, the purpose, then Interface, Behaviour, Reasoning and Open questions. A file that starts in a part but has no entry in the answer produces a warning.

## Example

    llmq-grace --stage stages/reference-docs.ffg --gateway https://oracle:8443 --key-file ~/.config/llmq/key -m oracle/cpu/qwen2.5-coder:7b -i dump.txt -o docs.md

Exit status matches llmq: 0, 1, 2 for warnings, 130 when interrupted.

## Building it

llmq-grace is in `pkgs.open-slop.llmq-grace`, not in the fleet package, because it links Grace and the compiler (about 4.6 GB). Install it on the workstation only.

# open-slop manual

open-slop runs small open-weight language models on your own machines and gives you several tools for using them. Everything runs on your LAN. Nothing in this project sends text to a hosted model.

This manual covers every program, every NixOS and home-manager option, every file the programs write, and every environment variable they read. It is written from the source.

## Which tool do I want?

The project has one library and seven programs. They differ in how you talk to the model and in what checks the output.

| You want to | Use | How the model is used |
|---|---|---|
| See which models you have, how fast each one is, and chat with one or several side by side | `llmq-models` | Interactive chat, free text, nothing checked |
| Ask one question from a script or a terminal | `llmq ask` | One request, free text |
| Turn a long input (a source dump, notes) into a document, resumably | `llmq run` | Many requests, one per part, free text with coverage warnings |
| Extract claims about each file in a dump, each one checked against quoted evidence | `llmq-claims` | One schema-constrained request per file, verified by code |
| Get output whose shape is a Haskell type, checked before your code sees it | `llmq-grace` | Typed Grace stage per part, through the gateway |
| Give other programs and machines one authenticated OpenAI-style endpoint | `open-slop-gateway` | Server, refuses requests that cannot fit or cannot be honoured |
| Ask questions of your own files, one at a time or as a stored conversation, with citations | `llmq-index` | Embeddings, hybrid retrieval, packing sources to the model's capacity, a streamed cited answer |
| Measure what each model costs on the machine that serves it | `llmq-bench` | Benchmark, run by hand, results kept in your cache |
| Have a model work on a Haskell project, with the compiler checking every edit | `llmq-agent` | One typed action per step under a grammar, edits on a branch of their own, tricorder's build report after each |

The usual confusion is between the chat and Grace. The chat in `llmq-models` is conversation: you type, the model answers, nothing is checked. `llmq-grace` is a batch pipeline: a Grace program declares the type of the answer, the server is forced to produce JSON of that shape, and Grace checks it before it is written. Use the chat to explore and compare. Use Grace when a program depends on the answer.

## Pages

1. [Installing](01-install.md): the flake, the overlay, NixOS and home-manager, unfree packages, persistence.
2. [Servers and the catalogue](02-servers.md): ollama, pinned models, llama-server, the Hailo NPU, firewall rules, the catalogue and how it is checked.
3. [llmq](03-llmq.md): one-off questions and resumable long jobs.
4. [llmq-models](04-llmq-models.md): the model table, graph, answers view and chat.
5. [llmq-bench](05-llmq-bench.md): the measurement protocol and how to run it overnight.
6. [llmq-claims](06-llmq-claims.md): evidence-checked claims.
7. [open-slop-gateway](07-gateway.md): the authenticated endpoint.
8. [llmq-grace](08-llmq-grace.md): typed Grace stages.
9. [llmq-index](09-llmq-index.md): asking questions of your own files, alone or as a conversation, and how it compares with private-gpt.
10. [Files, variables and exit codes](10-reference.md): one place for every path and variable.
11. [Troubleshooting and known quirks](11-troubleshooting.md).
12. [Capacity](12-capacity.md): how every program works out how much a model can take, from the server, the benchmark and the catalogue, and why answers are not capped.
13. [llmq-agent](13-llmq-agent.md): a model working on a project, one typed action at a time, with tricorder as the judge of every edit.

## Words used throughout

A row is a machine that serves models, such as oracle. A backend is one inference server on a row: `cpu` is ollama, `hailo` is hailo-ollama on the NPU, `llamacpp` is llama-server. An endpoint is a row and a backend together, written `row/backend`, for example `oracle/cpu`. A model id is `row/backend/name`, for example `oracle/cpu/qwen2.5-coder:7b`. Every program accepts any unique suffix of a model id, so `qwen2.5-coder:7b` works when only one server has it.

The catalogue is the JSON description of the backends and models, built by Nix. The measurements file is `measured.json` in your cache, written by `llmq-bench` and laid over the catalogue when `llmq` and `llmq-models` read it.

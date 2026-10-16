# tricorder and Grace: what they offer open-slop

Researched 2026-10-16 from the tricorder repository (github.com/tweag/tricorder, package version 0.5.0.0, tricorder-mcp 0.1.3.0) and the Grace repository (github.com/Gabriella439/grace, commit a70b1ef of 2026-06-13), reading the source as well as the READMEs.

## Summary

tricorder does not close the private-gpt gap. private-gpt's missing pieces in open-slop are a streaming API with a retrieval route, a web UI, tool use, and conversation in a browser. tricorder provides none of these. It is a Haskell build oracle for coding agents: a daemon that keeps GHCi loaded, rebuilds on every change, runs tests, evaluates expressions in comments, and returns diagnostics and test results as JSON. That makes it the right component for a different goal, which you also named: an agent loop in which a local model writes Haskell, the compiler judges it, and the errors go back to the model. For that goal it fits well and saves real work.

Grace is already in open-slop and is used for one of its features out of several. It has a compile-check-repair loop of its own (`import prompt`), multi-turn conversations (`history`), and a way to express tool calls as a closed union type that the server decodes under a grammar. That last one is the most useful idea in either project for models the size of the ones on oracle, because it gives typed tool use without depending on a model's native function calling.

The plan at the end combines them: a Haskell agent driver whose actions are a closed Grace/Haskell union, executed by open-slop, with tricorder as the judge of Haskell code and llmq-index as the memory.

## Status, 2026-10-16

Steps 1 to 4 of the plan below are implemented; see [llmq-agent](../manual/13-llmq-agent.md).

- The gateway writes a message's name at the top of its content and maps `reasoning_effort` to each backend's thinking switch.
- `OpenSlop.Agent.Action` defines the decision type. Its schema, checked against llama.cpp's converter, becomes a grammar that accepts every decision and rejects an unknown action. Grace, given `stages/agent-step.ffg`, sent byte-for-byte the same schema through the gateway, and llmq-grace refuses a stage whose type drifts from the Haskell one.
- `llmq-agent` runs the loop in a git worktree on its own branch, with tricorder's `status --json` decoded by `OpenSlop.Agent.Oracle` as the build report after every edit.
- Loading the Grace stage found a lexer problem in Grace: an alternative whose name starts with a built-in type's name (`ListFiles` starts with `List`) does not parse. The action was renamed BrowseDirectory. The fix in Grace would be a word boundary after the built-in type names in its lexer.

Steps 5 to 7 are not done.

## tricorder

### What it is

| | |
|---|---|
| Maintainers | Christian Georgii and Victor Bakke at Tweag; built on Tweag's atelier libraries (effectful-based) |
| Licence | MIT |
| Executables | `tricorder` (CLI and TUI), `tricorder-daemon`, `tricorder-mcp` |
| GHC | tested 9.6.7 to 9.14.1; open-slop's pinned 9.6 is supported |
| Build tools | cabal (multi-package `cabal.project`, multiple home units by default) and stack, detected automatically |
| Nix | flake with an overlay, a home-manager module and a NixOS module (`programs.tricorder.enable`); built with haskell.nix, so it needs cache.iog.io and tweag-tricorder.cachix.org to avoid compiling GHC |
| Platforms | Linux and macOS |

### How it works

One daemon per project runs `cabal repl --enable-multi-repl` over every component it finds, watches the source directories, reloads on change, and after a clean build runs the test suites (each in its own GHCi, with a timeout and a heap limit) and evaluates eval comments. Any number of clients query the same state over a socket, so nothing is built twice. The daemon restarts when cabal files change and shuts down after five idle minutes unless told otherwise.

Configuration is `.tricorder.yaml`: the build, test and eval command templates and targets, watch directories and exclusions, test timeout and memory limit, hpack regeneration, idle timeout, logging, and shell hooks before and after start and reload.

### What it returns

`tricorder status --json` returns the build state as typed JSON (the types derive `ToJSON` in `Tricorder.Build`):

- the phase: starting, building (with modules compiled out of total), failed, post-building, or finished
- for a finished build: when it completed, how long it took, how many modules, and the diagnostics
- each diagnostic: severity (error or warning), file, line, column, end line, end column, a title and the full GHC message
- after the build: the test suites' results and the eval comments' results

Other commands:

| Command | What it gives |
|---|---|
| `tricorder status --wait` | blocks until the current build cycle finishes, then reports |
| `tricorder status --expand N` | the full message of diagnostic N only |
| `tricorder source Module` or `Module#name` | the source of any module, the project's own or an installed dependency's, recovered from the haddock HTML on disk; works offline |
| eval comments `-- $> expr` | results of expressions written in comments, evaluated in the module's scope after each build |
| `tricorder ui` | the TUI dashboard for a person |

`tricorder-mcp` is an MCP server over stdio exposing the same as tools: start, stop, restart, status, test_results, source, eval_comments, log_contents and log_path. It is a thin wrapper that runs the CLI with `--json`.

### What it would give open-slop

1. **A build oracle for an agent loop.** A model proposes a change, tricorder rebuilds, and the diagnostics come back as structured JSON with exact spans. This is the feedback signal that makes a small model useful on Haskell: GHC's type errors are precise, and a model that sees them can repair code it could not write correctly first time. open-slop has nothing like this today.
2. **Offline library source for retrieval.** `tricorder source` returns the real source of any dependency from the haddock HTML that Nix builds already put on disk. Feeding that into llmq-index gives retrieval over the exact library versions a project uses, so an answer about `Data.Map.Strict.insertWith` cites the installed code instead of the model's memory.
3. **Tests and eval comments as checks.** A change is accepted when the build is clean and the test suites pass, both read from the same JSON. Eval comments let a model state an expectation (`-- $> parseDuration "5m"`) and see the result without writing a test file.
4. **A dashboard for you.** While an agent works, `tricorder ui` shows you the same build state it sees.

### What it does not give

- **No PureScript.** tricorder drives GHCi only. The PureScript equivalent is `purs ide server`, which rebuilds single modules on request and returns errors as JSON (`purs compile --json-errors` gives the same shape for a whole build). An open-slop PureScript oracle would wrap that directly; tricorder's code is not reusable for it, but its JSON shape is a good model to copy so both languages look the same to the agent.
- **No tool calling in open-slop to use it with.** The gateway refuses `tools` and `tool_choice`, and open-slop has no MCP client. Using tricorder-mcp as written needs both. Calling the CLI with `--json` from Haskell needs neither, and is what the MCP server does internally.
- **Nothing for the private-gpt gaps.** No UI, no API, no retrieval.

### Cautions

- Hackage showed a failed build report for 0.5.0.0 on 2026-10-02. The flake builds its own toolchain and is the dependable way in.
- A module using a custom GHC plugin did not reload correctly as of June 2026, according to the author.
- The haskell.nix build pulls a second Haskell toolchain onto winsmuth. It is a workstation tool and should never go on a Pi.

## Grace

### What open-slop uses today

One feature: `prompt` with a type annotation. `llmq-grace` runs one stage, `stages/reference-docs.ffg`, whose result type Grace turns into a JSON schema; the gateway passes that schema to ollama or llama-server, which constrain decoding to it; Grace checks the result against the type. llmq-grace also checks the stage against the Haskell `Docs` type before any request.

### What Grace has that open-slop does not use

| Feature | What it does | Use in open-slop |
|---|---|---|
| Types inferred from use | The schema comes from how the result is used, without an annotation | Shorter stages |
| `import prompt` | The model writes a Grace expression of a required type. Grace type-checks it, and on failure sends the attempt and the error back and asks again, up to four attempts in total | A working compile-check-repair loop that already exists, for Grace code |
| `history` | Prior system, user and assistant messages in a prompt | Multi-turn stages; a conversation as a typed value |
| Union types with `fold` | The model returns a list of alternatives such as `HttpRequest { url }` or `ShellCommand { executable, arguments }`; `fold` turns each into an action | Typed tool use without native function calling |
| `import read` | Evaluates a string as Grace code, still type-checked | Running code a model wrote, safely typed |
| `import github`, file and URL imports | Code from a repository, a path or a URL | A shared library of stages |
| `model`, `effort`, `search` fields | Choose the model, the reasoning effort and OpenAI web search | `model` already used; `effort` ignored by the gateway; `search` refused by the gateway, which keeps text on the LAN |
| `grace repl` | Interactive | Trying stages against the gateway by hand |

### Typed tool use, and why it suits small models

OpenAI-style function calling depends on the model having been trained to emit tool calls in a particular format, and small open models are unreliable at it. Grace's tool example does it differently: the model's answer is typed as a list of a union of action records, Grace turns that type into a JSON schema with `anyOf`, and the server's grammar makes any other output impossible. The model only chooses among actions and fills in fields, which a 7B model does reliably under a grammar. The program, not the model, decides what each action does. For open-slop this means tools work on oracle today, through the gateway, without adding `tools` support.

### Where Grace assumes a frontier model

- **The default model is `gpt-5-mini`**, and `search` defaults to `gpt-5-search-api`. Your fork sends requests to the gateway through `OPENAI_BASE_URL`, so every stage must name a local model.
- **`import prompt` sends Grace's grammar and type-inference documentation with every attempt**: `prompts/abnf.md` and `prompts/inference.md`, about 29 KB, which is roughly 8,000 to 10,000 tokens, plus up to four attempts. On oracle's CPU that is minutes of prefill per attempt, and most of a 16K window. llama-server's prefix cache makes the repeats cheap, because the documentation comes first and does not change. So `import prompt` should be pointed at llama-server, and its cost read from llmq-bench's measured prefill rate before it is used.
- **Messages carry a `name`** ("Instructions", "Type", "Attempt", "Error") that the gateway currently drops. The content still arrives, but the model loses the labels that say which system message is the required type and which is the compiler error. The gateway should fold the name into the content for backends that ignore it.
- **`effort` is ignored** by the gateway. It could map to the reasoning switch on models that have one.

## What open-slop has today against what it could have

| Area | Today | With tricorder and more of Grace |
|---|---|---|
| Writing Haskell with a local model | Free-text answers, nothing checked | A loop: propose, build, read diagnostics, repair, test, until clean or out of attempts |
| Writing PureScript | Nothing | The same loop against `purs ide server` |
| Writing Grace | Stages written by hand | `import prompt` writes them against a required type, with Grace's own repair loop |
| Tool use | Refused by the gateway | Typed actions as a Grace union under a grammar; later, MCP |
| Retrieval over code | Your files | Your files plus the exact source of every dependency, from `tricorder source` |
| Knowing whether an answer is right | Citation checks in llmq-index, evidence checks in llmq-claims | Plus the compiler and the test suites for code |
| Conversation | llmq-index chat, llmq-models chat | Plus conversations as typed Grace values with `history` |

## Plan

Each step builds on the one before and can be tested on its own.

1. **Gateway fixes for Grace.** Fold message names into content. Map `effort` where a backend can use it. Accept `anyOf` schemas and test them against ollama and llama-server, since typed tools depend on it.
2. **Typed actions.** A Haskell `Action` union (read a file, search the index, look up library source, propose an edit as a unified diff, check the build, run tests, finish with an answer), with the same type in Grace. The model returns one action per turn under the grammar. Nothing outside the union can be expressed.
3. **The executor.** `llmq-agent`, a Haskell driver that runs actions inside an allowlisted project directory, applies edits on a scratch branch only, and records every step. Build checks call `tricorder status --wait --json` and decode it into Haskell types mirroring `Tricorder.Build`.
4. **The loop.** Propose, apply, build, read diagnostics, repair, test, stopping on a clean build with passing tests or at an attempt limit, with every turn sized by Capacity.
5. **Dependency source in the index.** `llmq-index ingest-source` runs `tricorder source` for a project's imported modules and indexes the results under a `deps:` root.
6. **PureScript.** The same oracle interface over `purs ide server`, returning diagnostics in the same shape.
7. **MCP**, if it is still wanted: a small MCP client in Haskell so the agent can use tricorder-mcp and other MCP servers directly. Step 3 makes this optional.

Steps 1 to 4 give a working Haskell agent on hardware you already have, slow on oracle but correct. The same code runs unchanged on a larger machine, where it becomes fast.

## Sources

- tricorder repository: https://github.com/tweag/tricorder (README; docs/configuring-tricorder.md; docs/features-of-tricorder.md; docs/using-with-coding-agents.md; docs/using-with-nix.md; docs/proposals/003-source-lookup; packages/tricorder/src/Tricorder/Build.hs; packages/tricorder-mcp/src/Tricorder/MCP/Tools.hs)
- tricorder on Hackage: https://hackage-content.haskell.org/package/tricorder
- tricorder announcement: https://discourse.haskell.org/t/ann-tricorder-a-new-development-tool-for-haskell-and-llms/14208
- Grace repository: https://github.com/Gabriella439/grace (README; examples/tools.ffg; examples/eval.ffg; examples/chaining.ffg; src/Grace/Prompt.hs; src/Grace/Prompt/Types.hs; prompts/)

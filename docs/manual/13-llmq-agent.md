# llmq-agent

`llmq-agent` gives a task to a local model and lets it work on a project one action at a time: look around, read files, look up library source, search your indexed notes, edit, and finish. Every edit is checked by the compiler before the model takes its next step. The model's replies are constrained to a fixed set of typed actions, none of which runs a command, and every path is checked to be inside the project. Its changes land on a branch of their own for you to review.

It is the first part of the agent loop described in [the tricorder and Grace write-up](../research/tricorder-and-grace.md): steps 1 to 4 of its plan. PureScript, dependency source in the index, and MCP are not done yet.

## What it needs

| Need | Why |
|---|---|
| A model on ollama (`cpu`) or llama-server (`llamacpp`) on your LAN, named in the catalogue | The model. hailo-ollama is refused because it cannot constrain an answer to a schema. |
| git | The run works in a git worktree on its own branch. Use `--in-place` for a directory that is not a repository. |
| The project's development shell | tricorder runs `cabal repl` in the project, so `cabal` and the project's GHC and dependencies must be on PATH. Run llmq-agent from inside `nix develop`. |
| tricorder (optional) | The build oracle for Haskell. Without it, edits are made but not checked, and LookupSource and Check are not offered. |
| llmq-index's database (optional) | For SearchIndex, with `--index`. |

## Synopsis

    llmq-agent --task TEXT [options]
    llmq-agent --task-file FILE [options]

| Option | Default | Meaning |
|---|---|---|
| `-t`, `--task TEXT` | | What to do, or the question to answer. |
| `--task-file FILE` | | The task, read from a file. One of the two is required. |
| `-p`, `--project DIR` | `.` | The project. tricorder runs here, so it should be the directory with `cabal.project` or the `.cabal` file. It may be a subdirectory of the repository. |
| `--chat-at ROW/BACKEND` | `$OPEN_SLOP_AGENT_CHAT_AT`, else `$OPEN_SLOP_RAG_CHAT_AT` | The model's server. |
| `-m`, `--model NAME` | `$OPEN_SLOP_AGENT_MODEL`, else `$OPEN_SLOP_RAG_CHAT_MODEL` | The model. |
| `--catalogue FILE` | `$OPEN_SLOP_CATALOGUE` | Set by the home-manager wrapper. |
| `--max-wait SECS` | none | Keep each prompt small enough to be read in this many seconds at the prefill rate llmq-bench measured. Without it, the window alone decides. |
| `--from REV` | `HEAD` | The revision the run's branch starts from. |
| `--steps N` | 60 | Stop after this many steps. |
| `--read-only` | off | Offer no edits. The model explores and answers. |
| `--in-place` | off | Work in the project directory itself, without git. Edits are not committed anywhere. |
| `--tricorder PATH` | `$TRICORDER`, else `tricorder` on PATH | The tricorder executable. |
| `--tricorder-required` | | Fail if tricorder cannot be found or started, instead of running without it. |
| `--no-oracle` | | Do not use tricorder even if it is there. |
| `--build-timeout SECS` | 3600 | The longest wait for one build and its tests. |
| `--settle SECS` | 3 | After an edit, how long an unchanged and finished build state means the edit triggered no rebuild. |
| `--index` | off | Offer SearchIndex over llmq-index's store. |
| `--db`, `--embed-at`, `--embed-model` | llmq-index's variables | The index and its embedding server, as for llmq-index. |
| `--under PATH` | | Limit SearchIndex to documents under this path. Repeat for several. |

## Examples

On winsmuth, in the project's shell:

    cd ~/src/open-slop/haskell
    nix develop
    llmq-agent --task "Make Workspace.numbered say how many lines the file has when the range is past the end."

A question rather than a change:

    llmq-agent --read-only --task "Where does the gateway decide how many bytes of input fit, and what does it compare them with?"

With your notes and other repositories searchable:

    llmq-agent --index --under ~/src --task-file task.md

Reviewing what it did:

    git log --oneline HEAD..llmq-agent/2026-10-16-101500
    git diff HEAD...llmq-agent/2026-10-16-101500
    git merge llmq-agent/2026-10-16-101500

## How a run goes

1. It works out the model's capacity (window, characters per token, measured prefill rate) the same way llmq-index does, and prints it.
2. It makes a git worktree of the project at `--from` on a new branch, `llmq-agent/<run>`, under the run's directory. Your checkout is never written to. If your checkout has uncommitted changes it says so, because those changes are not in the worktree.
3. It starts tricorder in the worktree and waits for the first build, so the model starts knowing whether the project builds and which tests pass.
4. It sends the instructions, the task, the top level of the project and that first build report, and asks for a decision.
5. Each decision is a short plan and one action. The server is given a JSON Schema for the decision and samples only JSON of that shape, so a reply is always one of the actions, with the fields that action has.
6. llmq-agent carries out the action inside the worktree and sends back what happened. After an edit it commits the change on the run's branch, waits for tricorder to rebuild and run the tests, and the build report is the observation. The model never has to ask whether its edit compiled.
7. This repeats until the model finishes, the step limit is reached, or the run gets stuck.
8. The worktree is removed. The branch stays, with one commit per edit. The run prints the diff summary and the command to review it.

## The actions

| Action | Fields | What happens |
|---|---|---|
| BrowseDirectory | `directory` | The entries directly under a directory of the project, directories marked with `/`. `.git`, `dist-newstyle`, `.direnv`, `.stack-work`, `node_modules`, `.spago` and `output` are left out. |
| ReadFile | `path`, `startLine`, `stopLine` | The file's lines, numbered. Both lines may be null for the whole file. A range too long for the observation is cut at a line, and the model is told where to continue. |
| SearchIndex | `query` | Up to eight hits from llmq-index's hybrid search, with path, lines and text. Offered only with `--index`. |
| LookupSource | `query` | `tricorder source QUERY`: the source of a module (`Data.Map.Strict`) or one definition (`Data.Map.Strict#insertWith`), from the project or any installed package, read offline from the documentation on disk. Offered only with tricorder. |
| ReplaceText | `path`, `replace`, `with` | Replace the one occurrence of `replace` with `with`. Refused when the text is not there, with a note when it is there with different spacing, and when it occurs more than once. |
| WriteFile | `path`, `text` | Create the file or replace all of it. |
| Check | none | The latest settled build report. Offered only with tricorder. |
| Finish | `summary` | Stop. After any edit, Finish is accepted only when the latest build has no errors and every test suite passed; otherwise it is refused and the build report is the observation. Without tricorder, Finish is always accepted. |

ReplaceText and WriteFile are not offered with `--read-only`.

There is no shell action. The set of actions is a Haskell type, and adding one means adding a constructor and writing what it does.

Every path is resolved inside the worktree. An absolute path, a path with `..`, a path inside `.git`, `.tricorder.yaml` (whose hooks are shell commands), and a path that leads outside the project through a symbolic link are all refused before any read or write.

## What is and is not confined

The actions confine what the model reads and writes to the project. They do not confine what the build runs. Compiling the project runs its Template Haskell and any custom `Setup.hs`, and tricorder runs the test suites, and the model may have written any of that code. On your own tasks on your own machine that is the same trust you give any code you compile. For a task from someone else, run llmq-agent itself inside a sandbox with no network and no access to your home directory.

## Why the model can only answer with an action

The decision type is in `OpenSlop.Agent.Action`. Its JSON Schema is the one Grace derives from the same type: a union is an object whose alternatives each have a constant `tag` and a `contents`, every record lists all its fields as required and allows no others, an Optional is the type or null, and a Natural is a number. ollama turns the schema it is given as `format` into a grammar, and llama-server does the same with `response_format`; both use llama.cpp's converter. Sampling under that grammar cannot produce an unknown action, a missing field, or prose.

This works with small models because the model only chooses among a few alternatives and fills in fields. It does not depend on a model having been trained on a function-calling format, which small open models handle unreliably.

The grammar also fixes the order in which the model writes fields, and that order is alphabetical, because that is how the schema's JSON is written. The labels were chosen so that order reads sensibly: `plan` before `step`, `path` before what is done to it, the text to replace before its replacement, the first line before the last. Inside an alternative, `contents` comes before `tag`, which is Grace's encoding and cannot be changed.

A reply that still does not decode (cut off, or from a server that ignored the schema) is shown to the model with the reason, and the run continues. Three in a row stop the run.

## The build oracle

[tricorder](https://github.com/tweag/tricorder) keeps one GHCi session per project, loaded with `cabal repl --enable-multi-repl`, rebuilds when a watched file changes, runs the test suites after a clean build, and evaluates `-- $>` comments. llmq-agent reads `tricorder status --json` and turns it into a report of the same shape whatever the compiler: the outcome, each diagnostic with its file and span, each test suite with its failing cases, and the eval comments. The report the model reads shows errors first, in full while they fit, then warnings by title, then the tests, and says how many diagnostics were left out.

After an edit, llmq-agent waits for a build different from the one before the edit, identified by tricorder's build id and completion time. An edit to a file tricorder does not watch triggers no build; after `--settle` seconds of an unchanged, finished state, that state is taken as the answer.

tricorder's daemon stops itself after five idle minutes by default, which a slow model can exceed between edits. When status says "Stopped.", llmq-agent starts it again and waits for its first build. Configure tricorder itself in the project's `.tricorder.yaml`, for example to raise the idle timeout or to set test targets.

## How much the model is sent

The budget per step is the prompt that fits the model's window beside the room kept for the answer, from [Capacity](12-capacity.md), further limited by `--max-wait`. Within it:

- One observation may take at most a third of the budget, so one large file or a long error list cannot push every earlier step out.
- The newest steps are sent whole. When the transcript no longer fits, older steps are shortened to their plan, the action in a few words, and the first line of what happened, written as prose so the model cannot copy them as a decision. When even that does not fit, the oldest are dropped and the model is told how many.
- Characters per token are refined from the prompt counts ollama reports, as llmq-index does.

Answers are not capped. Each step's prompt is the previous one with the newest step appended until shortening starts, so on llama-server, which keeps the prompt cache between requests, a step costs the prefill of the new part. That makes `llamacpp` the better endpoint for this on oracle.

## What is written

Each run has a directory, `$XDG_STATE_HOME/llmq-agent/<run>/`:

| File | Contents |
|---|---|
| `steps.jsonl` | One JSON object per step: the plan, the action, the observation, prompt characters, the prompt tokens the server counted, and seconds. A reply that did not decode is recorded with the raw text and the error. |
| `transcript.md` | The task and what the run printed, as it went. |
| `result.json` | How the run ended, with the summary or the reason. |
| `worktree/` | The worktree, while the run lasts. |

The branch `llmq-agent/<run>` in your repository holds one commit per edit, with the step number and the plan's first line as the message. Commits skip hooks.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | The model finished, and the Finish was accepted. The summary is printed on stdout. |
| 1 | The model's server failed, or the run could not start. |
| 2 | The step limit was reached, or the run was stuck: the same action three times running, or three replies in a row that did not decode. |

## The same type in Grace

`stages/agent-step.ffg` declares the decision type in Grace. llmq-grace loads it against the Haskell type, so the two cannot drift apart without llmq-grace refusing the stage:

    llmq-grace --agent-stage stages/agent-step.ffg

With a task, it sends one step through the gateway and prints the decision Grace decoded:

    llmq-grace --agent-stage stages/agent-step.ffg --gateway https://oracle:8443/v1 -m oracle/cpu/qwen2.5-coder:7b --task "Add a --verbose flag."

Checked 2026-10-16: the schema Grace sent through the gateway for this stage is identical to the one llmq-agent sends, and a stage with an extra alternative or a field of the wrong type fails to load with Grace's type error.

A Grace program can fold the decision into effects the way Grace's tools example does. llmq-agent does that in Haskell, because the effects (writing files, committing, waiting for builds) need more than Grace can do.

## Installing

llmq-agent is in `pkgs.open-slop.llmq` with the other fleet programs, and the home-manager wrapper puts git on its PATH. tricorder comes from its own flake, which builds with haskell.nix, so it needs two binary caches or it compiles GHC.

In neoblade-config's `flake.nix`, the input, without `follows`, so that its pinned nixpkgs matches the caches:

```nix
inputs.tricorder.url = "github:tweag/tricorder";
```

On winsmuth, the caches:

```nix
nix.settings = {
  extra-substituters = [
    "https://cache.iog.io"
    "https://tweag-tricorder.cachix.org"
  ];
  extra-trusted-public-keys = [
    "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
    "tweag-tricorder.cachix.org-1:PbwYPJ9gF8Wns14ai0sHK3iblqFd5YUrj0zEzGsJ/wg="
  ];
};
```

In the home-manager configuration for winsmuth:

```nix
programs.llmq.agent = {
  chatAt = "oracle/cpu";
  model = "qwen2.5-coder:7b";
  tricorder = inputs.tricorder.packages.${pkgs.system}.tricorder;
};
```

| Option | Default | Meaning |
|---|---|---|
| `programs.llmq.agent.chatAt` | null | The endpoint, `row/backend`. Null means `rag.chatAt`. |
| `programs.llmq.agent.model` | null | The model. Null means `rag.chatModel`. |
| `programs.llmq.agent.tricorder` | null | The tricorder package. Null means whatever tricorder is on PATH when llmq-agent runs. |

tricorder is a workstation tool. It should not go on a Pi.

## Choosing a model

Use a coding model that follows instructions well. The grammar guarantees the shape of each step; whether the step is sensible depends on the model. When llama-server on oracle serves a coding model, prefer it over ollama for the prompt cache described above. On oracle's CPU every step costs a prefill of the new part of the transcript and the decoding of one decision, and edits cost a build on winsmuth. On a machine with a large GPU and a 32B or 70B coder the same program runs the same loop faster and with better judgement. Nothing in it is specific to the Pi.

## Known limits

- PureScript has no oracle yet. The interface is ready for one over `purs ide server`, returning the same report.
- Dependency source is looked up one query at a time with LookupSource; it is not yet indexed for SearchIndex.
- There is no MCP client.
- llmq-agent talks to the backend directly, not through the gateway, the same as llmq-index.
- `--in-place` writes to your directory with no branch and no commits.
- A test suite that never finishes holds a step until `--build-timeout`.
- tricorder's known problem with modules that use custom GHC plugins applies.

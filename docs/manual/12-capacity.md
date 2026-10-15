# Capacity: limits that follow the model and the hardware

open-slop has to decide, for every request, how much text to send: how much of a conversation to keep, how many retrieved sources to include, how big a part of a long job may be. Those decisions depend on the model and on the machine serving it. A 1.5B model on a Pi's NPU holds 2048 tokens; a large model on a GPU server may hold 128K. The code fixes none of these numbers. They come from three places, in this order of authority.

## The window

| Engine | Where the window comes from |
|---|---|
| llama-server | The context it allocated at start, from `/props`. |
| ollama | The smaller of the model's trained context (from `/api/show`) and the catalogue's `ctx` for that model, else for the backend. ollama allocates memory per request from `num_ctx`, so the catalogue's figure is the operator's limit for this hardware. |
| hailo-ollama | 2048, which every zoo model has. |

When the server reports nothing, the catalogue's figure is used and the program says so.

On a Pi the cpu backend's catalogue `ctx` is 16384, so a 128K model gets 16K there. On a bigger machine, raise it in `catalogue.extra`:

```nix
services.open-slop.catalogue.extra.backends.cpu.ctx = 131072;
programs.llmq.catalogue.extra.backends.cpu.ctx = 131072;
```

or for one model:

```nix
programs.llmq.catalogue.extra.models.cpu."qwen2.5:72b".ctx = 131072;
```

## Characters per token

Text is budgeted in characters, because it is in hand before the server tokenises it. Each model's tokeniser differs, so the ratio is measured:

1. **llmq-bench** records `charsPerToken` for every model it measures: the median, over its grid prompts, of characters sent divided by the prompt tokens the server counted. Those prompts are Haskell source with comments, so prose usually tokenises a little more efficiently than this figure says, which errs on the side of fitting.
2. **During use**, every answer from ollama reports how many tokens the prompt was, and the chat in llmq-models and llmq-index refine the ratio from it. A count far from the current figure is ignored, because a server that reused a cached prefix counts only the tokens it evaluated.
3. **The catalogue's** backend `charsPerToken` (2.8) is the fallback for a model nothing has measured yet.

## Rates

llmq-bench's measured prefill rate (at the largest prompt measured) and decode rate are part of a model's capacity. `llmq-index ask --max-wait SECS` uses the prefill rate to keep the prompt small enough to be read in that time. On a Pi this is the difference between a ten-second answer and a ten-minute one. On a fast machine it rarely bites.

## Room for the answer

When deciding how much to send, a quarter of the window (at least 512 tokens) is kept free for the answer. This is a reservation, not a cap. The answer itself is not limited:

| Engine | What is sent |
|---|---|
| ollama | `num_predict: -2`: generate until the model stops or the context is full |
| llama-server, native route | `n_predict: -1`: no cap |
| llama-server, OpenAI route | no `max_tokens` |
| hailo-ollama | `num_predict` set to what the window leaves after the prompt, since it has no unlimited value |

The gateway sends a cap only when the client asked for one with `max_tokens` or `max_completion_tokens`.

## Where each program uses it

| Program | Uses capacity for | Still static |
|---|---|---|
| llmq-models chat | window, chars per token, learning, no answer cap | |
| llmq-index ask and chat | window, chars per token, learning, source packing, `--max-wait`, no answer cap | |
| llmq-bench | measures chars per token; window from the server | |
| llmq run and ask | no answer cap | part size comes from the catalogue budget, because a job's id is a hash of its budget and must not change between runs |
| open-slop-gateway | no answer cap unless asked | input limit comes from the catalogue budget |
| llmq-claims | | its own `--max-tokens` |

## Checking what a model gets

The first line of `llmq-index ask` and `chat`, and the opening block of an llmq-models chat, print the capacity and where each figure came from. To see the server's own figures:

    curl -s http://192.168.8.173:11434/api/show -d '{"model":"qwen2.5-coder:7b"}' | jq '.model_info | with_entries(select(.key | endswith("context_length")))'
    curl -s http://192.168.8.173:8081/props | jq .default_generation_settings.n_ctx
    jq '.models.cpu["qwen2.5-coder:7b"].measured | {window, charsPerToken, decode: .decode.tokPerSec}' ~/.cache/open-slop/measured.json

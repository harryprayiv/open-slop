# measurements

Every number here was produced on the named hardware by the named command.
Vendor figures do not go in this file.

## oracle: Raspberry Pi 5, 16 GB, four Cortex-A76

### Inference

| model | pack | prompt | pp tok/s | tg tok/s | command | date |
|---|---|---|---|---|---|---|
| qwen2.5-coder:7b (ollama) | Q4_K_M | 33 tokens | not measured | 2.0 | `llmq ask`, one 19-token answer | 2026-09-19 |
| llama3.1:8b (ollama) | Q4_K_M | small | not measured | 1.7 | manual, docs/hailo.md | 2026-09-1x |
| qwen2.5-instruct:1.5b (hailo) | int4 HEF | small | not measured | 6.1 to 6.5 | manual, docs/hailo.md | 2026-09-1x |
| llama3.2:3b (hailo) | int4 HEF | small | not measured | 2.5 | manual, docs/hailo.md | 2026-09-1x |
| bonsai-2-27b | PQ2_0 | 512 / 4096 / 16384 | | | `llama-bench -m <gguf> -t 4 -p 512,4096,16384 -n 128 -fa 1 -ngl 0` | |
| bonsai-8b | Q2_0 | 512 / 4096 / 16384 | | | same | |

The Bonsai rows decide the catalogue's llamacpp budgets and whether the ollama
7-8B models stay. Fill them before changing either.

### hailo-ollama 5.1.1 window, qwen2.5-instruct:1.5b, 2026-09-19

Prompt of N repetitions of "apple " plus a nine-word instruction, non-streaming.

| N | result |
|---|---|
| 1200 | answer, HTTP 200 |
| 1600 | answer, HTTP 200 |
| 1900 | answer ("OK"), HTTP 200 |
| 2100 | garbage, HTTP 200 |
| 4000 | HTTP 500, plain-text oatpp body |

No prompt_eval_count in any reply. The catalogue's ctx is 2048 and its input
budget is 2867 bytes, about half the window, because the server gives no
signal between a good answer and garbage.

### Builds on oracle

| what | cores | wall | notes | date |
|---|---|---|---|---|
| linux-rpi 6.18.50 plus the rest of oracle's closure | 2 | about two hours | `./build deploy-native oracle`, first native build; the same kernel under binfmt on winsmuth had run for a day without finishing | 2026-09-20 |
| open-slop library plus llmq, with haddock | 2 | ten to twelve minutes, rough | cancelled and restarted once; dependencies all substituted from cache.nixos.org | 2026-09-20 |
| open-slop library plus llmq, dontHaddock | 2 | not yet timed | | |

### Activation costs on oracle

| event | wall | cause | fixed by |
|---|---|---|---|
| activation after a nixpkgs bump, before 2026-09-20's fixes | about twelve minutes | seed unit wiped the Hailo blobs on a store-path stamp change; pull unit refetched 9 GB | version stamp; /api/tags guard |
| activation after the fixes | four seconds | five "already present" | |
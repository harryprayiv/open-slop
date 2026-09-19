# measurements

Every number here was produced on the named hardware by the named command.
Vendor figures do not go in this file.

## oracle: Raspberry Pi 5, 16 GB, four Cortex-A76

| model | pack | prompt | pp tok/s | tg tok/s | command | date |
|---|---|---|---|---|---|---|
| llama3.1:8b (ollama) | Q4_K_M | small | not measured | 1.7 | manual, docs/hailo.md | 2026-09-1x |
| qwen2.5-instruct:1.5b (hailo) | int4 HEF | small | not measured | 6.1 to 6.5 | manual, docs/hailo.md | 2026-09-1x |
| llama3.2:3b (hailo) | int4 HEF | small | not measured | 2.5 | manual, docs/hailo.md | 2026-09-1x |
| bonsai-2-27b | PQ2_0 | 512 / 4096 / 16384 | | | `llama-bench -m <gguf> -t 4 -p 512,4096,16384 -n 128 -fa 1 -ngl 0` | |
| bonsai-8b | Q2_0 | 512 / 4096 / 16384 | | | same | |

The Bonsai rows decide the catalogue's llamacpp budgets and whether the ollama
7-8B models stay. Fill them before changing either.

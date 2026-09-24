# measurements

Every number here was produced on the named hardware by the named command.
Vendor figures do not go in this file.

## oracle: Raspberry Pi 5, 16 GB, four Cortex-A76

### Rate against context, qwen2.5-coder:7b Q4_K_M on ollama, 2026-09-20

Real llmq parts of the same input (modules/system/homebeacon, 31 KB, four
files), the instruction included in the prompt count. Both rates fall as
the prompt grows; prefill by 2.5x and decode by 3x across this range.

| prompt tokens | prefill tok/s | decode tok/s | output tokens | wall | part |
|---|---|---|---|---|---|
| 853 | 13.5 | 1.7 | 361 | 271 s | genkey.nix alone |
| 1259 | 10.0 | 1.6 | 343 | 335 s | responder.nix alone |
| 2562 | 7.5 | 1.3 | 368 | 616 s | keycheck.nix alone |
| 5064 | 6.4 | 0.9 | 630 | 1526 s | default.nix alone |
| 8406 | 5.5 | 0.6 | 485 | 2399 s | all four files packed (documented one) |
| 33 | not measured | 2.0 | 19 | | `llmq ask` |

Per-file total for the four files: 2748 s, every file documented. Packed:
2399 s, one file documented. Per-file is the default from this date.

### The prompt experiment that failed, 2026-09-20

Same input, same model, same packed part, with a rule added to the prompt:
"Every file in the part gets its own section, in the order the files
appear. Do not stop before the last file."

| run | output tokens | files documented |
|---|---|---|
| before the rule | 522 | 1 of 4 |
| after the rule | 485 | 1 of 4 |

Both stopped on their own at about a quarter of the 2048-token cap. The
instruction did not move the model; the chunker did. This is the evidence
behind one-file-per-part being structural rather than a prompt fix, and the
reason sampling is now deterministic (temperature 0.0, fixed seed): without
it, two runs differ and no prompt change can be judged.

### Inference, other models

| model | pack | prompt | pp tok/s | tg tok/s | command | date |
|---|---|---|---|---|---|---|
| llama3.1:8b (ollama) | Q4_K_M | small | not measured | 1.7 | manual, docs/hailo.md | 2026-09-1x |
| qwen2.5-instruct:1.5b (hailo) | int4 HEF | small | not measured | 6.1 to 6.5 | manual, docs/hailo.md | 2026-09-1x |
| llama3.2:3b (hailo) | int4 HEF | small | not measured | 2.5 | manual, docs/hailo.md | 2026-09-1x |
| bonsai-2-27b (llama-server) | PQ2_0 | 128 / 64 | 0.98 | 0.66 | `llama-bench -t 4 -p 128 -n 0 -r 1` and `-p 0 -n 64 -r 1`; five reps of pp512 did not finish in 30 min | 2026-09-20 |
| bonsai-8b (llama-server) | PQ2_0 | 128 / 64 | 4.62 | 3.60 | `llama-bench -t 4 -p 128 -n 64 -r 1 -fa 1 -ngl 0` | 2026-09-20 |
| bonsai-8b (llama-server) | PQ2_0 | 8381-token part | 2.85 | 0.47 | llmq job, timed from the journal; output was untemplated garbage (engine bug, since fixed) but the rates stand | 2026-09-20 |
| bonsai-8b (llama-server) | PQ2_0 | 22 tokens | | 3.6 | `llmq ask`, through /apply-template | 2026-09-20 |

The Bonsai 8B legacy Q2_0 file does not load in the current fork ("legacy
Prism Q2_0 layout"); PQ2_0 is the pack for every model.

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
| linux-rpi 6.18.50 plus the rest of oracle's closure | 2 | about two hours, from activation timestamps | `./build deploy-native oracle`, first native build; the same kernel under binfmt on winsmuth had run for a day without finishing | 2026-09-20 |
| open-slop library plus llmq, with haddock | 2 | ten to twelve minutes, rough | cancelled and restarted once; dependencies all substituted from cache.nixos.org | 2026-09-20 |
| PrismML llama.cpp fork, CPU | 2 | not recorded | built during a deploy-native | 2026-09-20 |
| open-slop library plus llmq, dontHaddock | 2 | not yet timed | | |

### Activation costs on oracle

| event | wall | cause | fixed by |
|---|---|---|---|
| activation after a nixpkgs bump, before 2026-09-20's fixes | about twelve minutes | seed unit wiped the Hailo blobs on a store-path stamp change; pull unit refetched 9 GB | version stamp; /api/tags guard |
| activation after the fixes | four seconds | five "already present" | |

## winsmuth: the Grace chain against a local ollama

Not fleet hardware. These numbers exist because oracle was unreachable for a
week, and they measure the machinery rather than the model. Model:
qwen2.5:0.5b, 397 MB, through open-slop-gateway on loopback.

### llmq-grace end to end, 2026-09-23

| part | bytes | prompt tokens | completion tokens | wall | result |
|---|---|---|---|---|---|
| genkey.nix alone | 1350 | 691 | 177 | 7 s | a well-formed Docs value, exit 0, no coverage warning |
| default.nix alone | 19860 | 4903 | 2048 (the cap) | 82 s | refused: the model repeated one sentence until the cap, so the JSON stopped mid-string |

The second row is why the gateway now answers a schema-constrained request
that ends at the token cap with 400 `length_before_schema_complete` instead
of a 200 the client cannot decode: under grammar-constrained decoding, an
answer that hits the cap is inside a string or an object when the budget
runs out, and cannot be valid JSON.

The content at 0.5B is worthless and the structure is perfect, which is the
result the design predicts: `interface` came back as the prompt's own
category words, `reasoning` contained a confident falsehood about where a
key is written, and every layer reported success.

### Package closures, 2026-09-23

| output | binaries | closure | why |
|---|---|---|---|
| `pkgs.open-slop.llmq` | llmq, open-slop-gateway | 85.8 MiB | justStaticExecutables, no Grace |
| `pkgs.open-slop.llmq-grace` | all three | 4.6 GiB | Grace's closure keeps a reference to ghc-9.6.7; `nix why-depends --precise` found it in the package's own shared object before the split, and in a binary after |

The `grace` cabal flag is what keeps the first number small. See HANDOFF
section 4.

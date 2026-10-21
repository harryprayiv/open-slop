# Measuring Grace

`llmq-grace --measure stages/measure` runs every program here against a gateway, several times each, and reports what each one cost and whether it worked. The gateway must be started with `--record FILE` and llmq-grace given the same file, or calls and tokens are not counted. Nothing else should use that gateway during a run.

Each program reads the key and the model from `$OPEN_SLOP_KEY` and `$OPEN_SLOP_MODEL`, which `--measure` sets, so the same directory runs against any model.

| Program | Question it answers |
|---|---|
| 01-record | The cost of the smallest typed call: the floor under every typed stage. |
| 02-text | The same question with no schema. Against 01, what the grammar costs. |
| 03-list | The wrapped path for a type that is not a record. |
| 04-choice | A closed union: the shape of a typed tool call and of an NPU triage judgement. |
| 05-answer | llmq-index's answer as a Grace type, with fixed sources and one part the sources cannot answer. Grace cannot express "at least one claim or a gap" or "a source number that was sent", so this shows whether the weaker type changes what the model does. |
| 06-docs | A documentation-sized typed value. How many output tokens it needs, and whether it stops at the cap with the JSON unfinished. HANDOFF open question 5. |
| 07-codegen-text | import prompt, the smallest case. The cold run is the grammar preamble; the warm runs show what the prompt cache is worth; repairs show how often generated Grace type-checks. HANDOFF open question 7. |
| 08-codegen-function | import prompt for a function between records, applied to a value. |

The first run of each program is reported as the cold run, apart from the median of the rest. On llama-server, which keeps its prompt cache between requests, the difference is what the cache is worth to that program. On ollama it mostly is not.

Run it once per backend worth comparing. On oracle that means `cpu` and `llamacpp` with the same 7B, and `hailo` only for 02-text, because hailo-ollama takes no schema and the gateway refuses the others by name.

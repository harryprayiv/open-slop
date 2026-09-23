Three separate things. Taking them in order, with what the measurements and the sources actually say.

## The NPU for quick judgements

What it can do, from this week: 6.1 tok/s on a 1.5B, a 2,048-token window, about 2.8 KB of input per request, and it runs on separate silicon from the CPU, so an NPU call and a CPU call genuinely overlap. A twenty-token answer comes back in about four seconds.

What it cannot do, also measured: no schema. `hailo-ollama` has no grammar-constrained decoding, and the gateway refuses `response_format` for it by name rather than sending something that gets ignored. It also reports no prompt token count, so an overflowing prompt comes back as fluent garbage with HTTP 200. That rules it out of every Grace stage whose result type is not `Text`, because Grace's guarantee is the schema.

So the only safe shape for an NPU judgement is: a tiny prompt, a closed set of answers stated in the prompt, one or two words out, and a whitelist check in Haskell where anything unrecognised means "unknown". Combined with one more rule: **the NPU may only add work, never remove it.** An "unknown" or an off-list answer falls through to the expensive path. A 1.5B that silently drops a signature from annotation is the same failure as the 7B documenting one file of four, and that one took a day to notice.

Under those rules, the judgements worth asking it in the chase pipeline:

- **Triage.** For each signature: "does this function's behaviour need a note beyond its type: yes / no / unsure?" A `no` skips the 7B's four minutes; `unsure` and anything unparseable do not. On a 40-signature module that is about three minutes of NPU time deciding maybe 30 minutes of CPU time, and it runs while the CPU is still working on the previous module.
- **A second opinion on a claim.** Given one stage-1 sentence and the signature it attaches to: "is this supported by the signature and name: yes / no / unsure?" A `no` marks the claim for your eye rather than deleting it. This is cheap and it does not pretend to be a check.
- **Routing.** Which model a module should go to, by size and language.

What not to ask it, because chase already knows: purity, arity, whether a function is partial by construction, what it calls. Those come out of the parser, deterministically, and asking a 1.5B to guess at facts the parser has is how wrong data gets into the annotations.

In Grace terms, an NPU stage is a `prompt{...} : Text`, since that is the path that sends no schema, with the enum parsed on the Haskell side. Everything typed stays on `cpu` or `llamacpp`.

## Jev, and what it means for your box

Your memory of "JEV mode" is close to a real thing and slightly off in an important way. Jev is TypeSafe AI's model, released in early access on 15 September 2026, and the category name is "System One model". You give it a block of state and a set of typed questions; it evaluates all of them in parallel and returns structured answers with calibrated confidence scores, with no string generation and nothing to parse. It does not generate a token stream: it returns typed answers with probability distributions in a single parallel pass, in 70ms to 500ms.

So it is not "the model speaks JSON instead of markdown". It is "the model does not generate at all"; the answer is read out of one forward pass over the options you supplied. That is why the hallucination claim is stronger than JSON mode's: one open reproduction puts it as nothing is generated, so the structured-output error rate is 0 by construction. The model can still be wrong about the answer. What disappears is malformed output, invented option values, and preamble.

The limits are the same ones that make it fit your pipeline: this only works when the space of valid answers is bounded and known up front; Jev is useless for open-ended generation, and it doesn't write the schema for you, and it gives you a number, not a rationale. For chase that is exactly the triage and second-opinion jobs above, and not the invariant text.

Open reproductions exist and two shapes matter to you:

- An encoder classifier: `com-kotobalabs/open-jev-deberta-v3-large`, an open Jev-shaped typed-decision model taking one program state and any number of typed questions (choice over up to 255 options, score over 2 to 10 ordered levels, yes-no) and returning a calibrated probability distribution per question from one forward pass.
- A causal model turned into a single NLI cross-encoder, the `openjev` recipe (MIT), reused zero-shot for reranking, grading and guarding.

Here is the part that changes your hardware thinking. A DeBERTa-large classifier is a few hundred million parameters and one forward pass, no decode loop. On oracle's four A76 cores that is a fraction of a second per decision at int8, without the NPU at all, and without the 2,048-token window, and with no output to parse. For triage over a repository that is faster and more honest than a 1.5B generating the word "yes".

And if you do want it on the Hailo: an ONNX encoder classifier is precisely what Hailo's Dataflow Compiler is built to compile into a HEF, unlike LLMs where you are stuck with whatever is in their GenAI zoo. That is a real path to using the NPU for something you chose, rather than something Hailo shipped. It is also a week of work with a proprietary x86-only toolchain, op-support surprises, and a fixed sequence length baked into the HEF. I would run the classifier on the CPU first, measure it, and only then decide whether the NPU is worth the toolchain.

One more cheap experiment in the same family, no new model: llama-server returns per-token logprobs. A one-token answer with the probabilities of "yes" and "no" read off the logits is the poor man's System One, on a model you already have. The gateway refuses `logprobs` today; allowing it for the llamacpp backend is a small change if that experiment interests you.

## Fine-tuning a model on Grace

Worth separating two goals, because only one of them needs training.

**Filling a Grace-derived schema needs no Grace knowledge at all.** The model sees a JSON schema and some text. That is the whole chase pipeline. A fine-tune buys nothing there.

**Writing Grace (`import prompt`) needs the grammar in front of the model**, which is the 29 KB of `prompts/`. Before training anything, two cheaper moves:

1. **Cache the preamble.** If the grammar sits at the front of every request, unchanged, a server that keeps its KV cache prefills it once per session. That is the same bet as stage 1 of the chase design, and it would take the preamble from 25 minutes per call to 25 minutes once. This partly retracts what I said last time about `import prompt` being off the table: it is off the table per call, not per session, if the cache holds. Unmeasured, and worth measuring before anything else here.
2. **Shrink it.** Most of those 29 KB is prose aimed at a frontier model. An ABNF-only variant with six worked examples might be 2 to 3K tokens.

If you still want the fine-tune, the setup is unusually good, because Grace itself is the verifier: generate candidate programs, run `grace interpret` (or just the type checker) over them, keep what type-checks, and you have a rejection-sampled corpus with no human labelling. That is the kind of data pipeline that makes a small-model fine-tune actually work. Then a LoRA on a 7 to 8B on a rented GPU for a few hours, merge, convert to GGUF, serve from `llamacpp` on oracle.

The honest ceiling: it improves the odds that the generated Grace type-checks. It does not make oracle faster. A Grace program written at 0.5 to 0.7 tok/s at long context is still minutes per attempt, and a wrong intermediate program wastes every level under it. Fine-tuning changes quality, not the rate curve.

## One concrete thing to fix in the schema path

Reading Grace's `toJSONSchema`: record properties are emitted through `Map.fromList`, so the schema's `properties` object is **alphabetical**, while `required` keeps your declaration order. With grammar-constrained decoding the model writes the fields in the order the schema gives them, which means the field order in your Grace record type does not control what the model writes first; the alphabet does.

That matters because of the one real criticism of JSON mode: constraining output can cost reasoning quality, since the model has nowhere to think before committing to a value. The fix inside a constrained schema is a scratch field the caller throws away, and for it to help it has to be generated *first*. In Grace that means naming it so it sorts first: `analysis` before `body` and `consumes`, not `notes`. Add it to the Grace result type and to the Haskell record, and ignore it. Whether it improves the annotations on a 7B is exactly the kind of thing the golden set is for, and it is a two-line change to test.
# The inference backends, and the models they serve: what each one is, what it
# costs, and what it is for.
#
# PLAIN DATA, NOT A MODULE. Read by:
#
#   nix/modules/server.nix           the cpu backend's port and context length
#   nix/modules/hailo.nix            the hailo backend's port
#   nix/modules/llama-server.nix     the llamacpp backend's port AND its
#                                    --ctx-size, which is why the context for
#                                    that server is changed here rather than
#                                    on a host
#   nix/modules/gateway.nix          the loopback catalogue it serves
#   nix/modules/catalogue-check.nix  warns when a row declares a model this
#                                    file does not describe
#   nix/modules/client.nix           writes it as JSON for llmq, with the
#                                    consumer's endpoints added
#
# pinned.nix reads the cpu port through services.ollama.port rather than from
# here, because that option is what the server was actually given.
#
# A consumer extends it through services.open-slop.catalogue.extra, merged with
# lib.recursiveUpdate, rather than by editing this file.
#
# ============================================================================
# WHAT THE NUMBERS MEAN
# ============================================================================
#
#   ctx             tokens a request asks the server to hold, prompt AND
#                   output together. Output that pushes past it makes ollama
#                   discard the oldest tokens, which are the input.
#   predict         output tokens reserved inside ctx. Sent as num_predict
#                   where the backend accepts options. Where it does not, the
#                   reservation still shrinks the input budget.
#   promptOverhead  tokens reserved for the chat template, the instruction,
#                   and llmq's part header.
#   charsPerToken   a PESSIMISTIC bytes-per-token figure for source code.
#                   llmq cuts input at
#                     floor((ctx - predict - promptOverhead) * charsPerToken)
#                   bytes, and prints the observed ratio after every part, so a
#                   wrong figure is visible after the first one.
#   tokPerSec       generation rate MEASURED on oracle, or null. Never a vendor
#                   figure. docs/measurements.md holds the measurements and the
#                   prompt sizes they were taken at; a rate at a short prompt
#                   overstates a long job on this CPU by several times.
#   docFit          "best", "usable", "poor", "unsuitable" or "unknown", for
#                   turning long source text into reference documentation
#                   specifically.
#
# A model entry may override ctx and predict. Everything else is per backend.
#
# ============================================================================
# CHANGING A NUMBER CHANGES EVERY NEW llmq JOB, AND NO EXISTING ONE
# ============================================================================
#
# A job's id hashes its chunk budget, ctx, predict and temperature, and a
# resumed job reads them from its own meta.json. So a job started under the old
# numbers resumes under the old numbers, and the same input under new numbers
# starts a new job. That is deliberate: the chunks on disk were cut for the old
# budget, and sending them under a smaller ctx is the silent truncation this
# whole file exists to prevent.
{
  backends = {
    cpu = {
      engine = "ollama";
      port = 11434;

      streams = true;
      acceptsOptions = true;

      # 16K is chosen for time rather than memory. 16 GB holds an 8B at Q4
      # plus 16K of f16 KV cache with room left for the machine. Prefill on
      # four A76 cores is slow and grows with the prompt, so a larger window
      # mainly lengthens the wait before each part's first output token.
      ctx = 16384;
      predict = 2048;
      promptOverhead = 512;
      charsPerToken = 2.8;
      temperature = 0.0;

      blurb = ''
        ollama on the host's four Cortex-A76 cores. Any GGUF, num_ctx and
        num_predict honoured per request, tokens streamed as they are made.

        OVERFLOW IS SILENT. A prompt longer than num_ctx loses its FRONT, which
        is where the instruction sits, and the server still answers 200. llmq
        fails any part whose prompt_eval_count reaches ctx.

        Reuses the KV cache of a shared prefix, measured 2026-09-26: a
        4,700-token prompt took about 219 s cold, 5.6 s with a different
        tail, and 0.95 s repeated, with an earlier prefix still hitting on
        return. It has no cache_prompt field to control that and ignores the
        one llama-server takes.

        Its prompt_eval_duration field is not usable: the same measurement
        reported 711 s of prefill inside a 258 s wall clock. Time requests
        from outside.
      '';
    };

    hailo = {
      engine = "hailo-ollama";

      # DESCRIBED HERE, NOT SET HERE. hailo-ollama 5.1.1 binds the address in
      # its own shipped JSON, and 5.3.0 reads OLLAMA_HOST with the same
      # default. This value is what the firewall rule, the model-pull unit and
      # llmq use to find that server. Editing it moves all three and leaves the
      # server where it was, so nix/modules/catalogue-check.nix pins it.
      port = 8000;

      # Both verified against hailo-ollama 5.1.1 on 2026-09-19. Streaming
      # lines have ollama's shape (response, done); the final line carries
      # done_reason, total_duration and eval_count, and NO prompt_eval_count
      # and no eval_duration. options.num_predict is honoured. Nothing else
      # in options has been tried; llmq sends only num_predict.
      streams = true;
      acceptsOptions = true;

      # MEASURED 2026-09-19 on qwen2.5-instruct:1.5b, prompts of N "apple "
      # tokens plus a short instruction: an answer at 1900, garbage with
      # HTTP 200 at 2100, HTTP 500 with a text body at 4000. So the window
      # is 2048, overflow is SILENT up to some larger size, and the server
      # reports no prompt token count that would let llmq notice. The byte
      # budget below is the only protection on this backend, which is why
      # it stays at about half the window.
      ctx = 2048;
      predict = 768;
      promptOverhead = 256;
      charsPerToken = 2.8;
      temperature = null;

      blurb = ''
        hailo-ollama on the Hailo-10H. int4 HEFs in the NPU's own 8 GB,
        compiled by Hailo with a fixed context that cannot be raised per
        request. Upstream weight licences vary per model; the HEFs themselves
        ship in Hailo's proprietary zoo.

        NO SCHEMA, NO OPENAI ROUTE. Measured 2026-09-26: a request carrying a
        format field is answered with HTTP 500 and "No suitable mapper found
        to deserialize the request body", and GET /v1/models is a 404 from
        oatpp. The gateway refuses a response_format for this backend rather
        than sending a field it cannot honour, and no typed stage can run
        here.

        Reports no prompt token count, so an overflowing prompt cannot be
        detected: measured, a prompt past the 2048-token window comes back as
        garbage with HTTP 200. The byte budget is the only guard, and it is
        set at half the window for that reason.

        Under 3 KB of input per request. Suitable for a closed choice with a
        whitelist check in Haskell, under the rule that it may only add work,
        never remove it.
      '';
    };

    llamacpp = {
      engine = "llama-server";

      # One llama-server instance per row, on this port. Its context is a
      # start flag, so ctx here is what nix/modules/llama-server.nix passes
      # to --ctx-size, and no request can ask for more.
      port = 8081;

      streams = true;
      acceptsOptions = true;

      # 16384 since 2026-09-26, down from 32768. The KV cache is the cost,
      # the bundles this serves are about 5K tokens, and a window the Pi
      # cannot prefill in reasonable time buys nothing. The claims pipeline
      # sends one bundle in front of many per-subject questions, so what
      # matters here is warm prefill rather than window size.
      ctx = 16384;
      predict = 2048;
      promptOverhead = 512;
      charsPerToken = 2.8;
      temperature = 0.0;

      blurb = ''
        llama-server from PrismML's llama.cpp fork. Reports its own
        truncation, streams, takes n_predict, temperature and seed per
        request, and constrains decoding to a JSON Schema through
        response_format. Context is fixed at start.

        THE BACKEND FOR TYPED WORK, since 2026-09-26. Measured that day on
        oracle against the same 4,700-token prompt: decode 0.975 tok/s
        against ollama's 1.03, and warm prefill 1.0 s against ollama's 5.6,
        because cache_prompt works and is sent by the gateway and by
        llmq-claims. A pipeline that asks many questions over one bundle
        pays that difference on every call.

        Speculative decoding does not work in this fork as built, measured
        the same day: --spec-draft-model loads the draft, and the server
        then reports no draft statistics and no speedup, with or without a
        grammar. Worth retrying against upstream llama.cpp.
      '';
    };
  };

  models = {
    llamacpp = {
      "qwen2.5-coder-7b" = {
        summary = "code-tuned 7B, the typed-pipeline model, 0.98 tok/s";
        docFit = "best";
        tokPerSec = 0.98;
        licence = "Apache-2.0";
        blurb = ''
          Qwen2.5-Coder 7B Instruct, Q4_K_M, about 4.7 GB, served by
          llama-server as a store-pinned GGUF rather than through ollama's
          private blob store.

          Measured 2026-09-26 under a JSON Schema on a 4,700-token prompt:
          0.975 tok/s decode, 1.0 s warm prefill, 235 output tokens in 240
          seconds. Constrained decoding costs nothing against free text.

          With minItems on an array in the schema, it returns one record per
          subject and cannot stop early. Without it, on the same input, it
          returned one record where two were asked for.
        '';
      };

      "bonsai-2-27b" = {
        summary = "Ternary Bonsai 2 27B, PQ2_0, 0.66 tok/s";
        docFit = "unsuitable";
        tokPerSec = 0.66;
        licence = "Apache-2.0";
        blurb = ''
          Bonsai 2 27B, Qwen3.5-based, ternary weights in the PQ2_0 pack,
          7.2 GB, served by llama-server with reasoning off.

          Measured 2026-09-20 (llama-bench, four threads): prefill 0.98
          tok/s, decode 0.66 tok/s, both on short prompts. A 16K prompt is
          over four hours before the first output token. Not a working model
          on a Pi 5; kept in the catalogue so the number is not remeasured.
        '';
      };

      "bonsai-8b" = {
        summary = "Ternary Bonsai 8B, PQ2_0, 3.6 tok/s short, 0.47 at 8K";
        docFit = "unsuitable";
        tokPerSec = 3.6;
        licence = "Apache-2.0";
        blurb = ''
          First-generation Bonsai 8B, Qwen3-8B dense, PQ2_0 pack, 2.2 GB.

          Measured 2026-09-20: prefill 4.62 tok/s and decode 3.60 tok/s at
          128 tokens (llama-bench); prefill 2.85 and decode 0.47 on a real
          8,381-token part. The fastest CPU model on the fleet for a short
          question and slower than qwen2.5-coder at documentation length.
          tokPerSec above is the short-prompt figure; llmq's dry-run
          estimate overstates a long job by a factor of seven for this
          model.
        '';
      };
    };

    cpu = {
      "qwen2.5-coder:7b" = {
        summary = "code-tuned 7B on ollama, 0.7 tok/s at 8K";
        docFit = "best";
        # 2026-09-20, a real 8,381-token part: prefill 5.7, decode 0.7. On a
        # 19-token answer the day before it decoded at 2.0. Those prefill
        # figures came from ollama's own duration fields, which the
        # 2026-09-26 measurement showed to be unreliable; the decode rates
        # were taken from wall clock and stand.
        tokPerSec = 0.7;
        licence = "Apache-2.0";
        blurb = ''
          Qwen2.5-Coder 7B Instruct, Q4_K_M, about 4.7 GB resident.
          Trained context 32K. llmq asks for 16K, about 0.9 GiB of KV cache.

          The same weights the llamacpp backend serves as a pinned GGUF.
          Typed work goes there instead, because only llama-server has
          cache_prompt and a grammar together.

          Reads code more carefully than anything else on the fleet. Its
          training is dominated by mainstream languages, so expect confident
          mistakes about type-level Haskell, PureScript rows and effects, and
          Nix module merge semantics. Check every claim it makes about a
          type.
        '';
      };

      "llama3.1:8b" = {
        summary = "general 8B, most readable prose, 1.7 tok/s";
        docFit = "usable";
        tokPerSec = 1.7;
        licence = "Llama 3.1 Community License, not OSI-approved";
        blurb = ''
          Llama 3.1 8B Instruct, Q4_K_M, about 4.9 GB resident.
          Trained context 128K. llmq asks for 16K, about 2 GiB of KV cache.

          Writes the most readable prose here, and reads code less carefully
          than qwen2.5-coder. A 128K request is legal and fits in RAM; at this
          CPU's prefill rate it is an overnight job for a single part.

          The second family on the fleet, which makes it the cross-check
          model: a claim two unrelated families derive from the same evidence
          is as good as this class of system gets.
        '';
      };

      sully = {
        summary = "abliterated Qwen2.5 7B at 3-bit, store-pinned";
        docFit = "poor";
        ctx = 8192;
        tokPerSec = null;
        licence = "Apache-2.0, from Qwen2.5-7B-Instruct";
        blurb = ''
          Qwen2.5-7B-Instruct with its refusal direction removed, Q3_K_M,
          about 3.8 GB. Pinned by hash through
          services.open-slop.server.pinnedModels, so the bytes cannot drift.

          General instruct, not code-tuned. Abliteration and a 3-bit quant both
          cost accuracy, and reference documentation is where that shows first.
          llmq caps it at 8K context.
        '';
      };
    };

    hailo = {
      "llama3.2:3b" = {
        summary = "largest NPU model, 2.5 tok/s";
        docFit = "poor";
        tokPerSec = 2.5;
        licence = "Llama 3.2 Community License, not OSI-approved";
        blurb = ''
          Llama 3.2 3B Instruct as an int4 HEF. The biggest model the 5.1.1 zoo
          offers, and the 5.3.0 zoo drops it.

          Faster per token than either 7-8B on the CPU, with under half the
          parameters and an eighth of the window. Useful for a one-paragraph
          summary of one small file, or a closed choice. Not for reference
          documentation, and not for anything typed: this backend cannot
          constrain output.
        '';
      };

      "qwen2.5-instruct:1.5b" = {
        summary = "fastest measured, 6.1-6.5 tok/s, 1.5B";
        docFit = "unsuitable";
        tokPerSec = 6.1;
        licence = "Apache-2.0";
        blurb = ''
          Qwen2.5 1.5B Instruct as an int4 HEF. The fastest thing on the fleet
          and the one docs/hailo.md benchmarks against.

          Fine for classification, extraction, a commit-message draft. At 1.5B
          and a 2K window it restates its input and fills gaps with invented
          detail.
        '';
      };

      "qwen2.5-coder:1.5b" = {
        summary = "code-tuned 1.5B, rate not measured";
        docFit = "poor";
        tokPerSec = null;
        licence = "Apache-2.0";
        blurb = ''
          Qwen2.5-Coder 1.5B Instruct as an int4 HEF. Same size as
          qwen2.5-instruct:1.5b, so expect a similar rate.

          The only NPU model trained for code. It can name what a short function
          does. Its explanations of why code is written a certain way are
          unreliable at this size.
        '';
      };

      "qwen2:1.5b" = {
        summary = "previous-generation 1.5B";
        docFit = "unsuitable";
        tokPerSec = null;
        licence = "Apache-2.0";
        blurb = ''
          Qwen2 1.5B Instruct as an int4 HEF. Superseded by
          qwen2.5-instruct:1.5b at the same size, and kept because the zoo
          ships it.
        '';
      };

      "deepseek_r1_distill_qwen:1.5b" = {
        summary = "reasoning distill, writes a think block first";
        docFit = "unsuitable";
        tokPerSec = null;
        licence = "MIT, over an Apache-2.0 Qwen base";
        blurb = ''
          DeepSeek-R1 distilled into Qwen 1.5B, as an int4 HEF. Emits a
          reasoning block before its answer, and that block comes out of the
          same small window and the same slow token budget, which on a
          2048-token window means the budget is gone before the answer
          starts. llmq keeps the block in the output rather than guessing
          where it ends.

          Renamed deepseek_r1:1.5b in the 5.3.0 zoo.
        '';
      };
    };
  };
}
# The inference backends, and the models they serve: what each one is, what it
# costs, and what it is for.
#
# PLAIN DATA, NOT A MODULE. Read by:
#
#   nix/modules/server.nix           the cpu backend's port and context length
#   nix/modules/hailo.nix            the hailo backend's port
#   nix/modules/llama-server.nix     the llamacpp backend's port and context
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
#                   figure. docs/hailo.md section 14 holds the measurements.
#   docFit          "best", "usable", "poor" or "unsuitable", for turning long
#                   source text into reference documentation specifically.
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
      temperature = 0.2;

      blurb = ''
        ollama on the host's four Cortex-A76 cores. Any GGUF, num_ctx and
        num_predict honoured per request, tokens streamed as they are made.

        OVERFLOW IS SILENT. A prompt longer than num_ctx loses its FRONT, which
        is where the instruction sits, and the server still answers 200. llmq
        fails any part whose prompt_eval_count reaches ctx.

        Prefill is slow here and grows with the prompt. A full-size part can sit
        for many minutes before its first output token. llmq does not treat
        that silence as a failure; curl's TCP keepalive detects a server that
        has gone away.
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

      # [?] Neither is verified against hailo-ollama 5.1.1. Unrecognised
      # request fields have been reported to produce a 500 from it, so llmq
      # sends the one shape known to work here: model, prompt, stream false.
      # Before flipping either, send oracle a request carrying the field and
      # check that it answers with text rather than a 500.
      streams = false;
      acceptsOptions = false;

      # [?] The context is compiled into each HEF and cannot be requested.
      # 2048 is the figure a third-party server on the same 5.1.1 runtime
      # reports for a Qwen2-1.5B HEF. Not measured here. predict is a
      # reservation only: nothing is sent, and the server's own output cap is
      # unknown.
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

        No streaming and no request options are sent, because neither is
        verified against this server. llmq shows elapsed time while it waits.

        The assumed 2048-token window leaves under 3 KB of input per request.
        Long text becomes hundreds of small parts, each written with no view of
        the others.
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

      # [?] Nothing below is measured. Bonsai's hybrid attention keeps 32K of
      # cache near 1.5 GB, so memory allows it; prefill time on a Pi 5 CPU is
      # what will set the real ceiling. predict is generous because the
      # model writes JSON when asked for structure, and JSON costs tokens.
      ctx = 32768;
      predict = 4096;
      promptOverhead = 512;
      charsPerToken = 2.8;
      temperature = 0.0;

      blurb = ''
        llama-server from PrismML's llama.cpp fork, serving one ternary
        Bonsai GGUF from the store. Reports its own truncation, streams, and
        takes n_predict and temperature per request. Context is fixed at
        start.

        Runs on demand, not at boot: the 27B holds 7 GB for as long as it
        runs. Expect decode near 1 tok/s on a Pi 5 and prefill measured in
        minutes per 16K; see docs/measurements.md once it exists.
      '';
    };
  };

  models = {
    llamacpp = {
      "bonsai-2-27b" = {
        summary = "Ternary Bonsai 2 27B, PQ2_0, unmeasured";
        docFit = "unknown";
        tokPerSec = null;
        licence = "Apache-2.0";
        blurb = ''
          Bonsai 2 27B, ternary weights in the PQ2_0 pack, about 7.2 GB,
          served by llama-server with reasoning off.

          The strongest model the fleet can hold. Whether it is usable for
          documentation on this hardware is a question of prefill time, and
          that has not been measured. Until it is, docs fit is unknown.
        '';
      };

      "bonsai-8b" = {
        summary = "Ternary Bonsai 8B, Q2_0, unmeasured";
        docFit = "unknown";
        tokPerSec = null;
        licence = "Apache-2.0";
        blurb = ''
          First-generation Bonsai 8B, about 2.2 GB. Roughly three times the
          decode rate of the 27B on the same bus. The likely working model if
          the 27B proves too slow. Unmeasured.
        '';
      };
    };

    cpu = {
      "qwen2.5-coder:7b" = {
        summary = "code-tuned 7B, the best documentation model here";
        docFit = "best";
        tokPerSec = null;
        licence = "Apache-2.0";
        blurb = ''
          Qwen2.5-Coder 7B Instruct, Q4_K_M, about 4.7 GB resident.
          Trained context 32K. llmq asks for 16K, about 0.9 GiB of KV cache.

          Reads code more carefully than anything else on the fleet. Its
          training is dominated by mainstream languages, so expect confident
          mistakes about type-level Haskell, PureScript rows and effects, and
          Nix module merge semantics. Check every claim it makes about a type.

          Generation rate not measured here. Expect roughly the llama3.1:8b
          figure; the two are close in size.
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

          A full 2048-token output at the measured rate is about 20 minutes,
          before prefill.
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
          about 3.8 GB. Pinned by hash through services.open-slop.server.pinnedModels, so the
          bytes cannot drift.

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
          summary of one small file. Not for reference documentation.
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
          same small window and the same slow token budget. llmq keeps the
          block in the output rather than guessing where it ends.

          Renamed deepseek_r1:1.5b in the 5.3.0 zoo.
        '';
      };
    };
  };
}

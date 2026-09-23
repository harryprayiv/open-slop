# Grace against the gateway

Each program here is one path of Grace's `prompt` keyword, run against an
open-slop gateway instead of api.openai.com through the Grace fork's
OPENAI_BASE_URL.

  record.ffg  record type: the strict schema goes to the backend as-is
  list.ffg    non-record type: Grace wraps it as { response: T }
  text.ffg    Text: no schema

Three environment variables:

  OPENAI_BASE_URL   the gateway, e.g. http://127.0.0.1:18443
  OPEN_SLOP_KEY     the bearer key itself, llm_...
  OPEN_SLOP_MODEL   the model id the gateway serves it under, e.g.
                    winsmuth/cpu/qwen2.5:0.5b

The last two are read by `env:VAR : Key` and `env:VAR : Text`, which take the
variable's raw text. An import with no annotation is parsed as Grace code
instead, which is why the annotations are not optional here.

A program that names no model is sent as gpt-5-mini, Grace's default, and
the gateway answers 404 naming it. Every program meant for this fleet
names its model.
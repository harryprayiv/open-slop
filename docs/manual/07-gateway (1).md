# open-slop-gateway

The gateway is one authenticated, OpenAI-compatible endpoint in front of a row's inference servers. Any program that speaks the OpenAI chat API can use the models on the row through it, with a key per client. It refuses, before sending anything, a request that could not fit the model's window or that asks for something the backend cannot do. It does not stream.

## NixOS options

| Option | Type | Default | Meaning |
|---|---|---|---|
| `gateway.enable` | bool | false | |
| `gateway.package` | package | `pkgs.open-slop.llmq` | |
| `gateway.host` | string | `127.0.0.1` | Anything other than loopback needs TLS or `plaintextLan`. |
| `gateway.port` | port | 8443 | Must not equal a backend port. |
| `gateway.keysFile` | string | required | Path outside the store, for example a sops secret. |
| `gateway.tlsCertFile` | string or null | null | |
| `gateway.tlsKeyFile` | string or null | null | Both or neither. |
| `gateway.plaintextLan` | bool | false | Allow a LAN bind without TLS, accepting that keys cross the network in clear. |

The unit `open-slop-gateway.service` runs as a dynamic user with a strict sandbox. The keys file and the TLS files are passed as systemd credentials, readable by that process only. Its catalogue lists the row's own enabled backends on loopback, so a backend is behind the gateway exactly when it runs. At least one backend must be enabled.

## The keys file

One client per line, `name key`. Blank lines and lines starting with `#` are ignored. Keys must be at least 24 characters, and names and keys must be unique.

    # who        key
    winsmuth     llm_winsmuth_3k8f0a9d7c6b5e4f1a2b3c4d
    blade        llm_blade_9f8e7d6c5b4a3f2e1d0c9b8a

Keys are kept only as SHA-256 digests in memory.

## Routes

| Route | Key | Result |
|---|---|---|
| `GET /healthz` | no | `ok` |
| `GET /v1/models` | yes | every served model as `row/backend/name` |
| `POST /v1/chat/completions` | yes | a chat completion |

A model is named by its id or by any unique suffix of it. The model list is cached for 30 seconds.

## What a request may contain

Accepted: `model`, `messages` (system, developer, user and assistant roles, text content, and a `name`), `response_format` (`text`, `json_object`, `json_schema`), `max_completion_tokens` or `max_tokens`, `temperature`, `seed`, `reasoning_effort`. Ignored: `user`, `metadata`, `store`, `service_tier`.

A message's `name` is written at the top of its content, followed by a colon, because none of the backends' chat templates show the field to the model. Grace labels its messages "Instructions", "Type", "Attempt" and "Error", and with the label in the text the model can tell the required type from its last attempt and the compiler's complaint about it.

`reasoning_effort` is `minimal` (or `none`), `low`, `medium` or `high`, and is sent only when the client sets it; Grace sets it when a stage sets `effort`.

| Backend | What it is sent |
|---|---|
| ollama | `think`: false for minimal; for a gpt-oss model, the level; otherwise true. ollama refuses true for a model without a thinking mode, and that refusal is returned to the client. |
| llama-server | `chat_template_kwargs` with `enable_thinking` (false for minimal) and `reasoning_effort` (low for minimal, since gpt-oss has no minimal). Templates ignore arguments they do not use. |
| hailo-ollama | Nothing. |

Both servers return the thinking apart from the answer, so the client gets the answer alone.

A `json_schema` response format is passed through unchanged, including the `anyOf` unions Grace derives from union types. Checked 2026-10-16 with llama.cpp's converter, which ollama and llama-server both use: the schema for the agent's decision type becomes a grammar that accepts every decision and rejects an unknown action. See [llmq-agent](13-llmq-agent.md).

Refused with 400: `stream: true`, `n` other than 1, tools and function calling, logprobs, audio, modalities, prediction, web search options, image or other non-text content, and an empty message list. A body over 8 MiB gets 413.

## What is checked before the backend is called

- A client's `max_tokens` must be at least 1 and less than the window. Without one, the answer is not capped (ollama gets `num_predict: -2`, llama-server no `max_tokens`), and the catalogue's `predict` is only the room kept free when checking the input size.
- The total size of the messages must fit `floor((ctx - predict) * charsPerToken)` bytes, or the request is refused with `context_length_exceeded`.
- A JSON response format sent to hailo-ollama is refused with `response_format_unsupported`. So is a conversation with assistant turns.

## What is checked after

- A constrained answer that stopped at the token cap is refused with `length_before_schema_complete`, because the JSON is unfinished.
- A prompt that filled the window is refused with `context_length_exceeded`.
- Softer problems (the answer hit the cap, the prompt ate into the output reserve) are returned in the `X-Open-Slop-Warnings` header.
- For hailo-ollama, which reports no prompt count, the count is estimated and the header `X-Open-Slop-Prompt-Tokens: estimated` is set.

Errors use the OpenAI shape, `{"error": {"message", "type", "code", "param"}}`.

## Examples

    curl -s -H "Authorization: Bearer $KEY" https://oracle:8443/v1/models | jq .

    curl -s -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" -d '{"model":"qwen2.5-coder:7b","messages":[{"role":"user","content":"Name three NixOS module arguments."}],"max_tokens":128}' https://oracle:8443/v1/chat/completions | jq -r '.choices[0].message.content'

From the command line, without Nix:

    open-slop-gateway --catalogue cat.json --keys keys.txt
    open-slop-gateway --catalogue cat.json --keys keys.txt --host 0.0.0.0 --tls-cert cert.pem --tls-key key.pem

# Troubleshooting and known quirks

## Commands that show what is happening

On the serving row:

    systemctl status ollama llama-server hailo-ollama open-slop-gateway --no-pager
    journalctl -u ollama -n 50 --no-pager
    curl -s http://127.0.0.1:11434/api/ps | jq .
    curl -s http://127.0.0.1:8081/health
    curl -s http://127.0.0.1:9100/metrics | grep -E '^rpi_|node_thermal_zone_temp'

On the client:

    llmq list
    llmq-bench --pending
    llmq jobs
    llmq-index stats

## Common failures

**"no catalogue: pass --catalogue or set OPEN_SLOP_CATALOGUE".** The program was run without the home-manager wrapper. Enable `programs.llmq` or pass `--catalogue`.

**"no server reported any model".** Every endpoint failed to answer within 8 seconds. Check the row is up, the backend is enabled, the bind address is not loopback, and `openFirewallFor` covers your machine.

**A job part fails with a window error.** The part is too big for the model as it really tokenises. Resuming will fail the same way. Start a new job with a smaller `--chunk-bytes`.

**`llmq-bench --preflight` fails on telemetry.** The host has no node exporter on port 9100, or no `rpi_arm_clock_hertz` textfile metric. Without them throttling cannot be detected.

**A chat with llama-server says it cannot start it.** Your user is not in `services.open-slop.llamaServer.controlledBy` on that host, or ssh cannot log in without a prompt.

**`llmq-index` says the vector extension is not installed.** `open-slop-rag-db.service` has not run. Check `systemctl status open-slop-rag-db.service`.

**`llmq-index` refuses an endpoint as not private.** The endpoint's address is public, or a hostname with a suffix it does not accept. Use the LAN address in `programs.llmq.endpoints`.

**hailo-ollama will not start.** Check `dmesg | grep -i hailo`. "driver_compatible is false" means the driver and firmware versions disagree; remove power for ten seconds.

## Quirks in the current code

These are behaviours the code has now that you may not expect. Each is a candidate for a fix.

1. `llmq-bench --preflight --control` really stops llama-server, unloads ollama models and starts llama-server again while it lists what it would measure. Run it when nothing else is using the row.
2. The `server.nix` assertion fails when ollama is on `127.0.0.1` and `openFirewallFor` is set, even if the ranges are meant only for hailo or the gateway.
3. hailo's firewall rule is added whenever hailo is enabled, since the shipped binary always binds `0.0.0.0`.
4. The gateway does not read your measurements file; `llmq` does. Their budgets agree only while measurements do not change `ctx` or `predict`, which they currently do not.
5. `llmq-grace --dry-run` creates the job directory, and `-r` does not reject `-i` or `--fresh`.
6. `llmq-claims` has no `LLMQ_KEY_FILE` fallback.
7. `llmq-models` names the backends `cpu`, `hailo` and `llamacpp` in its status line and chat, so renaming a backend in the catalogue breaks those parts.
8. The chat in `llmq-models` does not show a reasoning model's thinking, but counts its tokens in the rate when the server reports them.
9. `llmq run` and the gateway size input from the catalogue's budget, not from the measured capacity. For llmq run this keeps a job's id stable between runs; for the gateway it is not yet done.
10. llama-server reports prompt counts that exclude its cached prefix, so the chat does not learn characters per token from llama-server answers; it uses the benchmark's figure.

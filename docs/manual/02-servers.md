# Servers and the catalogue

All options here are under `services.open-slop`. Nothing runs until one of the `enable` options is set.

## The catalogue

The catalogue describes each backend and, optionally, each model. It ships in `catalogue/default.nix` with three backends and no models: models belong to whoever deploys them. You add or override anything with `catalogue.extra`, which is merged recursively over the shipped file. The NixOS side reads `services.open-slop.catalogue.extra` and the client reads `programs.llmq.catalogue.extra`. Keep the two equal.

### Shipped backends

| Field | cpu | hailo | llamacpp |
|---|---|---|---|
| engine | ollama | hailo-ollama | llama-server |
| port | 11434 | 8000 | 8081 |
| ctx (window, tokens) | 16384 | 2048 | 16384 |
| predict (output reserved, tokens) | 2048 | 768 | 2048 |
| promptOverhead (tokens) | 512 | 256 | 512 |
| charsPerToken | 2.8 | 2.8 | 2.8 |
| temperature | 0.0 | none | 0.0 |

The hailo port describes where the shipped Hailo binary listens. It does not set it.

### A model entry

```nix
catalogue.extra.models.cpu."qwen2.5-coder:7b" = {
  summary = "one line shown in menus";
  docFit = "usable";      # best | usable | poor | unsuitable | unknown
  licence = "Apache-2.0";
  blurb = "longer text shown in previews";
  ctx = 32768;            # optional, overrides the backend's window
  predict = 4096;         # optional, overrides the backend's output reserve
};
```

Do not put measured numbers here. `llmq-bench` writes those to your cache, and they are laid over the catalogue when it is read.

### The request budget

Each model gets a byte budget per request:

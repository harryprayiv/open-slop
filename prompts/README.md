# prompts

Named instructions, shipped with the package. The home-manager module sets
`OPEN_SLOP_PROMPTS` to this directory, and llmq resolves `-P NAME` against
it: `llmq -P reference-docs` reads `reference-docs.md` from here. A name
with a slash or a `.md` suffix is a path instead.

`reference-docs.md` is the instruction llmq uses when none is given. A
built-in copy in `app/llmq/Run.hs` stands in when `OPEN_SLOP_PROMPTS` is
unset, for a binary run outside the module; keep the two in step when the
shipped one changes.

Every prompt here is measured against the golden set (handoff item 30)
before it replaces the one before it. Until that set exists, a change to a
prompt is a change to every job's output with no evidence either way.
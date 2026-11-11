# ADR 0003 (Suite): the local AI model is optional

Date: 2026-11-11. Status: **Accepted** (owner, 2026-11-11: "Yes take out the
local ai llm for now and make it optional... we are better off (for now)
making a more routstr solution"). Target: Suite `v0.9.64-alpha`, with
Continuum `v0.2.209-alpha` (`docs/adr-routstr-provider-fallback.md` there).

## Context

- chiefmonkey.art has a 15 GB disk at 74% use. `/usr/share/ollama` (the
  local model store) is 1.8 GB, plus the Ollama binary and libraries.
- The local model was a last-resort fallback for Continuum chat. It is slow on
  a CPU-only VPS (1–5 tokens a second) and much weaker than any Routstr model.
- Continuum v0.2.209-alpha now falls back across Routstr providers and
  models by itself, so the local model is rarely the only answer left.
- `INSTALL_OLLAMA` defaulted to 1. `install-continuum.sh` could switch
  `ollama.enabled` on but never off, and nothing removed an existing install.

## Decision

1. **Off by default.** `INSTALL_OLLAMA=0` in `.env.example` and in
   `bootstrap.sh`. `INSTALL_OLLAMA=1` still installs it exactly as before
   (local or remote mode).
2. **Config follows the switch.** With `INSTALL_OLLAMA=0`,
   `install-continuum.sh` sets `ollama.enabled: false` in the agent config
   (only the top-level `ollama:` block; file mode and owner kept;
   `lib/ollama-config.sh`). Every Continuum deploy keeps it in line.
3. **Removal is a stage, not a side effect.** `installers/remove-ollama.sh`,
   run by the Continuum `suite-stages-vps.yml` stage `ollama_remove` with the
   operator's approval: turn it off in Continuum and restart the agent; stop
   and disable `ollama.service`; remove the unit and drop-in,
   `/usr/local/bin/ollama`, `/usr/local/lib/ollama`, `/usr/share/ollama`,
   and the `ollama` user and group. The stage also writes `INSTALL_OLLAMA=0`
   to the operator `.env` so no later deploy reinstalls it. A normal deploy
   with `INSTALL_OLLAMA=0` never deletes anything.
4. **The in-world greeter.** `hermes-npc` (installed separately by
   Continuum's `ops/install-hermes-npc.sh`) used the same local model. The
   removal warns when that user exists; the greeter needs another model
   before it answers again.

## Consequences

- About 2 GB of disk back on servers that remove it; new installs fit 2 GB
  of RAM.
- No free offline answer when every Routstr provider is down; the chat says
  so instead.
- Bringing it back is `INSTALL_OLLAMA=1` and a bootstrap.

## Tests

`test/remove-ollama.test.sh`: config flip (only the ollama block, mode kept,
idempotent, no block, bad value, symlink refused), defaults off, and the
removal against a fake root, twice.

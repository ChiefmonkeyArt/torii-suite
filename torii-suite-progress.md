# Torii Suite Progress

## Release v0.9.24-alpha: FIPS integration

The operator approved paired merge/tag/primary-VPS rollout on 24 September 2026. Seventeen local installer-contract checks and all existing Suite scripts pass. The [Ubuntu install/rerun proof](https://github.com/ChiefmonkeyArt/torii-suite/actions/runs/36028624132) verifies stable identity, running services and valid firewall rules; Quest's real two-node proof also passes. Pair with Quest v0.2.888-alpha / ADR-0126 and verify main/tag/live equality. The Project deployment receipt records the actual live result; cross-operator enrollment and long-soak/player acceptance remain separate.

**Repo:** https://github.com/ChiefmonkeyArt/torii-suite
Current release: v0.9.24-alpha. Merge/tag status and live source commit must be checked against the deployment receipt rather than inferred from this version label.

> **Note:** Many intermediate tags shipped between v0.6.1-alpha and v0.9.8-alpha (v0.7.x, v0.8.x, v0.9.0–0.9.7-alpha) without narrated entries in this file — sourced from git history if you need details. The next entry below is v0.9.11-alpha; historical v0.6.1-alpha entry follows.

---

## Shipped

### v0.9.22-alpha - fallback model corrected to llama3.2:1b (2026-09-15)

**What shipped.** The default local Ollama model is corrected to `llama3.2:1b` (was `qwen3:0.6b`), fixing a fresh-install bug where the Continuum chat fallback silently failed. The agent's `ollama.model` has always been `llama3.2:1b` — a qwen3 "thinking" model emits its reply into the `reasoning` field and returns empty `content` over Ollama's `/v1/chat/completions` (NAP-BRIDGE-4, documented in `agent/core/ollama.mjs` + `install-nap-bridge.sh`) — but the Suite's `.env.example` hardcoded `OLLAMA_MODELS=qwen3:0.6b`, so every fresh box pulled the wrong model and the no-wallet fallback surfaced as "insufficient funds" (the primary provider's code) before "model not found". Root cause: model-name drift between the installer default and the Continuum agent config.

**Fix.** `OLLAMA_MODELS` now defaults to `llama3.2:1b` in `.env.example`, `bootstrap.sh`, `installers/install-ollama.sh`, and `installers/install-continuum.sh` so the pulled model always matches the agent config. No behavior change for remote mode.

**Version markers bumped.** `VERSION` v0.9.21-alpha → v0.9.22-alpha.

**Update-All checklist.** Code [done] `.env.example` + `bootstrap.sh` + `install-ollama.sh` + `install-continuum.sh`; version [done] `VERSION` + `README.md` changelog; continuity [done] this entry + `torii-suite-handoff.md`; ADR [n/a] no architecture change.

### v0.9.21-alpha - nginx relay vhost http2 syntax fix for Ubuntu 24.04 (2026-09-15)

**What shipped.** `installers/install-nostr-git.sh`'s relay subdomain vhost drops `http2 on;` for `listen 443 ssl http2;` / `listen [::]:443 ssl http2;`. `http2 on;` requires nginx 1.25.1+, but Ubuntu 24.04 ships nginx 1.24.0, so a fresh install failed at stage 2/7 (`unknown directive "http2"`). Paired with torii-base v0.1.13 (same revert in `nginx/torii.conf`, stage 1/7). Swept all four repos — these were the only two `http2 on;` directives remaining.

**Version markers bumped.** `VERSION` v0.9.20-alpha → v0.9.21-alpha.

**Update-All checklist.** Code [done] `install-nostr-git.sh`; version [done] `VERSION` + `README.md` changelog; continuity [done] this entry + `torii-suite-handoff.md`; ADR [n/a] no architecture change.

### v0.9.11-alpha - install-continuum.sh self-sources the suite .env with auto-export (2026-09-11)

**What shipped.** `installers/install-continuum.sh` now self-sources the suite `.env` wrapped in `set -a`/`set +a`, and defaults `SUITE_WORK_DIR` to `/opt/torii-suite/work`, so a direct `sudo install-continuum.sh` run without `bootstrap.sh`'s exported environment no longer dies with "TORII_DOMAIN not set". Root cause: the `.env` stores plain `KEY="value"` assignments and bash never auto-exports a plain assignment, so when a caller did `source .env` and launched the installer as a child process the values stayed shell-local. The self-source is idempotent (re-sourcing the same file over an already-exported value is a no-op), so a bootstrap.sh-driven run is unaffected.

**Why now.** Surfaced during the Continuum v0.2.128-alpha docs-backfill deploy: a manual `install-continuum.sh` invocation failed at preflight because the operator had sourced `.env` without exporting it.

**Tests.** Suite has no test suite of its own (established). `bash -n` clean; `shellcheck` clean on the changed block (one pre-existing SC2086 info at line 150, unrelated); functional smoke test confirms a child process sees `TORII_DOMAIN`/`CONTINUUM_ADMIN_NPUB`/`OLLAMA_MODELS` after the self-source and that `SUITE_WORK_DIR` defaults correctly.

**Version markers bumped.** `VERSION` 0.9.10-alpha → 0.9.11-alpha.

**Update-All checklist.**
- Code: [done] `installers/install-continuum.sh`.
- Version marker: [done] `VERSION`.
- README / `.env.example`: [n/a] no installer-env contract change.
- Continuity docs: [done] this entry + `torii-suite-todo.md` + `torii-suite-handoff.md`. `torii-suite-strategy.md` skipped — no strategy change.
- ADR: [n/a] no architecture change; matches `bootstrap.sh`'s existing `set -a; source .env; set +a` pattern.

### v0.9.10-alpha - thread admin npub into torii-base bootstrap (2026-09-10)

**What shipped.** `bootstrap.sh` (`_stage_base`) now passes the operator's `CONTINUUM_ADMIN_NPUB` through as `TORII_ADMIN_NPUB` when invoking torii-base's own `bootstrap.sh`. torii-base v0.1.9 replaced the install token with NIP-07 npub sign-in and now requires `TORII_ADMIN_NPUB` at bootstrap, so the base layer records the same admin identity that Continuum records at install.

**Version markers bumped.** `VERSION` 0.9.9-alpha -> 0.9.10-alpha.

---

### v0.9.9-alpha - fix clean Quest install + wire presence website (SB-08, ADR-0094) (2026-09-10)

**What shipped.** `installers/install-quest.sh`:
- Moves the `torii-quest` system-user creation to a new "3b-pre" block before world seeding (previously "7b", after). A truly clean host no longer fails on `install -d -o torii-quest`, which needs the uid/gid to already exist (SB-08).
- Adds `QUEST_PUBLIC_URL` (default `https://${TORII_DOMAIN}/quest/`) and injects it into the arena-ws systemd environment, so the presence beacon publishes a reachable `world.website` instead of an empty one — fixing the open-travel gateway hop (ADR-0094).

**Version markers bumped.** `VERSION` 0.9.8-alpha -> 0.9.9-alpha.

---

### v0.9.8-alpha - Sovereign relay subdomain default (SUITE-RELAY-SUBDOMAIN-1) (2026-09-10)

**Why.** The operator's live VPS has a manually-provisioned `wss://relay.chiefmonkey.art` (dedicated nginx vhost + its own Let's Encrypt cert, `certbot --webroot` auto-renewing). NAP-BRIDGE-3-FIXES-1 (torii-continuum v0.2.113-alpha) proved that sovereign relay end-to-end for NIP-17 gift-wrap DMs. This slice codifies that pattern into the suite installer so any fresh operator gets the same subdomain by default — no manual nginx or certbot steps.

**What shipped.**

- **`installers/install-nostr-git.sh`.** New step 7c after the fragment writes: provisions a dedicated `/etc/nginx/sites-available/relay.<TORII_DOMAIN>.conf` (HTTP-01 ACME location + HTTPS TLS + WSS reverse-proxy to `127.0.0.1:${NOSTR_RELAY_PORT}`), runs `certbot certonly --webroot -w /var/www/certbot -d relay.<TORII_DOMAIN>` when no cert exists yet, and reloads nginx via the existing `torii` sidecar. Idempotent: skips issuance when the cert already exists; writes the vhost content only when it changes. `SKIP_CERTBOT=1` demotes DNS + cert failures to warnings and writes an HTTP-only vhost so a subsequent run can upgrade it. New env: `TORII_RELAY_HOST` (default `relay.<TORII_DOMAIN>`; empty string opts out into path-only mode), `LETSENCRYPT_EMAIL` (already flowed from `torii-base`), `SKIP_CERTBOT`.

- **`bootstrap.sh`.** Extended the DNS preflight block to also resolve `${TORII_RELAY_HOST}` when `INSTALL_NOSTR_GIT=1` and `TORII_RELAY_HOST` is non-empty. Fatal (`ui_die`) unless `SKIP_CERTBOT=1`. Exports `TORII_RELAY_HOST` alongside the other nostr-git vars. Summary box now reports `wss://relay.<domain>` with `(+ wss://<domain>/relay fallback)` when the subdomain is provisioned, or falls back to `wss://<domain>/relay` in path-only mode.

- **`.env.example`.** Added the new `# TORII_RELAY_HOST=relay.example.com` opt-in comment with an explanation of the empty-string opt-out.

- **Backward compatibility preserved.** The existing `/opt/torii/nginx-fragments/relay.conf` (path-based `wss://<TORII_DOMAIN>/relay`) is still written and included in the main-domain vhost. Both endpoints reverse-proxy to the same loopback `strfry`. Any client already pointing at `/relay` keeps working; the subdomain is just the new default for fresh clients (and matches what NIP-17 clients like the Continuum nap-bridge look for by default).

**Follow-on paired slice (torii-continuum).** `ops/install-nap-bridge.sh` now derives `NPC_RELAYS="wss://relay.${TORII_DOMAIN}"` when `NPC_RELAYS` is unset and `TORII_DOMAIN` is set. Explicit `NPC_RELAYS` still wins. Together the two slices turn the manual pattern from v0.2.113-alpha ops work into the default operator experience. Shipped as torii-continuum v0.2.114-alpha.

**Tests.** `bash -n` + `shellcheck -S error` clean on the modified installers (no shell-syntax regressions). Suite has no test suite of its own; the continuum-side `ops/test/install-nap-bridge.test.sh` 28→30 covers the `TORII_DOMAIN`-default path.

**Version markers bumped.** `VERSION` 0.9.7-alpha → 0.9.8-alpha. `README.md` "New in" section added at the top. No other version markers exist in the suite repo.

**Update-All checklist.**

- Code + tests: [done] installer changes, `bash -n` + `shellcheck` clean.
- Version markers: `VERSION` [done]; `README.md` "New in" [done]. Suite has no `src/config.js`, `sw.js`, `index.html` labels, dashboard, or state JSONs.
- Continuity docs: `torii-suite-progress.md` (this file, done); `torii-suite-todo.md` (new, created); `torii-suite-handoff.md` (new, created); strategy unchanged.
- ADRs: [none] no architecture change — the existing torii-base/nginx-fragment split still holds; this adds a per-app dedicated vhost, which is already the pattern for the main domain.
- GitHub: PR to be merged squash on `main`; tag `v0.9.8-alpha` cut from the merge.
- VPS: apply by running `install-nostr-git.sh` from the new tag — the operator's manually-configured `relay.chiefmonkey.art` vhost + cert already exist, so the installer will detect the existing cert (idempotent), write its own canonical vhost file replacing the manual one, and reload nginx. Verify: `curl -sI https://relay.chiefmonkey.art` still returns 200/101, `curl -H "Accept: application/nostr+json" https://relay.chiefmonkey.art/` returns NIP-11 JSON.

---

### v0.6.1-alpha - Quest ref pin (2026-07-11)

**PR:** [#15](https://github.com/ChiefmonkeyArt/torii-suite/pull/15) merged squash.
**Tag:** v0.6.1-alpha, pushed and byte-verified.

`torii-quest` cut v0.2.367-alpha (first tag carrying `server/arena-ws.js`). Suite defaults updated so fresh installs stand up the full MP stack with no `.env` overrides.

- `.env.example`: `TORII_QUEST_REF=main` -> `TORII_QUEST_REF=v0.2.367-alpha`
- `bootstrap.sh`: fallback default matches
- `VERSION`: 0.6.0-alpha -> 0.6.1-alpha
- README: one-liner URL bumped in both spots; "New in v0.6.1-alpha" stanza added

**Verification:** `bash -n` + shellcheck clean on all scripts; no device names / banned verbs / forbidden platforms in the diff; pinned URL sha256 (`cbe44966…`) matches local `main`; `.env.example` at the tag has `TORII_QUEST_REF=v0.2.367-alpha` (confirmed via raw.githubusercontent.com fetch).

**Files touched (4):** `.env.example`, `README.md`, `VERSION`, `bootstrap.sh`. +15 / -9 lines.

---

### v0.6.0-alpha - SUITE-VPS-READY-1 (2026-07-11)

**PR:** [#14](https://github.com/ChiefmonkeyArt/torii-suite/pull/14) merged squash.
**Tag:** v0.6.0-alpha, pushed and byte-verified.

Closes the two remaining blockers for the chiefmonkey.art VPS install: server-side auth rate limiting (paired with Continuum v0.2.14-alpha) and the arena-ws multiplayer install stage in the suite installer.

**Shipped:**

- **Continuum rate-limit slice** (Items G, H)
  - `.env.example`: `CONTINUUM_RATE_LIMIT_ENABLED` (default 1), `CONTINUUM_RATE_LIMIT_CHALLENGE_PER_MIN` (10), `CONTINUUM_RATE_LIMIT_VERIFY_PER_MIN` (20), `CONTINUUM_RATE_LIMIT_MAX_CHALLENGES` (1000)
  - `installers/install-continuum.sh`: idempotent Python patcher writes the four fields into `agent/config.yaml` (mirrors the ollama patcher; regex handles the blank-line-tolerant `rate_limit:` block shape)
  - `bootstrap.sh`: `_stage_auth_smoke_rate()` fires N+1 POSTs to `/api/auth/challenge` on loopback, expects 429 on the (N+1)th. Records `AUTH_SMOKE_RATE_RESULT` (`ok`/`not-enforced`/`skipped`) and renders on the summary card. Never hard-fails; skipped when `CONTINUUM_RATE_LIMIT_ENABLED=0`.
- **Quest arena-ws installer** (Items L, M, N, O)
  - `.env.example`: `INSTALL_ARENA_WS` (default 1), `ARENA_WS_PORT` (default 8788), `ARENA_WS_MODE` (default `authoritative`)
  - `installers/install-quest.sh` new stage 7:
    - Creates `torii-quest` system user (idempotent)
    - Copies `dist/server/arena-ws.cjs` + `dist/package.json` to `/opt/torii-quest/mp/`, `npm install --omit=dev` as `torii-quest`
    - Writes hardened systemd unit `torii-arena-ws.service` (`NoNewPrivileges`, `ProtectSystem=strict`, `PrivateTmp`, `MemoryDenyWriteExecute`, `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6`, etc.)
    - Writes nginx fragment `/opt/torii/nginx-fragments/quest-mp.conf` (WebSocket upgrade proxy `/mp` -> `127.0.0.1:${ARENA_WS_PORT}`)
    - Enables + starts + waits up to 10s for readiness (health probe with TCP fallback)
    - Auto-writes `dist/package.json` declaring `ws@^8.21.0` if the Quest build did not emit one (the esbuild pipeline produces the `.cjs` but no manifest)
    - Soft-skips with a warning if `dist/server/arena-ws.cjs` is missing (falls through cleanly - the pinned Quest ref does not yet carry arena-ws)
  - `bootstrap.sh`: `_stage_mp_smoke()` opens a loopback WebSocket to `127.0.0.1:${ARENA_WS_PORT}/mp` and verifies arena-ws is speaking WS. Records `MP_SMOKE_RESULT` on the summary card.
- **Preflight + polish** (Item P)
  - Ubuntu 26.04 now logs an INFO note that local Ollama is unofficial-but-should-work when `INSTALL_OLLAMA=1` and `OLLAMA_MODE=local`; escape hatch is `INSTALL_OLLAMA=0` or `OLLAMA_MODE=remote`.
- **Version + pins** (Item J)
  - `VERSION`: `0.5.0-alpha` -> `0.6.0-alpha`
  - `TORII_CONTINUUM_REF` default `main` -> `v0.2.14-alpha`
  - `TORII_QUEST_REF` stays `main` (no tag carrying arena-ws exists yet)
  - README: pinned one-liner URL bumped in both spots; new "New in v0.6.0-alpha" env-vars section

**Verification done before merge:**
- `bash -n` clean across `bootstrap.sh` and every `installers/*.sh`
- `shellcheck --exclude=SC1091,SC2154,SC2016` clean on all touched scripts (fixed SC2034 unused loop var and SC2086 unquoted `/dev/tcp` port before commit)
- Continuum rate_limit patcher exercised across 3 real states against `torii-continuum/agent/config.example.yaml`: rewrite existing block, idempotent second run, strip-and-append when block absent
- No device names, personal identifiers (iMac / Duncan / A76A1E1D / hodlr.rocks / /Users/), banned verbs (scrape / crawl), or forbidden platforms (cloudflare / fly.io / railway / vercel / netlify / heroku / render.com) in the diff
- Pinned URL byte-verified: `curl -fsSL https://raw.githubusercontent.com/ChiefmonkeyArt/torii-suite/v0.6.0-alpha/bootstrap.sh | sha256sum` matches local `main` bootstrap.sh (`c7d89add...`)

**Files touched (6):** `.env.example`, `README.md`, `VERSION`, `bootstrap.sh`, `installers/install-continuum.sh`, `installers/install-quest.sh`. +489 / -12 lines.

**Reality note (resolved same day):** the Quest repo did not yet ship a tag that carries `server/arena-ws.js` when v0.6.0-alpha landed. `torii-quest` cut v0.2.367-alpha immediately after, and suite v0.6.1-alpha pins to it. Live install now brings up arena-ws with no `.env` overrides.

---

### v0.5.0-alpha - SUITE-CONTINUUM-NOSTR-LOGIN (2026-07-11)

**PR:** [#13](https://github.com/ChiefmonkeyArt/torii-suite/pull/13) merged fast-forward.
**Tag:** v0.5.0-alpha, pushed and verified.

Defence-in-depth pass over Continuum's existing Nostr sign-in stack. The auth code itself already lives in `torii-continuum` (challenge/verify/HMAC-token flow, NIP-44 v2 crypto, admin_npub allowlist). This slice hardens the torii-suite side around it.

**Shipped:**
- **A. Install-time auth smoke test** (`bootstrap.sh`) - hits `/api/auth/challenge` via loopback, validates 48-hex challenge shape, POSTs a bogus kind-22242 event to `/api/auth/verify`, expects rejection. Records outcome (`ok`/`health-timeout`/`challenge-*`/`SECURITY-FAIL`/`skipped`) and surfaces on the summary card. Non-blocking.
- **B. session_secret sanity check** (`installers/install-continuum.sh`) - post-substitution grep confirms the 64-char hex secret replaced the placeholder; aborts if not.
- **C. `installers/rotate-session-secret.sh`** - atomic secret rotation with timestamped backup, verified restart via `/api/health`, rollback on failure.
- **D. `installers/set-admin-npub.sh`** - full bech32 shape validation, atomic write, verified restart, idempotent, rollback on failure.
- **E. Plebeian Signer install hint** (`bootstrap.sh`) - printed before the npub prompt (Chrome Web Store + addons.mozilla.org). Full bech32 shape validation on both interactive and non-interactive paths; paste-whitespace trimmed.
- **F. `CONTINUUM_SESSION_TTL_SEC`** (`.env.example` + `installers/install-continuum.sh`) - integer 60-604800 seconds, default 86400. Rewrites `session_ttl_sec` in `agent/config.yaml`.
- **G. README** - new "Signing in for the first time" section with troubleshooting table (7 rows) and key-hygiene commands. Pinned one-liner bumped in two spots.

**Explicitly out of scope, deferred to v0.6.0-alpha:** Server-side rate limiting on `/api/auth/challenge` and `/api/auth/verify`. Shipped in v0.6.0-alpha alongside the Continuum v0.2.14-alpha rate_limit slice.

---

### v0.4.0-alpha - SUITE-OLLAMA-REMOTE-1 (2026-07-10)

Remote Ollama endpoint support. `OLLAMA_MODE=local|remote`, `OLLAMA_URL`, optional `OLLAMA_AUTH_HEADER`, plaintext-HTTP guardrail (loopback / RFC1918 / Tailscale / `.internal|.lan|.local|.home` treated as private), preflight `/api/tags` probe, live benchmark against remote endpoint.

---

### v0.3.0-alpha - SUITE-SEXY-1
Polished install UX: color output, staged progress, summary card, plan card, benchmark tok/s reporting.

### v0.2.1-alpha - SUITE-BENCH-1
Ollama benchmark stage.

### v0.2.0-alpha - SUITE-BRIDGES-1
Onboarding bridges (NAP-to-NAP, QR).

### v0.1.6-alpha - SUITE-BOOT-2
Idempotency + preflight hardening.

### v0.1.5-alpha - SUITE-BOOT-1
Initial one-shot bootstrap.

---

## In progress

Nothing. v0.6.1-alpha closes the VPS-install readiness track. Next action: run the install on chiefmonkey.art (SHC Ubuntu 26.04 VPS, `23.182.128.118`, apex + www A records verified). One-liner:

```bash
curl -fsSL https://raw.githubusercontent.com/ChiefmonkeyArt/torii-suite/v0.6.1-alpha/bootstrap.sh | sudo bash
```

---

## Backlog (unordered, will be sliced later)

- Continuum web wallet: Bitcoin/Lightning payments panel
- torii-de: full v0.3 desktop environment integration into suite
- Automated update path: `torii-update` command that rolls forward from any prior tag
- Multi-domain support: install with more than one `TORII_DOMAIN` (e.g. quest + continuum on separate hosts)
- Backup/restore: single command to snapshot `/etc/torii-*`, Continuum SQLite, Nostr keys
- Rate-limit metrics + alerting (Prometheus endpoint on Continuum agent)

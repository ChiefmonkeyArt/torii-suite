# Torii Suite Strategy

## Active direction: FIPS background node build

Candidate v0.9.24-alpha integrates FIPS provisioning with the Suite Quest path, paired with Quest ADR-0126. Keep player UI, world storage and multiplayer unchanged; use a separate stable node key, one known peer and bounded services. Broader collectors and mutual discovery remain outside scope. Historical version markers below describe earlier work, not the current release.

**Repo:** https://github.com/ChiefmonkeyArt/torii-suite
**Purpose:** one-shot installer that stands up the full Torii self-hosted stack on a fresh VPS — Continuum agent, Quest, Plebeian, onboarding bridges, and (optionally) local Ollama for LLM fallback.
**Current version:** v0.7.0-alpha
**Install pattern:** `curl -fsSL https://raw.githubusercontent.com/ChiefmonkeyArt/torii-suite/v0.7.0-alpha/bootstrap.sh | sudo bash`

---

## Design principles (non-negotiable)

1. **Privacy → security → efficiency → 80/20.** In that order, every decision.
2. **Sovereign by default.** Users own their keys, their data, their infrastructure. No KYC, no accounts on our servers, no third-party CDN, no Cloudflare, no PaaS lock-in (Fly, Railway, Vercel, Netlify, Heroku, Render — none).
3. **One repo per app.** `torii-quest`, `torii-continuum`, `torii-de`, `torii-base`, `torii-suite` — files carry only their own repo's project name; never cross-name.
4. **Version bump on every change.** Doc-only edits included. No exceptions.
5. **PR → main.** No local-only work. Every change lands via PR on `main`, then a signed tag.
6. **Never publish device names, hostnames, or personal identifiers to GitHub.**
7. **Style rules.** Never "scrape/crawl" — use collect/gather/read/fetch/browse. Plain ASCII hyphens in commit messages (em-dashes get literal-escaped by bash).

---

## Architecture

The suite is a bootstrap script + a set of installer scripts + a shared lib. It orchestrates:

- **torii-base** — hardening, users, firewall, systemd shape
- **Ollama** — optional LLM fallback; local (installed) or remote (existing endpoint)
- **torii-continuum** — the agent + web UI (Nostr wallet/dashboard)
- **torii-quest** — the metaverse game server (arena-ws)
- **plebeian** — Bitcoin/Nostr marketplace surface
- **onboarding bridges** — NAP-to-NAP flow, QR onboarding

Each stage is idempotent, has a preflight, and can be skipped via `INSTALL_*=0` env vars.

---

## Deployment modes

### Ollama modes (added v0.4.0-alpha)

| Mode                    | Behaviour                                                                                                         | Use case                                                                                    |
| ----------------------- | ----------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| `OLLAMA_MODE=local`     | install-ollama.sh runs, binds `127.0.0.1:11434`, pulls default model, wires Continuum to `http://127.0.0.1:11434` | small VPS is beefy enough OR privacy demands single-box                                     |
| `OLLAMA_MODE=remote`    | install-ollama.sh SKIPPED. Preflights `GET $OLLAMA_URL/api/tags`, wires Continuum to `$OLLAMA_URL`                | keep VPS small, offload inference to homelab GPU / Tailscale peer / private inference VPS   |

Remote mode supports an optional `OLLAMA_AUTH_HEADER` for reverse-proxy-authenticated endpoints (nginx basic auth, oauth2-proxy, bearer gateway). Vanilla Ollama has no built-in auth — never expose it plaintext to the internet.

### Plaintext-HTTP guardrail

`http://` to a public-looking host emits a warning. Loopback, RFC1918, Tailscale (`100.64/10`, `*.ts.net`), and `*.internal/*.lan/*.local/*.home` are treated as private and skip the warning.

---

## Shipped slices

| Version         | Slice ID                    | Summary                                                                                       |
| --------------- | --------------------------- | --------------------------------------------------------------------------------------------- |
| v0.1.5-alpha    | SUITE-BOOT-1                | initial one-shot bootstrap; base + Continuum + Quest wiring                                   |
| v0.1.6-alpha    | SUITE-BOOT-2                | idempotency + preflight hardening                                                             |
| v0.2.0-alpha    | SUITE-BRIDGES-1             | onboarding bridges (NAP-to-NAP, QR)                                                           |
| v0.2.1-alpha    | SUITE-BENCH-1               | Ollama benchmark stage, live tok/s reporting                                                  |
| v0.3.0-alpha    | SUITE-SEXY-1                | polished install UX (color output, staged progress, summary card)                             |
| v0.4.0-alpha    | SUITE-OLLAMA-REMOTE-1       | remote Ollama endpoint support                                                                |
| v0.5.0-alpha    | SUITE-CONTINUUM-NOSTR-LOGIN | Nostr-sign-in defence in depth: auth smoke test, session-secret rotation, admin-npub setter   |
| **v0.6.0-alpha**| **SUITE-VPS-READY-1**       | **Continuum rate-limit env vars + patcher; Quest arena-ws systemd install stage + /mp proxy** |
| **v0.6.1-alpha**| **Quest ref pin**            | **`TORII_QUEST_REF` default `main` -> `v0.2.367-alpha` (first Quest tag carrying arena-ws)**  |
| v0.6.2 -> v0.6.8-alpha | SUITE-VPS-INSTALL-HARDENING | seven point releases driven by first live chiefmonkey.art install: Ubuntu-26 preflight polish, agent-config env-var patcher edge cases, drop MemoryDenyWriteExecute from Node services, torii-quest home-dir ownership fix, Plebeian fragment fix, Continuum strapline expansion, `scripts/torii-doctor-deep.sh` read-only diagnostic dumper |
| **v0.7.0-alpha**| **SUITE-NGINX-ASSET-ALIAS-FIX** | **Continuum + Quest blank-page fix: replace broken `location ~*` + `alias` regex with prefix `location /<app>/assets/` + `alias` + `try_files $uri =404`. Live install evidence: `GET /continuum/assets/*.js -> 301 to <path>/ served as text/html`** |

---

## Next slice

VPS-install readiness track closes at **v0.7.0-alpha** — first fully-rendering install on chiefmonkey.art. Next planned work is the **launcher-as-claim-gate + owner sidecar** slice (target: v0.8.0-alpha):

- **Torii Base owner sidecar** — new endpoints on `127.0.0.1:8780` (already running as `torii-base-sidecar.service`): `GET /api/torii/owner`, `POST /api/torii/claim` (NIP-07 challenge validation, writes `/opt/torii/owner.json`), `POST /api/torii/homepage` (operator-only, sets which app answers `chiefmonkey.art/`), plus a `torii owner reset` CLI.
- **Two-step launcher onboarding** — Step 1 unclaimed: "Your Torii, your gateway." + server card + primary "Claim with Plebeian Signer" CTA. Step 2 claimed: "Welcome, operator." + 3 tiles (Continuum, Quest, Plebeian) with Open + Set-as-homepage per tile. Continuum has **no** set-as-homepage button — operator-only app, never a public homepage. Amber+neon design system locked in (mockups already built in workspace).
- **Silent SSO across apps** — Continuum landing (and later Quest, Plebeian) reads `/api/torii/owner` to auto-recognise the seeded npub instead of re-prompting for login.

Secondary backlog: `torii-update` roll-forward command, backup/restore snapshot, rate-limit metrics endpoint, doctor script hostname/port bug fixes (line 69 of progress.md).

---

## Decision log

- **v0.4.0-alpha: one `OLLAMA_MODE` var with two values, not three.** `disabled` is already covered by the existing `INSTALL_OLLAMA=0`. Fewer axes of configuration = fewer bug surfaces.
- **v0.4.0-alpha: preflight probes `/api/tags` BEFORE any stages run.** 5s to fail is cheap; failing after installing torii-base + Continuum is not.
- **v0.4.0-alpha: plaintext HTTP is a warning, not a hard fail.** Sovereign users with novel Tailscale suffixes or air-gapped LANs shouldn't be blocked. We warn loudly and get out of the way.
- **v0.4.0-alpha: auth header written to `agent/config.yaml` mode 0600, passed via env vars.** Never on command line, never in `ps`.
- **v0.4.0-alpha: install-ollama.sh refuses to run if `OLLAMA_MODE=remote`.** Defence in depth against operator error on a re-run.
- **v0.5.0-alpha: server-side rate limiting deferred to v0.6.** The Continuum agent had no limiter yet - testing a nonexistent feature would fabricate false confidence. Sliced against `torii-continuum` first (v0.2.14-alpha), then re-integrated in suite v0.6.0-alpha.
- **v0.6.0-alpha: Continuum ref pins to `v0.2.14-alpha`; Quest ref stays `main`.** Continuum ships the rate-limit slice as a tagged release. Quest has `server/arena-ws.js` on `main` at `0.2.366-alpha` but no tag carrying it - pinning to a nonexistent tag would break every install. The Quest MP stage is written to soft-skip when `dist/server/arena-ws.cjs` is missing, so the rest of the install proceeds cleanly until Quest cuts a real tag.
- **v0.6.1-alpha: Quest ref pinned to `v0.2.367-alpha`.** Quest cut its first arena-ws-carrying tag the same day v0.6.0-alpha shipped. Rather than leave the pin as `main` (breaks reproducibility) or override via install-time `.env` (leaves `.env.example` and `bootstrap.sh` defaults lying to future operators), suite cut a real point release. Version-bump-on-every-change rule mandates the shipped default match the intended contract.
- **v0.6.0-alpha: arena-ws bound to loopback + fronted by nginx `/mp`.** Never exposes port 8788 to the internet. WSS terminates at nginx (Let's Encrypt cert), plain WS to loopback. Systemd unit is hardened (`NoNewPrivileges`, `ProtectSystem=strict`, `PrivateTmp`, `MemoryDenyWriteExecute`, `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6`).
- **v0.6.0-alpha: rate-limit smoke never hard-fails.** Fires N+1 challenges on loopback, records `ok`/`not-enforced`/`skipped` on the summary card. Blocking the install because the limiter is off would trap operators who chose `CONTINUUM_RATE_LIMIT_ENABLED=0` for dev boxes.

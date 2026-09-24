# Torii Suite - Master TODO

## FIPS release v0.9.24-alpha

- [x] Pinned/checksummed minimal runtime, idempotent identity, isolated relay proxy and default-deny firewall.
- [x] Automatic Suite Quest hook and same-origin presence route, with operator opt-out.
- [x] Tests, CI install/rerun proof, operations guide and coordinated Quest dependency.
- [x] Pass fresh Ubuntu service/firewall and Quest real two-node transport CI.
- [x] Primary operator approved coordinated merge/tag/deploy through the existing fixed root updater. Verify the result in the deployment receipt; the second operator performs their own approved installation.
- [ ] Complete actual heartbeat exchange, disk/resource soak and player UX acceptance before declaring shipped.

> Torii Suite is the operator-facing deployment layer: `bootstrap.sh` + the `installers/` set that provision `torii-base`, Continuum, Quest, Ollama, cors-proxy, webssh, and (optionally) the sovereign nostr-git relay.

> This file is the **active task list and source of truth for Torii Suite**. Update whenever tasks are added, changed, completed, removed, or reprioritised. Companion docs (per `Torii` Space instructions): `torii-suite-strategy.md`, `torii-suite-todo.md`, `torii-suite-progress.md`, `torii-suite-handoff.md`.

### Active tasks

- **SUITE-ENV-SELFSOURCE-1 - install-continuum.sh self-sources the suite .env with auto-export. DONE v0.9.11-alpha.** Direct installer runs (without bootstrap.sh's exported env) now resolve TORII_DOMAIN/CONTINUUM_ADMIN_NPUB/OLLAMA_* from the suite `.env` via a `set -a`-wrapped source, and `SUITE_WORK_DIR` defaults to `/opt/torii-suite/work`. See `torii-suite-progress.md`.

- **SUITE-ADMIN-NPUB-1 - thread CONTINUUM_ADMIN_NPUB into torii-base as TORII_ADMIN_NPUB. DONE v0.9.10-alpha.** torii-base v0.1.9 swapped the install token for NIP-07 npub sign-in and now requires `TORII_ADMIN_NPUB` at bootstrap; `bootstrap.sh` passes the operator's `CONTINUUM_ADMIN_NPUB` through so the base layer records the same admin identity as install. See progress.

- **SUITE-PRESENCE-WEBSITE-1 - derive QUEST_PUBLIC_URL + create torii-quest user before seed. DONE v0.9.9-alpha (SB-08, ADR-0094).** `install-quest.sh` creates the torii-quest system user before world seeding (clean-host fix) and injects a `TORII_DOMAIN`-derived `QUEST_PUBLIC_URL` into arena-ws so the presence beacon publishes a reachable `world.website` (open-travel hop). See progress.

- **SUITE-RELAY-SUBDOMAIN-1 - relay.<TORII_DOMAIN> vhost + cert as default. DONE v0.9.8-alpha (installer + bootstrap DNS preflight + README + env.example; PR + tag).** **Why.** Operator's live VPS proved out a manually-configured `wss://relay.chiefmonkey.art` (dedicated nginx vhost + own Let's Encrypt cert + certbot --webroot auto-renew) during NAP-BRIDGE-3 round-trip work. NIP-17 clients (and the Continuum nap-bridge) look for `relay.<domain>` by default; the pre-slice path-based `wss://<domain>/relay` worked but was non-default and mixed relay traffic in with the main-domain app fragments. **Done.** `installers/install-nostr-git.sh` gets a new step 7c: writes `/etc/nginx/sites-available/relay.<TORII_DOMAIN>.conf` (HTTP-01 ACME + HTTPS + WSS proxy to `127.0.0.1:${NOSTR_RELAY_PORT}`), runs `certbot certonly --webroot` when no cert exists, reloads nginx via the `torii` sidecar. Idempotent. `SKIP_CERTBOT=1` demotes to HTTP-only vhost so a follow-up run can upgrade. New env `TORII_RELAY_HOST` (default `relay.<TORII_DOMAIN>`; empty string opts out into path-only mode). `bootstrap.sh` DNS preflight extended to resolve the subdomain (fatal unless `SKIP_CERTBOT=1`). Path-based `/relay` fragment stays for backward compat - both endpoints reverse-proxy to the same loopback `strfry`. **Tests.** `bash -n` + `shellcheck -S error` clean on `install-nostr-git.sh` + `bootstrap.sh`. Suite has no test suite of its own. **Paired continuum slice.** torii-continuum v0.2.114-alpha (NAP-BRIDGE-DEFAULT-RELAY-1) - `ops/install-nap-bridge.sh` auto-defaults `NPC_RELAYS=wss://relay.${TORII_DOMAIN}` when unset. **Update-All.** `VERSION` 0.9.7 -> 0.9.8-alpha; `README.md` "New in v0.9.8-alpha" section added; `.env.example` gets the new opt-in comment; progress + this todo + handoff updated; strategy unchanged; PR merged to main; tag `v0.9.8-alpha` cut. VPS: run `install-nostr-git.sh` from the new tag (idempotent - detects the existing cert, replaces the manual vhost with the canonical one, reloads).

### Backlog / follow-ups

- **SUITE-TODO-NEXT-1 - decide whether path-based `/relay` fragment should be dropped in a future release.** Now that subdomain is the default, the path fragment is compat-only. Keep it for one or two releases while any existing client transitions, then reassess. Not blocking anything.

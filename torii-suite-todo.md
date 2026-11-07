# Torii Suite - Master TODO

## Continuum on its own host v0.9.31-alpha

- [x] `installers/install-continuum-host.sh` + `lib/continuum-host.sh`: `continuum.<domain>` vhost (same fragment + `/api/`), main-domain `/continuum/` 301 after the certificate, headers in every Continuum location, rollback `CONTINUUM_HOST_REMOVE=1`.
- [x] `bootstrap.sh` stage + `CONTINUUM_HOST` export for the Teams app; `.env.example`; `docs/CONTINUUM-HOST.md`.
- [x] Tests: `test/install-continuum-host.test.sh` 27/27, `test/continuum-host-live.sh` 26/26 (real nginx); CI `continuum-host.yml`.
- [ ] Deploy on chiefmonkey.art with the Teams MVP (owner-approved 2026-11-04).
- [x] v0.9.32-alpha: Teams app detects Continuum at its real config path.

## Torii Teams app v0.9.27-alpha (TEAMS-2c a)

- [x] `installers/install-teams-app.sh` (opt-in, needs `INSTALL_TEAMS`): pinned-checksum release, `teams.<domain>` vhost, `/torii-node.json`, Continuum CORS, launcher tile.
- [x] `lib/teams-app.sh` + `test/install-teams-app.test.sh`; `test/teams-app-live.sh` + `teams-app.yml` against real nginx.
- [x] v0.9.28-alpha: write `teams.app_url` into the Continuum agent config (TEAMS-2a Team view link; Continuum adds the link).
- [x] v0.9.29-alpha: pinned torii-teams `0.6.1-torii.1` (tag + SHA-256).
- [x] v0.9.30-alpha: pin `0.6.1-torii.2` (per-project sidebar, torii-teams ADR 0002); `frame-ancestors` = Continuum hosts, no `X-Frame-Options`; node file `continuum` honours `CONTINUUM_HOST` (vhost lands in v0.9.31, other session).
- [x] v0.9.33-alpha: pin `0.6.1-torii.3` (ec2bc86; node builds never contact Cordn's coordinator, ADR 0003; project-only main pane). Redeploy: `suite-stages-vps.yml` suite_tag=v0.9.33-alpha stages=teams_app (other session).
- [x] v0.9.42-alpha: pin `0.6.1-torii.12` (ADR 0011, join while the owner is away; needs Continuum v0.2.200-alpha). Redeploy continuum, then teams_app.
- [x] v0.9.41-alpha: pin `0.6.1-torii.11` (one-tap thumbs up, ADR 0010 amendment). Redeploy teams_app only.
- [x] v0.9.40-alpha: pin `0.6.1-torii.10` (ADR 0010, joining that works; needs Continuum v0.2.199-alpha). Redeploy continuum, then teams_app.
- [x] v0.9.39-alpha: pin `0.6.1-torii.9` (ADR 0009, invite links; needs Continuum v0.2.198-alpha). Redeploy continuum, then teams_app.
- [x] v0.9.38-alpha: pin `0.6.1-torii.8` (ADR 0008, one sign-in; needs Continuum v0.2.197-alpha). Redeploy continuum, then teams_app.
- [x] v0.9.37-alpha: pin `0.6.1-torii.7` (ADR 0007): node file server `torii-teams-files` at `/files/` (Continuum-session uploads via `/api/team/files-ok`, 100 MiB/file, 10 GiB quota), node file `files`, node-only CSP; CSP `connect-src` gains `blob:` (local file reads). Redeploy continuum + teams_app.
- [x] v0.9.36-alpha: pin `0.6.1-torii.6` (590d204; ADR 0006 membership signals, no reloads; profiles via Continuum); Continuum host `microphone=()`. Redeploy continuum (v0.2.195-alpha, suite_tag=v0.9.36-alpha) + teams_app.
- [x] v0.9.35-alpha: pin `0.6.1-torii.5` (05a6c37; fixes endless signer popups from torii.4). Redeploy teams_app.
- [x] v0.9.34-alpha: pin `0.6.1-torii.4` (7382de5; own white-labelled Teams UI, roster = membership, ADR 0005); Teams headers `microphone=()`. Redeploy: `suite-stages-vps.yml` suite_tag=v0.9.34-alpha stages=teams_app.
- [ ] Deploy: DNS A record for `teams.<domain>`, then `INSTALL_TEAMS_APP=1` (after the Plebeian trial; owner approval; run from tags).

## Torii Teams services v0.9.26-alpha (TEAMS-2b)

- [x] `installers/install-teams.sh` (opt-in): Cordn coordinator on the node relay, private ngit-grasp on the FIPS mesh only, daily backups, `torii-teams` CLI.
- [x] `teams-deps.yml`: pinned ngit-grasp build + `deps-ngit-grasp-v3.0.10` prerelease with provenance.
- [x] FIPS 0.5.1 -> 0.5.3; `members` chain + `fips.d` drop-in include (TEAMS-2d step 3).
- [x] `test/install-teams.test.sh` + `teams-build.yml` install/rerun/bind/firewall/backup proof.
- [ ] Deploy to chiefmonkey.art after the FIPS trial teardown (port 7334 collision; owner approval).
- [ ] Narrow git egress to loopback + mesh after a push/fetch proof.
- [ ] TEAMS-2a-4 writes `git-members` / `member-nodes` from the signed roster.

## Quest security policy v0.9.25-alpha

- [x] `lib/quest-headers.sh`: validate the Quest build's `csp.nginx.conf` and write `/opt/torii/nginx-snippets/quest-{security,csp}.inc` every deploy; `QUEST_CSP_ENFORCE=0` opts out.
- [x] `install-quest.sh` fragment: CSP on the game document only; four security headers restored on index/assets/worlds (nested `add_header` had dropped them).
- [x] `test/install-quest-csp.test.sh`: 49 checks incl. real `nginx -t` and served headers (fixture and real Quest v0.2.935 build).
- [x] chiefmonkey.art enforced (operator-approved 2026-10-26), applied by the Quest deploy runner.
- [ ] Other operators: picked up on their next approved Quest update; nothing to configure.

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

- [ ] **HIGH PRIORITY — FIPS-DEFAULT-1: FIPS on by default across all apps** (owner, 2026-11-04; schedule after the Teams MVP). Scope: Plebeian (market), Torii Quest, Torii Continuum and the marketplace. Rules: (1) each app gets an ADR before its behaviour changes; (2) any edit to PlebeianApp/market needs the owner's explicit approval, and analysis there stays read-only; (3) the FIPS trial teardown (removing fips-trial relay/coord/grasp, which hold :7334) does not remove or pause FIPS. It only frees the port for the real Teams FIPS install.

- **SUITE-ENV-SELFSOURCE-1 - install-continuum.sh self-sources the suite .env with auto-export. DONE v0.9.11-alpha.** Direct installer runs (without bootstrap.sh's exported env) now resolve TORII_DOMAIN/CONTINUUM_ADMIN_NPUB/OLLAMA_* from the suite `.env` via a `set -a`-wrapped source, and `SUITE_WORK_DIR` defaults to `/opt/torii-suite/work`. See `torii-suite-progress.md`.

- **SUITE-ADMIN-NPUB-1 - thread CONTINUUM_ADMIN_NPUB into torii-base as TORII_ADMIN_NPUB. DONE v0.9.10-alpha.** torii-base v0.1.9 swapped the install token for NIP-07 npub sign-in and now requires `TORII_ADMIN_NPUB` at bootstrap; `bootstrap.sh` passes the operator's `CONTINUUM_ADMIN_NPUB` through so the base layer records the same admin identity as install. See progress.

- **SUITE-PRESENCE-WEBSITE-1 - derive QUEST_PUBLIC_URL + create torii-quest user before seed. DONE v0.9.9-alpha (SB-08, ADR-0094).** `install-quest.sh` creates the torii-quest system user before world seeding (clean-host fix) and injects a `TORII_DOMAIN`-derived `QUEST_PUBLIC_URL` into arena-ws so the presence beacon publishes a reachable `world.website` (open-travel hop). See progress.

- **SUITE-RELAY-SUBDOMAIN-1 - relay.<TORII_DOMAIN> vhost + cert as default. DONE v0.9.8-alpha (installer + bootstrap DNS preflight + README + env.example; PR + tag).** **Why.** Operator's live VPS proved out a manually-configured `wss://relay.chiefmonkey.art` (dedicated nginx vhost + own Let's Encrypt cert + certbot --webroot auto-renew) during NAP-BRIDGE-3 round-trip work. NIP-17 clients (and the Continuum nap-bridge) look for `relay.<domain>` by default; the pre-slice path-based `wss://<domain>/relay` worked but was non-default and mixed relay traffic in with the main-domain app fragments. **Done.** `installers/install-nostr-git.sh` gets a new step 7c: writes `/etc/nginx/sites-available/relay.<TORII_DOMAIN>.conf` (HTTP-01 ACME + HTTPS + WSS proxy to `127.0.0.1:${NOSTR_RELAY_PORT}`), runs `certbot certonly --webroot` when no cert exists, reloads nginx via the `torii` sidecar. Idempotent. `SKIP_CERTBOT=1` demotes to HTTP-only vhost so a follow-up run can upgrade. New env `TORII_RELAY_HOST` (default `relay.<TORII_DOMAIN>`; empty string opts out into path-only mode). `bootstrap.sh` DNS preflight extended to resolve the subdomain (fatal unless `SKIP_CERTBOT=1`). Path-based `/relay` fragment stays for backward compat - both endpoints reverse-proxy to the same loopback `strfry`. **Tests.** `bash -n` + `shellcheck -S error` clean on `install-nostr-git.sh` + `bootstrap.sh`. Suite has no test suite of its own. **Paired continuum slice.** torii-continuum v0.2.114-alpha (NAP-BRIDGE-DEFAULT-RELAY-1) - `ops/install-nap-bridge.sh` auto-defaults `NPC_RELAYS=wss://relay.${TORII_DOMAIN}` when unset. **Update-All.** `VERSION` 0.9.7 -> 0.9.8-alpha; `README.md` "New in v0.9.8-alpha" section added; `.env.example` gets the new opt-in comment; progress + this todo + handoff updated; strategy unchanged; PR merged to main; tag `v0.9.8-alpha` cut. VPS: run `install-nostr-git.sh` from the new tag (idempotent - detects the existing cert, replaces the manual vhost with the canonical one, reloads).

### Backlog / follow-ups

- **SUITE-TODO-NEXT-1 - decide whether path-based `/relay` fragment should be dropped in a future release.** Now that subdomain is the default, the path fragment is compat-only. Keep it for one or two releases while any existing client transitions, then reassess. Not blocking anything.

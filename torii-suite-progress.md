# Torii Suite Progress

## Release v0.9.51-alpha: up to eight FIPS peers (2026-11-10)

The FIPS config renderer now takes up to 8 peers instead of 1, each with its own transport name, from a peer file of up to 8 KiB, matching Quest v0.2.939-alpha (ADR-0151). No installer logic or service change; a node with zero or one peer renders exactly as before.

## Release v0.9.50-alpha: Auctions v0.2.0, FROST and Coco (2026-11-10)

Pins plebeian-arena-auctions v0.2.0 (fee2ce3, SHA-256 `a0ea3ef49aaeb8713159fdbeb656911680056145867893d64d432012732d2c65`): escrow is one FROST 3-of-4 group key (frost-secp256k1-tr 3.0.0) instead of NUT-11 multisig, and the browser wallet is Coco (coco-core 2.0.0). The installer requires `bin/arena-frost`; the gateway unit re-runs `arena init` when `chain/v1/config/frost_key.json` is missing, so v0.1 chains are replaced on upgrade. Tests: contract 45/45; live 21/21 (stale v0.1 chain replaced, four 0600 shares, one group key), e2e 34/34 over HTTPS. v0.9.49-alpha was deployed to chiefmonkey.art (owner approved) and serves v0.1.0 until this release is deployed.

## Release v0.9.49-alpha: Auctions picks a free port (2026-11-09)

The first VPS run (Continuum `suite-stages-vps.yml`, stage `auctions`, Suite v0.9.48-alpha) stopped safely before installing anything: 8795 was already in use on chiefmonkey.art. On a first install, the installer now moves an unset gateway or mint port to the next free one (up to +50) and saves the choice in `/etc/torii/auctions/ports` (0600); later runs reuse it. Explicit settings still win, and validator ports still fail closed. Tests: contract 43/43; live 19/19 with a listener on 8795 (gateway moved to 8796), e2e 30/30. The release repo is now public (owner approved), so the VPS downloads it directly.

## Release v0.9.48-alpha: Plebeian Auctions, team-only (2026-11-09)

Suite ADR 0002. New opt-in `installers/install-auctions.sh` (`INSTALL_AUCTIONS=1`) installs plebeian-arena-auctions `v0.1.0` (282ac2c), SHA-256 `76fbf0dfe7297a0928d99e8046caecc9436e1ff6bbd3e9daf226e52cfba397f0`, CI-built by the arena's `release.yml`. It runs at `auctions.<domain>` on its own certificate, with no `torii register` and no main-domain fragment, so there is no launcher card. Two sandboxed DynamicUser units, loopback only. Tests: `test/install-auctions.test.sh` 37/37; `test/auctions-live.sh` 18/18 against real nginx and systemd, including the arena's 30/30 acceptance suite over HTTPS. The release repo is private, so the VPS needs `AUCTIONS_TARBALL` or a public repo.

## Release v0.9.47-alpha: the FIPS node on every install (2026-11-09)

Suite ADR 0001. Every default install now sets up the FIPS node in its own step after the node relay, whether or not Quest is chosen, with no peers and the same limits. Without the relay or a TUN device it says so and skips; `INSTALL_FIPS=0` still opts out. The doctor step shows "FIPS: running, N peers". First of the FIPS-default ADRs; Continuum and Quest next, Plebeian later.

## Release v0.9.46-alpha: pin torii-teams 0.6.1-torii.16 (2026-11-09)

Removal finishes before you leave (torii-teams ADR 0015). Pin
`0.6.1-torii.16` (68bcc62), SHA-256
`ca8e4cb692fd32fca623a5cea82b40e96847e00487269d7b1666f013e4b917b5`, attestation present (torii-release.yml at the tag). Pairs with Continuum v0.2.202-alpha.

## Release v0.9.45-alpha: pin torii-teams 0.6.1-torii.15 (2026-11-08)

Shisa favicon, install icons and sign-in logo (torii-teams ADR 0014). Pin
`0.6.1-torii.15` (80f9f99), SHA-256
`60007a179628c1a739ba51fc0fd2178bf3195c66befa186561b30e0095b33bfe`, attestation present (torii-release.yml at the tag). No Continuum change.

## Release v0.9.44-alpha: pin torii-teams 0.6.1-torii.14 (2026-11-08)

One shisa look (torii-teams ADR 0013): painted pair at a laptop, washed in the
theme colour. Pin `0.6.1-torii.14` (2e54606), SHA-256
`ffe441417e09c4d0a2c090246f684071e4914dcdb893a7a35ed4422c991b8a4a`, attestation present (torii-release.yml at the tag). No Continuum change.

## Release v0.9.43-alpha: pin torii-teams 0.6.1-torii.13, gzip (2026-11-07)

Remove while the owner is away and a lighter start-up (torii-teams ADR 0012).
Pin `0.6.1-torii.13` (1064e44), SHA-256
`2bda3799687a79e62ae6f398ae803d843de71e6613bc1d2f301834f73e8b429e`, attestation present (torii-release.yml at the tag). Needs Continuum
v0.2.201-alpha. The live Teams host sent every file uncompressed; the
installer now pre-compresses the release and the vhost serves it with
`gzip_static`.

## Release v0.9.42-alpha: pin torii-teams 0.6.1-torii.12 (2026-11-07)

Join the chat while the owner is away (torii-teams ADR 0011). Pin
`0.6.1-torii.12` (eea9d92), SHA-256
`6d4d533d7fb13e141130a2802550d66f894bea26aa32e302b17b859b4989696c`, attestation verified. Needs Continuum v0.2.200-alpha. No
installer logic change.

## Release v0.9.41-alpha: pin torii-teams 0.6.1-torii.11 (2026-11-07)

One-tap thumbs up beside each message, press and hold for the emoji row
(torii-teams ADR 0010 amendment). Pin `0.6.1-torii.11` (d4df0a0), SHA-256
`1cb800b06288f5ee1e7b82dc7c28f62cb84f103215e9ab0cd8e108c6d02363d4`, attestation verified. Continuum unchanged (v0.2.199-alpha). No
installer logic change.

## Release v0.9.40-alpha: pin torii-teams 0.6.1-torii.10 (2026-11-06)

Joining that works (torii-teams ADR 0010): personal links straight in, group
links ask first or straight in (owner-signed grant), places default to seats
left, one Teams frame while Continuum is open, shisa welcome on the invite.
Pin `0.6.1-torii.10` (73c4703), SHA-256
`82a354c377e582699512bb04d9d7a1fd63dde339090719a619d8ffd301e094df`, attestation verified. Needs Continuum v0.2.199-alpha. No
installer logic change.

## Release v0.9.39-alpha: pin torii-teams 0.6.1-torii.9 (2026-11-06)

Invite links (torii-teams ADR 0009): the owner copies a link in Continuum's Team
view; open links wait for the owner's Let in, named links sign the listed person
straight in. Pin `0.6.1-torii.9` (e4084a8), SHA-256
`e9ca8e277a876b625709f54d362f12b2c29b7d2d2240ac0e2dbc7e3f22ecca20`, attestation verified. Needs Continuum v0.2.198-alpha. No
installer logic change.

## Release v0.9.38-alpha: pin torii-teams 0.6.1-torii.8 (2026-11-06)

One sign-in (torii-teams ADR 0008): one consent card, NIP-46 permissions at
connect, the team session in localStorage with quiet renewal, and the owner's
session handed to the Team view frame. Pin `0.6.1-torii.8` (05c9502), SHA-256
`f3900c7282224d37dc33ffb61fe9ec39b190403174b0bb9d6d1690e6b72475bc`, attestation verified. Needs Continuum v0.2.197-alpha. No
installer logic change.

## Release v0.9.37-alpha: pin torii-teams 0.6.1-torii.7 (2026-11-05)

The owner asked for images and files to move to the node's own Blossom server.
New `lib/teams-files.mjs` (`torii-teams-files`, Node built-ins only) runs on
127.0.0.1:8805 behind `https://<teams host>/files/`. Uploads use the member's
Continuum session, checked with Continuum v0.2.196-alpha's
`GET /api/team/files-ok`; reads are ciphertext served as attachments in a
sandbox. With it on (default with Continuum) the Teams CSP allows only this
node's hosts. A browser test found the old CSP blocked the app reading picked
files through `blob:` URLs, so `connect-src` now includes `blob:` in both
modes. Tests: install-teams-app 68/68, teams-files 4/4, teams-app-live 27/27.

## Release v0.9.36-alpha: pin torii-teams 0.6.1-torii.6 (2026-11-05)

The owner wanted chats to start and fill without reloading the page. torii-teams
PR #12 (590d204, ADR 0006) adds membership signals with Continuum
v0.2.195-alpha: Teams re-reads the roster every 60 s without the signer, a
teammate's Teams reports "ready", and the owner's Teams adds them and reports
"added". Profiles and avatars come from Continuum, not public relays. The
Continuum Team view no longer passes the microphone to the Teams frame, so the
Continuum host Permissions-Policy is now `microphone=()` for every origin.
Release SHA-256 `8a045309...d74a` matches and its attestation is verified.

**Update-All checklist.** Code + tests [done] pin, `lib/continuum-host.sh` +
both host tests; version [done] `VERSION` + README; `.env.example` [done]; docs
[done] `docs/TEAMS.md`, `docs/CONTINUUM-HOST.md`; continuity [done]; ADR [done]
torii-teams ADR 0006 and Continuum `adr-teams-membership-signals.md`; deploy:
continuum + teams_app stages (owner approval).

## Release v0.9.35-alpha: pin torii-teams 0.6.1-torii.5 (2026-11-05)

Owner report: Continuum's Team page opened endless signer-extension popups.
The cause was torii.4 running a roster check on window focus. Each check signs
a coordinator request and decrypts the reply, and closing a popup refocuses the
page. torii-teams PR #11 (05a6c37) drops the focus trigger. The coordinator is
now asked only when something is pending, at most every 5 to 30 minutes.
Release SHA-256 `5a43ea27...f7f5` matches and its attestation is verified.

**Update-All checklist.** Code + tests [done] pin; version [done] `VERSION` +
README; `.env.example` [done]; docs [done] `docs/TEAMS.md`; continuity [done];
ADR [done] torii-teams ADR 0005 "Signer prompts"; deploy: teams_app stage (bug
fix for the owner's own box; the owner reported it and asked for the fix).

## Release v0.9.34-alpha: pin torii-teams 0.6.1-torii.4 (2026-11-04)

The owner asked for a simpler, white-labelled Teams instead of Cordn's full UI.
torii-teams PR #10 (7382de5, ADR 0005) adds Torii's own screens: sign in,
project list, one chat per project with text, images, files, reactions and
replies. The project roster is the membership: the owner starts each chat once,
and their client adds or removes people as the roster changes. The release also
fixes the service worker, which never installed in torii.1-3. Release verified:
SHA-256 `9c251d3c9954ce629f63c690e96352e72ae629dc724f825fc5f4368e3bcdabd2`
matches, MANIFEST commit 7382de5, attestation verified. With voice notes gone,
the Teams Permissions-Policy is now `microphone=()`.

Tests: `install-teams-app.test.sh` 47/47, `teams-app-live.sh` 16/16 on the
real tarball.

**Update-All checklist.** Code + tests [done] pin, headers, new header check;
version [done] `VERSION` + README; `.env.example` [done]; docs [done]
`docs/TEAMS.md`; continuity [done] todo, progress, handoff; ADR [done]
torii-teams ADR 0005; deploy: `suite-stages-vps.yml` stages=teams_app (owner
approved "Deploy torii.4 when it's tagged").

## Release v0.9.33-alpha: pin torii-teams 0.6.1-torii.3 (2026-11-04)

A live browser check of teams.chiefmonkey.art (0.6.1-torii.2) found that the
upstream first-run seed had added Cordn's public coordinator (contextvm and
primal relays), so auto-publish would send members' key packages to a third
party. torii-teams PR #8 (ec2bc86) adds `VITE_TORII_NODE_BUILD=1`: no seed, no
migration probe and no fallback publish to Cordn (ADR 0003). The main pane is
project-only, and the project list loads once per account. Release verified:
SHA-256 `3d74c2ccc0960be022fa0b80a9e2ee33a24ecd8bd1c1a56aca147e1787a2a14d`
matches, MANIFEST commit ec2bc86, attestation present. The released bytes,
served locally, seed only the node coordinator. Also checked live on
v0.9.32:
- Teams frames inside a continuum.chiefmonkey.art page, and other origins are
  blocked by frame-ancestors.
- Cross-origin sign-in reaches /api/team/auth/verify (a throwaway key gets
  not_member).

Tests: `install-teams-app.test.sh` 46/46, `teams-app-live.sh` 16/16 on the
real tarball. Not yet redeployed.

**Update-All checklist.** Code + tests [done] pin; version [done] `VERSION` +
README; `.env.example` [done]; docs [done] `docs/TEAMS.md`; continuity [done]
todo, progress, handoff; ADR [done] torii-teams ADR 0003; deploy [pending]
the other session runs `suite-stages-vps.yml` (owner approved "do all the
things").

## Release v0.9.32-alpha: Teams app finds Continuum (2026-11-04)

Found in the live Teams MVP deploy on chiefmonkey.art: `install-teams-app.sh` (v0.9.28+) looked for the Continuum config under `$SUITE_WORK_DIR/torii-continuum/agent/config.yaml`, but `install-continuum.sh` writes `$APPS_ROOT/continuum/agent/repo/agent/config.yaml`. Continuum was never detected, so the node file had no `continuum`, the Teams CSP said `frame-ancestors 'none'`, and Continuum's `cors_origins`/`teams.app_url` were not set. Fixed the path; the contract test now checks that both installers agree (46/46).

**Update-All checklist.** Code + tests [done]; version [done] `VERSION` + README; docs [done] handoff; continuity [done] todo, progress; ADR [skipped] bug fix, no decision change; deploy [done after merge] owner-approved Teams MVP.

## Release v0.9.31-alpha: Continuum on its own host (2026-11-04)

Teams MVP step 2 (owner: Teams inside `continuum.chiefmonkey.art`). New opt-in `install-continuum-host.sh` serves Continuum on `continuum.<domain>`: the vhost includes the fragment `install-continuum.sh` already writes plus the torii-base `/api/` snippet, `/` goes to `/continuum/` and other paths are 404. The main-domain `/continuum/*` gets a 301 (path and query kept), written only once the host has a certificate. A rejected `nginx -t` rolls back. `install-continuum.sh` now includes `/opt/torii/nginx-snippets/continuum-headers*.inc` in its four locations (the glob matches nothing without the host) and drops a redundant `expires 30d` that sent a second Cache-Control. Headers: HSTS, nosniff, `frame-ancestors 'none'` + `X-Frame-Options: DENY`, and microphone only for the Teams origin. `bootstrap.sh` exports `CONTINUUM_HOST`, which the v0.9.30 Teams installer reads. Continuum needs no change (sign-in does not bind to the origin). Tests: contract 27/27, live nginx 26/26.

**Update-All checklist.** Code + tests [done] installer, lib, bootstrap stage, 2 tests, CI workflow; version [done] `VERSION` + README; `.env.example` [done]; docs [done] `docs/CONTINUUM-HOST.md`, `docs/TEAMS.md`; continuity [done] todo, progress, handoff, strategy decision log (ADR); deploy [pending] owner-approved, runs from the tag.

## Release v0.9.30-alpha: Teams inside Continuum (2026-11-04)

Owner request "do all the things" (Teams MVP inside continuum.<domain>). torii-teams PR #7 (411c435) gave the per-project sidebar and Continuum member sign-in (ADR 0002), released as `0.6.1-torii.2`: SHA-256 `951a9379b2a2a73300bf4b95dcff11e33468a3c3ee7879851f3af86f695fdb90`, MANIFEST commit 411c435, attestation present. The Suite now pins it. `teams_csp` takes frame hosts, so Continuum's Team view iframe is allowed only from `https://$CONTINUUM_HOST` (when set) and `https://<domain>`, and only when Continuum is installed; otherwise it is `'none'`. `X-Frame-Options` was removed because frame-ancestors governs. `teams_node_json` takes the Continuum host. Tests: `install-teams-app.test.sh` 44/44, and `teams-app-live.sh` 16/16 with both the fake build and the real 0.6.1-torii.2 tarball (one first run failed on the headers check and passed on every rerun; nginx state from an earlier run is the likely cause). Not deployed.

**Update-All checklist.** Code + tests [done] lib, installer, 6 new checks, live test; version [done] `VERSION` + README; `.env.example` [done]; docs [done] `docs/TEAMS.md`; continuity [done] todo, progress, handoff; ADR [done] in torii-teams (ADR 0002); deploy [skipped] awaits owner approval and the FIPS-trial teardown answer.

## Roadmap: FIPS on by default (2026-11-04, docs only)

High-priority item added after the Teams MVP: FIPS on by default across Plebeian, Quest, Continuum and the marketplace. Each app gets an ADR first; the market needs owner approval.

## Release v0.9.29-alpha: first Torii Teams release pinned (2026-10-31)

Owner approved the first torii-teams tag. `0.6.1-torii.1` (d2a2f22) built in `torii-release.yml`: tarball, `.sha256`, `MANIFEST.json`, build-provenance attestation. The download matched its checksum, carried no `.well-known`, `_headers`, `_redirects` or `torii-node.json`, and passed `test/teams-app-live.sh` 16/16. `install-teams-app.sh` now pins its tag and SHA-256 `8f7ae47641784511...`.

**Update-All checklist.** Code + tests [done] installer pin, 2 new contract checks; version [done] `VERSION` + README; `.env.example` [done]; docs [done] `docs/TEAMS.md`; continuity [done] todo, progress, handoff; strategy [skipped] unchanged; ADR [skipped] no behaviour change.

## Release v0.9.28-alpha: Team view link setting (2026-10-31)

Requested by the Continuum Teams session for the "TEAMS-2a Team view link". `install-teams-app.sh` now writes `teams.app_url: "https://teams.<domain>"` into the Continuum agent config in the same step as `cors_origins` (new `teams_continuum_config` in `lib/teams-app.sh`), and restarts the agent only when something changed. Tested on Continuum's real `config.example.yaml` and on existing `teams:` blocks; YAML stays valid and the edit is idempotent.

**Update-All checklist.** Code + tests [done] `lib/teams-app.sh`, `installers/install-teams-app.sh`, `test/install-teams-app.test.sh` (36); version [done] `VERSION` + README; docs [done] `docs/TEAMS.md`; continuity [done] todo, progress, handoff; `.env.example` [skipped] no new setting; strategy [skipped] unchanged; ADR [skipped] covered by torii-teams ADR 0001 and Continuum's own PR.

## Release v0.9.27-alpha: Torii Teams app installer (2026-10-31)

TEAMS-2c part (a), agreed with the Continuum Teams session. `installers/install-teams-app.sh` (opt-in, needs the Teams services) installs the torii-teams web build on its own origin, `teams.<domain>`, and writes `/torii-node.json` with the node's coordinator and relay so the app needs no setup. The release checksum is pinned in the installer, not read from the release. The Content-Security-Policy is derived from each build's inline scripts; a real Cordn build ran under it in headless Chromium with no violations and picked up the node coordinator. Upstream Cordn's `.well-known` files are dropped so a node never claims Cordn's NIP-05 names. No release is pinned yet: the first torii-teams tag needs owner approval.

**Update-All checklist.** Code + tests [done] `installers/install-teams-app.sh`, `lib/teams-app.sh`, `bootstrap.sh`, `test/install-teams-app.test.sh`, `test/teams-app-live.sh`, `.github/workflows/teams-app.yml`; version [done] `VERSION` + README; `.env.example` [done]; docs [done] `docs/TEAMS.md`; continuity [done] todo, progress, handoff; strategy [skipped] unchanged; ADR [done] torii-teams `docs/torii/adr-0001-node-mount.md`.

## Release v0.9.26-alpha: Torii Teams services (2026-10-31)

TEAMS-2b packaging. The owner chose public chat and mesh-only git. Cordn's coordinator reuses the node's strfry (members connect at `wss://relay.<domain>`), with its key generated on the node and handed over as a systemd credential. ngit-grasp runs in private mode on the FIPS address only, behind a per-device allow list in a new `members` firewall chain. ngit-grasp has no binary release, so a Suite workflow builds it at the pinned commit and publishes checksummed, attested assets; the VPS never compiles. FIPS moves to v0.5.3 (the trial's version); the rendered config was checked against the 0.5.3 daemon. Daily backups stop both services briefly for a consistent snapshot.

**Update-All checklist.** Code + tests [done] `installers/install-teams.sh`, `teams/*`, `fips/mesh.nft`, `installers/install-fips.sh`, `bootstrap.sh`, `test/install-teams.test.sh`, `.github/workflows/teams-{deps,build}.yml`; version [done] `VERSION` + README changelog; `.env.example` [done]; docs [done] `docs/TEAMS.md`, `docs/FIPS.md`; continuity [done] todo, progress, handoff; strategy [skipped] unchanged; ADR [done] Continuum `adr-team-collaboration.md` addendum.

## Release v0.9.25-alpha: Quest security policy on nginx (2026-10-26)

The operator approved enabling Quest's Content-Security-Policy on chiefmonkey.art. Before this, the game page and world links sent only `Cache-Control`: Quest's nested nginx locations declared their own `add_header`, which drops torii-base's server-level security headers, and no CSP was sent at all. `install-quest.sh` now validates the build's `dist/csp.nginx.conf`, copies it to a stable snippet path on every deploy, and includes it on the game document only; the four security headers are restored on the index, assets and worlds locations. `torii reload` already runs `nginx -t` before reloading, so a bad config never replaces a good one. 49 checks pass, including a real nginx 1.28.3 (the VPS version) serving the generated fragment with the real Quest v0.2.935 build. `QUEST_CSP_ENFORCE=0` opts out.

**Update-All checklist.** Code + tests [done] `lib/quest-headers.sh`, `installers/install-quest.sh`, `test/install-quest-csp.test.sh`; version [done] `VERSION` + README changelog; `.env.example` [done]; continuity [done] todo, progress, handoff; strategy [skipped] deployment strategy unchanged; ADR [n/a] the decision lives in Quest ADR-0149.


The operator approved paired merge/tag/primary-VPS rollout on 24 September 2026. Seventeen local installer-contract checks and all existing Suite scripts pass. The [Ubuntu install/rerun proof](https://github.com/ChiefmonkeyArt/torii-suite/actions/runs/36028624132) verifies stable identity, running services and valid firewall rules; Quest's real two-node proof also passes. Pair with Quest v0.2.889-alpha / ADR-0126 and verify main/tag/live equality. The Project deployment receipt records the actual live result; cross-operator enrollment and long-soak/player acceptance remain separate.

**Repo:** https://github.com/ChiefmonkeyArt/torii-suite
Current release: v0.9.25-alpha. Merge/tag status and live source commit must be checked against the deployment receipt rather than inferred from this version label.

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

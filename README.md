# torii-suite

**One VPS. One domain. Continuum + Quest + Ollama + Plebeian, side by side.**

## Install in one line

On a fresh Ubuntu 22.04 / 24.04 / 26.04 VPS, as root:

```bash
curl -fsSL https://raw.githubusercontent.com/ChiefmonkeyArt/torii-suite/v0.6.7-alpha/bootstrap.sh | sudo bash
```

The installer will show you the Torii banner, ask three questions (domain,
Let's Encrypt email, admin npub), preflight the host (Ubuntu version, root,
DNS `A` record, ports 80/443 free), then install everything with a live
progress meter and print a summary card. No `.env` file to edit.

What you'll see (roughly):

```
   ______              _ _
  /_  __/___  _____   (_|_)
   / / / __ \/ ___/  / / /
  / / / /_/ / /     / / /
 /_/  \____/_/     /_/_/
     s u i t e   v0.3.0-alpha

  one vps  ·  one domain  ·  a gateway to a
  decentralised open world of infinite possibilities

──  Preflight
  ✓ Ubuntu 24.04
  ✓ port 80 free
  ✓ port 443 free
  ✓ DNS: torii.example.com → 203.0.113.10

──  Setup
  → Domain (e.g. torii.example.com): torii.example.com
  → Email for Let's Encrypt: you@example.com
  → Your admin npub (starts with npub1): npub1…

[3/7]  ████████░░░░░░░░░░░░  Ollama (local LLM fallback)

  ✓ install Ollama + pull llama3.2:3b  (4m18s)
  → measuring Ollama throughput on this host…
  ✓ Ollama benchmark: 2.34 tok/s (llama3.2:3b)
```

Every stage's stdout streams to `/var/log/torii-suite/install-<timestamp>.log`
so the terminal stays calm. On failure, the last 10 log lines print inline
plus the full log path — no second SSH session needed to debug. Set
`SUITE_QUIET=0` to stream everything to the terminal instead.

> **You need before you start:** a domain with a single `A` record pointing at
> your VPS's public IP, an email address for Let's Encrypt, and a **NIP-07
> signer** (Plebeian Signer, nos2x, or similar) so you can hand the installer
> your `npub`. **Never** hand it an `nsec` — the VPS doesn't sign anything.

---

## What you get

`torii-suite` is a meta-installer. It composes the individual Torii apps into
a single deployment on a fresh Ubuntu VPS:

```
https://your-domain.com/                — Torii launcher
https://your-domain.com/continuum/      — Continuum (AI-powered app builder)
https://your-domain.com/agent/          — Continuum agent (Fastify, proxied)
https://your-domain.com/quest/          — Torii Quest (3D open-world game)
https://your-domain.com/plebeian/       — Plebeian Market (external tile)
wss://your-domain.com/relay             — sovereign Nostr relay (strfry)
https://your-domain.com/git/            — read-only git mirror host (NIP-34)
```

Continuum also gets a **local Ollama daemon** on `127.0.0.1:11434` as an LLM
fallback for when Routstr is unreachable or out of ecash. It runs the 3B
`llama3.2` model by default — usable as a fallback on a CPU-only VPS (1–5 tok/s),
not a daily driver. See [Ollama daily-driver notes](#ollama-a-fallback-not-a-daily-driver).

Everything is opt-in. Install only Continuum if that's all you want. Add Quest
later by re-running the installer with `INSTALL_QUEST=1`.

---

## Repo layout

```
torii-suite/
├── VERSION                       # e.g. 0.1.0-alpha — bump on every change
├── bootstrap.sh                  # the one-command entrypoint
├── .env.example                  # env contract (copy to .env)
├── installers/
│   ├── install-continuum.sh      # frontend + agent + systemd + nginx fragment
│   ├── install-ollama.sh         # local LLM daemon (loopback, systemd-managed)
│   ├── install-quest.sh          # static bundle at /quest/ + nginx fragment
│   ├── install-nostr-git.sh      # strfry relay + read-only git smart-HTTP host
│   ├── register-plebeian.sh      # launcher tile only (Plebeian is external)
│   └── install-bridges.sh        # onboarding bridges: cors-proxy + webssh
├── onboarding/
│   └── prototype.html            # non-coder onboarding wireframe (browser-side)
├── bridges/                      # onboarding infra (opt-in, off by default)
│   ├── cors-proxy/               # zero-dep allowlisted HTTP forwarder
│   └── webssh/                   # WebSocket-to-SSH bridge (ws + ssh2)
├── docs/
│   ├── HOSTING.md                # BYO VPS vs SHC vs any-other-provider
│   └── ONBOARDING_ARCHITECTURE.md  # ephemeral browser-side design
└── LICENSE                       # MIT
```

---

## Install options

### A. One-liner (recommended for non-coders)

```bash
curl -fsSL https://raw.githubusercontent.com/ChiefmonkeyArt/torii-suite/v0.6.7-alpha/bootstrap.sh | sudo bash
```

The installer clones itself to `/opt/torii-suite/checkout/`, asks three
questions, writes your answers to `.env` (mode `0600`), preflights the host,
and runs. Re-run the same command later to update — it detects the existing
`.env` and skips the prompts.

### B. Manual (for operators who want to edit `.env` by hand)

```bash
# 1. SSH into your VPS as root (or a passwordless-sudo user):
git clone https://github.com/ChiefmonkeyArt/torii-suite.git
cd torii-suite

# 2. Copy the env template and fill in the three required fields:
cp .env.example .env
nano .env
#   TORII_DOMAIN=torii.example.com
#   LETSENCRYPT_EMAIL=you@example.com
#   CONTINUUM_ADMIN_NPUB=npub1yourpubkeyhere…

# 3. Run:
sudo -E ./bootstrap.sh
```

Either way, in roughly 10–20 minutes on a small VPS you'll have the full suite
running behind a Let's Encrypt certificate (add ~5–10 minutes on first install
while Ollama pulls the 2GB model).

---

## What the bootstrap does

Seven stages, each idempotent (safe to re-run):

1. **torii-base** — clones and runs [torii-base](https://github.com/ChiefmonkeyArt/torii-base)'s
   own `bootstrap.sh`, which installs nginx, certbot, node@22, the launcher
   at `/`, and the `torii-base-sidecar` systemd service that owns the app
   registry at `/opt/torii/registry.json`.
2. **Continuum** — clones torii-continuum, builds the SPA with `base=/continuum/`,
   snapshots it into `/var/www/torii/continuum-releases/<stamp>/`, atomically
   flips `/var/www/torii/continuum` to the new release, installs the Fastify
   agent under the `continuum` system user at `/home/continuum/agent/repo/`,
   generates a session secret, writes `continuum-agent.service`, and drops an
   nginx fragment that mounts `/continuum/` (static) and `/agent/` (proxy).
2b. **Ollama** *(opt-in, on by default when Continuum is installed)* — installs
   the official Ollama daemon, writes a systemd override binding it to
   `127.0.0.1:11434` with `OLLAMA_ORIGINS` restricted to localhost, pulls the
   default model (`llama3.2:3b`, ~2 GB), and flips `ollama.enabled: true` in
   the Continuum agent config. The agent's model router keeps Routstr as first
   choice — Ollama is only used when Routstr is unavailable.
3. **Quest** — clones torii-quest, patches `vite.config.js` for a `/quest/`
   base path (see [`docs/HOSTING.md`](docs/HOSTING.md) §Quest sub-path), builds,
   snapshots into `/var/www/torii/quest-releases/<stamp>/`, atomically flips
   the symlink, drops an nginx fragment.
4. **Plebeian** — registers a launcher tile that opens
   `$PLEBEIAN_EXTERNAL_URL` (default `https://plebeian.market`). No install,
   no nginx fragment — Plebeian is a hosted external service.
5. **Onboarding bridges** *(opt-in, `INSTALL_ONBOARDING_BRIDGES=1`)* — installs
   the CORS proxy and WebSSH bridge under `torii-bridges` with hardened
   systemd units, drops an nginx fragment mounting `/cors-proxy/` and
   `/webssh`, and registers a `bridges` tile. Both refuse to start on an
   empty allowlist. See [`bridges/README.md`](bridges/README.md).
6. **Doctor** — runs `torii status` and `torii doctor` from torii-base to
   verify every app registered, its nginx fragment loads, and (for Continuum)
   the agent is reachable, Routstr is up, and the Cashu wallet directory
   exists.

Everything is atomic-symlink deployed. The last 3 releases of each app are
retained under `<app>-releases/` for rollback via `ln -sfn`.

---

## Signing in for the first time

Continuum has no username, no password, no email recovery link. Your
**Nostr npub is the identity** and a **NIP-07 signer** is how you prove
it. If you gave a fresh domain to `bootstrap.sh` you already declared
the one npub the agent will accept.

### 1. Install a NIP-07 signer

Any NIP-07 browser signer works. Recommended:

- **Plebeian Signer** (Chrome / Firefox) — built by us, small surface area
- Alternatives: `nos2x`, Alby (browser), Amber (Android via WebView)

Search "Plebeian Signer" on the Chrome Web Store or on
addons.mozilla.org, install, then unlock it with your existing nsec (or
create one from inside the signer if you're new to Nostr).

### 2. Note your npub

Open the signer, copy the `npub1...` string. **Never copy the nsec.**
The VPS is never allowed to see your private key — that's the whole
point of NIP-07.

### 3. Visit your Torii domain

Open `https://<your-domain>/continuum/` in the same browser that has the
signer installed. Click **Sign in with Nostr**.

The flow:

1. Continuum agent hands you a random challenge (48 hex chars, 5-min TTL).
2. Your signer wraps it in a kind-22242 event and signs it.
3. Agent verifies signature, checks pubkey matches `admin_npub`, issues an
   HMAC-signed session token that lasts `session_ttl_sec` (default 24h).
4. Browser stores the token in `localStorage` and fires `session-changed`.

You are now logged in. Signer approval popup only appears once per
challenge — not per request.

### 4. Troubleshooting

| Symptom                              | Cause                                                        | Fix                                                                                     |
| ------------------------------------ | ------------------------------------------------------------ | --------------------------------------------------------------------------------------- |
| "No NIP-07 signer detected"          | Extension not installed or disabled in this browser profile  | Install Plebeian Signer, reload the page                                                |
| Signer popup never appears           | Extension permissions blocked on your domain                 | Extension settings → allow on `https://<your-domain>`                                   |
| "pubkey is not admin npub"           | You're signing with a different key than `CONTINUUM_ADMIN_NPUB` | Switch signer identity, or rotate the admin npub: `sudo bash /opt/torii-suite/installers/set-admin-npub.sh npub1...` |
| "challenge expired"                  | You took > 5 minutes to approve the popup                    | Click **Sign in with Nostr** again — a fresh challenge is issued                        |
| Cross-origin (CORS) error in console | Your domain isn't in `cors_origins` of `agent/config.yaml`   | Re-run `install-continuum.sh`, or edit the config and `systemctl restart continuum-agent.service` |
| Signed in yesterday, session gone    | Token expired at `session_ttl_sec` (default 24h)             | Sign in again; shorten TTL in `.env` if that felt too long                              |

### 5. Key hygiene

- **Lost your signer?** `sudo bash /opt/torii-suite/installers/set-admin-npub.sh npub1<new>` on the VPS to swap identity.
- **Suspect a token was leaked?** `sudo bash /opt/torii-suite/installers/rotate-session-secret.sh` — every open session dies at the next request.
- **Both at once?** Run `set-admin-npub.sh` first, `rotate-session-secret.sh` immediately after.

See [`.env.example`](.env.example) for `CONTINUUM_SESSION_TTL_SEC` if you
want tokens shorter than 24 hours.

---

## Environment variables

See [`.env.example`](.env.example) for the full contract. The three required
values:

| Variable                | What                                                         |
| ----------------------- | ------------------------------------------------------------ |
| `TORII_DOMAIN`          | FQDN with a single `A` record pointing at this VPS           |
| `LETSENCRYPT_EMAIL`     | Account email for the Let's Encrypt registration            |
| `CONTINUUM_ADMIN_NPUB`  | Your npub (bech32). **Never an nsec** — the VPS doesn't sign |

Everything else has a sensible default (see the file for opt-ins, ref pins,
port overrides, staging mode).

### New in v0.8.1-alpha

Bumps `TORII_BASE_REF` from `v0.1.1` to `v0.1.4`. Fixes the `duplicate
location "/" in .../torii.conf` nginx error that aborted the `[1/7] torii-base`
stage on reinstall over an existing box. Root cause: `torii-base` v0.1.1's
`torii.conf` declares its own `location = /` launcher fallback *and* includes
`root_app.conf`; once the sidecar had written a `location = /` into
`root_app.conf` (normal after any `set-root` / homepage activation), the two
exact-match blocks collided and `nginx -t` failed. v0.1.4 drops the fallback
from `torii.conf` (making `root_app.conf` the single owner of `/`) and its
bootstrap reconciles a stale `root_app.conf` into a valid block before the
nginx reload. v0.1.4 retains the v0.1.1 passwordless-sudo shim the sidecar
needs to reload nginx, so `torii register` still works.

### New in v0.8.0-alpha

Adds sovereign Nostr git-mirror infrastructure as a new opt-in stage
(`INSTALL_NOSTR_GIT=1`, on by default). The VPS now runs its own Nostr relay
and a read-only git smart-HTTP host on the shared domain:

- **strfry relay** at `wss://your-domain/relay` — built from a pinned source
  tag (`STRFRY_REF=1.1.0`). strfry publishes no prebuilt release binaries, so
  the stage compiles the binary itself from reviewed source (no opaque blob
  to trust). Loopback-bound behind nginx; the build is skipped on re-run when
  the binary already exists at the pinned tag.
- **git host** at `https://your-domain/git/` — git smart-HTTP via fcgiwrap +
  `git-http-backend`, serving bare repos from `/opt/torii/git`. Read-only by
  design: fetch/clone is allowed, push (`service=git-receive-pack`) is blocked
  at nginx (403), with per-repo `http.receivepack=false` as belt-and-braces.

Keyless by design — the VPS holds no nsec and signs nothing. This stage only
provisions empty infra (`/opt/torii/git` + a running relay); Continuum
(slice `CONT-NIP34-MIRROR-1`) populates it with browser-signed `kind:30617`
NIP-34 repos via your NIP-07 signer. New env vars: `INSTALL_NOSTR_GIT`,
`NOSTR_RELAY_PORT`, `NOSTR_RELAY_DB`, `GIT_HOST_ROOT`, `NOSTR_PUBLIC_RELAYS`,
`STRFRY_REF`. The bootstrap summary card now reports `RELAY_SMOKE_RESULT`
(strfry NIP-11 probe) and `GIT_SMOKE_RESULT` (git-http-backend fetch probe).

Note: strfry is [GPLv3](https://github.com/hoytech/strfry/blob/master/LICENSE);
the suite itself remains MIT. Building strfry pulls in the usual C++ build
deps (`g++ make libssl-dev zlib1g-dev liblmdb-dev libflatbuffers-dev
libsecp256k1-dev libzstd-dev`) on first run.

### New in v0.7.21-alpha

Fixes an `Update Now` deploy regression where `install-quest.sh` aborted at
`git checkout` with "Your local changes to the following files would be
overwritten: public/dashboard.html, public/torii-quest-data.json". The Quest
build rewrites those generated artifacts every deploy; the dirty work tree left
behind then blocked the next tag's checkout (surfaced first when deploying
`v0.2.402-alpha`). `install-quest.sh` now `reset --hard`s tracked modifications
(`node_modules` is untracked, so it is preserved) and strips the two generated
artifacts before checkout, so a dirty work tree can never block a redeploy.
No Quest change required — `v0.2.402-alpha` deploys cleanly once the suite
checkout pulls this fix.

### New in v0.7.20-alpha

Bumps the stale `TORII_CONTINUUM_REF` pin (`v0.2.14-alpha` → `v0.2.29-alpha`).
`v0.2.29-alpha` is the deployed/known-good Continuum server version (running on
the VPS on Node 22), so it is the strongest install-compatible signal available.
Newer tags (`v0.2.32`–`v0.2.45-alpha`) exist on GitHub but are not yet
deployed/verified-for-install — bump further only after testing one.

### New in v0.7.19-alpha

Documents the adoption step for the v0.7.17-hardened Quest update runner: a
`## Updating` note with the one-line `install -m 0755` command to swap a live VPS
onto the hardened checkout (so `Update Now` resolves the latest tag from a local
branch, never a detached HEAD). Does NOT bump the stale `TORII_CONTINUUM_REF` pin
(`v0.2.14-alpha`) — that needs a confirmed install-compatible tag first (latest
is `v0.2.45-alpha`; the deployed/known-good server version is `v0.2.29-alpha`).

### New in v0.7.18-alpha

Applies the same detached-HEAD hardening (shipped for Quest in v0.7.17) to
`install-continuum.sh`. Both of its source-sync blocks — the frontend checkout and
the agent-repo checkout — replace the fragile `git checkout <tag>` +
`git pull --ff-only origin <tag>` (pulling a tag into a detached HEAD, failures
masked by `|| true`) with `git checkout -B torii-continuum-deploy <tag>` +
`git reset --hard <tag>` — idempotent and always on a local branch, never detached.
No behaviour change for clean installs.

### New in v0.7.17-alpha

Hardens the Quest deploy checkout against detached-HEAD. `install-quest.sh` is now
the single Quest source-sync authority: its update branch replaces the fragile
`git checkout <tag>` + `git pull --ff-only origin <tag>` (a semantically-wrong
"pull a tag into a detached HEAD", masked by `|| true`) with
`git checkout -B torii-quest-deploy <tag>` + `git reset --hard <tag>` — idempotent
and always on a local branch, never a detached HEAD. The auto-update runner drops
its now-redundant quest fetch/reset/checkout (it still pulls the Suite checkout,
which safely tracks a branch, sources `.env`, and calls `install-quest.sh`).
Pins `TORII_QUEST_REF` default `v0.2.387-alpha` -> `v0.2.397-alpha`.

### New in v0.7.16-alpha

Quest auto-update infrastructure. `QUEST_ADMIN_NPUB` (defaults to
`CONTINUUM_ADMIN_NPUB`) gates a new in-game "Update Now" button (Quest v0.2.387)
that reinstalls the latest published tag from a browser click. arena-ws (hardened,
no sudo) cannot run the installer itself, so install-quest.sh now also installs:
  * `/opt/torii-quest/mp/update-requests/` (root:torii-quest 0770)
  * `/usr/local/sbin/torii-quest-update-runner` (root, flock single-flight)
  * `torii-quest-update.path` + `torii-quest-update.service` (root oneshot)
The runner resolves the latest tag ITSELF (`git ls-remote --tags`), validates it
against an allowlist regex, and runs the FIXED deploy (`git pull` + `install-quest.sh`).
It never reads a requested ref from the request file, so a compromised admin session
cannot pin an arbitrary tag. nginx gains `/mp/admin/update{,-status,-capability}`.
Also pins `TORII_QUEST_REF=v0.2.387-alpha` (tags-based update check + admin UI + endpoint).

### New in v0.7.15-alpha

`TORII_QUEST_REF` default: `v0.2.385-alpha` -> `v0.2.386-alpha`. Quest combat-feel
fix: Augustink boss render scale 2.5m -> 2.0m (~1.2x the player; combat stats
unchanged), and the bot hit capsule widened ~15% (body radius 0.26->0.30, head
0.20->0.23) in server<->client parity so shots that visually hit the body
register. No change to BOT_HP/damage/the v0.2.383 event-authoritative fix/the
v0.2.385 lag-comp. 2480 tests passing.

### New in v0.7.14-alpha

`TORII_QUEST_REF` default: `v0.2.384-alpha` -> `v0.2.385-alpha`. Quest adds
**bot lag-compensation** for player→bot shots. Player→peer combat already rewound
peers to the shot timestamp; player→bot did not, so the server tested the player's
ray against the bots' current positions while the client rendered each bot ~100ms
in the past — moving bots ate missed shots ("takes more than 2 body / 1 head").
A new `server/bots/botSnapshotRing.js` records bot positions per sim tick;
`arenaBotSim.resolvePlayerShot` now rewinds bots to the shot ts (clamped like the
peer path) before ray-testing, so hits land where the player aimed. No
BOT_HP/BODY/HEADSHOT/BOSS stats, hit zones, damageTable, or the v0.2.383
event-authoritative fix touched. Also bundled: ENTER NAP ZONE button recoloured
orange, torii-gate logo bottom-aligned with the title text, and the centre-card
title shrunk to fit one line. 2480 tests passing.

### New in v0.7.13-alpha

`TORII_QUEST_REF` default: `v0.2.383-alpha` -> `v0.2.384-alpha`. Quest ships a
UI / leaderboard / stats truth pass (combat path untouched):
- Augustink boss render scale 3.2m -> 2.5m (~1.5× the player); combat stats unchanged.
- Leaderboard title de-mocked (`SCORE — LEADERBOARD`, no `3 ·` prefix); mock rows
  removed; honest empty/loading state when no local data.
- LOCAL board now keeps disconnected players on the tally (`scoreLedger.retire()` +
  reconnect-rekey, no double-count) until the arena-ws process restarts.
- Personal stats panel + homescreen preview wired to the same authoritative score
  ledger via a new `EV.SCORE_FRAME` (single-player byte-identical).
- LOGIN button is now a solid mint/green primary CTA.
- Lightning-bolt title logo replaced with an inline torii-gate + bolt SVG in both
  homescreen title spots. 2466 tests passing.

### New in v0.7.12-alpha

`TORII_QUEST_REF` default: `v0.2.382-alpha` -> `v0.2.383-alpha`. Quest fixes the
player→bot combat regression (shots not registering / bots not dying / headshots
not working). The server was resolving hits correctly (confirmed via the
`[SHOT-RESOLVE]` log); the bug was client-side — `applyBotHit`/`applyBotKill`
updated the bot's sim state but not `botNetState`'s internal `b.hp`/`b.alive`, so
the next render frame re-read the stale ~15Hz `BOT_STATE` snapshot and reverted
the event for up to ~67ms (HP snapped back to full, killed bots flickered
alive). `applyBotHit`/`applyKill` now fold the authoritative event into
`botNetState` before the render path samples. Position interpolation unchanged;
single-player byte-identical; bot→player combat unchanged; boss takes damage the
same way. 8 new race tests + 7 v0.2.382 regression tests green.

### New in v0.7.11-alpha

`TORII_QUEST_REF` default: `v0.2.381-alpha` -> `v0.2.382-alpha`. Quest ships a
**diagnostic-only** combat build: the server-side `[SHOT-RESOLVE]` log (≤1/sec per
shooter) is enriched with `originY` / `nearBot` / `botFootY` / `dy` so a live
playtest where player→bot damage fails to register can be triaged from
`journalctl -u torii-arena-ws | grep SHOT-RESOLVE`. Headless `resolvePlayerShot`
correctly HITS torso + head for regular AND boss bots in every realistic
scenario, so no speculative geometry fix was shipped — the live miss is a
runtime/input/wire issue to be pinned from the log. Adds 7 player→bot combat
regression tests. No gameplay/protocol change.

### New in v0.7.10-alpha

`TORII_QUEST_REF` default: `v0.2.380-alpha` -> `v0.2.381-alpha`. Quest restores
the **Augustink boss bot** as a server-authoritative archetype on the existing
bot roster: per-bot stats (HP 60, speed 1.0, damage 14, radius 0.8, named
"Augustink", `kind`/`name`/`scale` in the additive BOT_STATE snapshot). One boss
spawns per arena alongside the regular bots, syncs across all players, and
renders with the lazy-loaded `augustink4.glb` model (~3.2 m) + a nameplate +
full-rate death anim. Single-player byte-identical except the boss is present.
`PROTOCOL_VERSION` unchanged. The GLB ships uncompressed (7.9 MB, lazy-loaded
via the existing cache-on-use handler — not precached); Draco compression was
deferred (unverifiable headlessly).

### New in v0.7.9-alpha

`TORII_QUEST_REF` default: `v0.2.378-alpha` -> `v0.2.380-alpha`. Quest ships
two changes:

- **v0.2.379-alpha (performance):** main renderer DPR cap lowered 2 -> 1.5
  (matches the existing mirror cap; ~44% fewer pixels on Retina), plus an
  adaptive quality tier (HIGH/NORMAL/LOW) that drops DPR and disables the
  UnrealBloom postprocessing pass on sustained frame drops and recovers when
  smooth — auto-tunes to the player's GPU. A debug perf HUD is available
  behind `window.__toriiPerf`. Render-only; single-player gameplay unchanged.
- **v0.2.380-alpha (live leaderboard):** the in-arena leaderboard is now wired
  end-to-end. The server broadcasts the `SCORE` frame during play (on kill + a
  ~5s tick) so clients see real-time server-authoritative tallies; the client
  mounts a toggleable (L / Tab) leaderboard overlay whose LOCAL tab is the
  default view (0 signer prompts, works with no Nostr login). The existing
  `PUBLISH MY SCORE` button is reachable from the panel (opt-in, one NIP-07
  sign on click, never auto), and a GLOBAL tab reads signed score events back
  from a relay (read-only, graceful empty/offline cache). Additive on
  PROTOCOL_VERSION=1; no new in-game signer prompts beyond the explicit publish
  click.

### New in v0.7.8-alpha

`TORII_QUEST_REF` default: `v0.2.377-alpha` -> `v0.2.378-alpha`. Quest
hotfix: forces authoritative MP mode (advisory retired — fixes player/bot hits
not registering when a stale .env had MP_MODE=advisory), lifts the bot shot
origin to world frame (fixes bot→player misses), and adds bot targeting
hysteresis (bots re-acquire a closer player).

### New in v0.7.7-alpha

`TORII_QUEST_REF` default: `v0.2.375-alpha` -> `v0.2.377-alpha`. Quest
ships server-authoritative bots (v0.2.377-alpha): the arena server runs
the bot AI on a fixed tick against the live player roster and broadcasts
bot state + shots; clients render-only in MP. Bots now move + attack
identically on every screen.

### New in v0.7.6-alpha

`TORII_QUEST_REF` default: `v0.2.374-alpha` -> `v0.2.375-alpha`. Quest moved
arena auth from a per-session NIP-42 challenge (which re-prompted the Nostr
signer on every arena entry and reconnect) to a one-time login sign that
mints a server-issued session token. The arena WebSocket now reuses that
token — **1 signer prompt at login, 0 in-game**.

The `/mp` nginx fragment gained two plain-HTTP endpoints for that login
handshake (`GET /mp/auth-challenge`, `POST /mp/session`). Because these
fragments live inside a `server{}` block (where a `map` directive is
illegal), the fragment splits `/mp` by path: exact-match HTTP locations for
the auth endpoints and the existing Upgrade proxy for the arena socket.

### New in v0.7.1-alpha

`TORII_QUEST_REF` default: `v0.2.369-alpha` -> `v0.2.374-alpha`. The live
Suite-hosted Quest froze after **ENTER ARENA** because the pinned entry URL
had lost its `/quest/` base, so the arena bundle 404'd under the mount.
Quest v0.2.374-alpha restores the base-prefixed entry URL and passes the
real base-path browser regression. Fresh installs now enter the arena
cleanly with no overrides.

### New in v0.6.7-alpha

Cosmetic: Continuum's stage-banner strapline now reads "an AI-powered app
builder for Torii Quest, Plebeian, itself, and anything else you can think
of... it's not a cult", wrapped across three dim lines so it stays balanced
under the wordmark.

### New in v0.6.6-alpha

Fix: Plebeian tile registration failed because `register-plebeian.sh` never
wrote an nginx fragment, but the torii-base sidecar's `POST /torii/apps`
unconditionally requires one at `/opt/torii/nginx-fragments/<slug>.conf`.
External tiles now ship a tiny redirect fragment (`location = /plebeian/`
→ 302 to `$PLEBEIAN_EXTERNAL_URL`) so the sidecar accepts registration and
the launcher tile lights up. Same diff-and-write pattern as install-quest.sh.

Also, cosmetic install-flow polish:

- `bootstrap.sh` no longer asks about local vs. remote Ollama. Local is the
  default (sovereign LLM fallback). Set `OLLAMA_MODE=remote` +
  `OLLAMA_URL` in the env to point at an existing endpoint.
- Tightened the Torii ASCII wordmark (removed the double-i gap).
- Strapline: "one vps · one clanker · a gateway to a decentralised open
  world of infinite possibilities".
- Quest stage label "3D world" → "the federated metaverse".
- New per-stage ASCII banners for Continuum and Quest before their install
  steps kick in.
- Spinner glyph now cycles through the same pink/cyan ramp as the wordmark
  so the whole install reads as one coherent visual system.
- Finale line prints the strapline in a rainbow ramp after the summary card.
- Banners fade in line-by-line (~35ms/line). Set `UI_ANIM=0` to skip the
  animation for scripted / CI runs.

### New in v0.6.5-alpha

Fix: Quest install failed at the `npm install --omit=dev` step with
`EACCES /opt/torii-quest/.npm` when a previous install had created the
`torii-quest` system user and a later cleanup step removed `/opt/torii-quest`.
`useradd --create-home` no-ops on the second run (user already exists), so
the home dir was gone and the following `install -d /opt/torii-quest/mp`
recreated `/opt/torii-quest` as `root:root` instead of `torii-quest`.
Then `sudo -u torii-quest -H npm install` set `$HOME=/opt/torii-quest`
and npm blew up trying to write `.npm/`. Fix: explicit `install -d`
+ `chown` on `/opt/torii-quest` before touching `mp/`. Idempotent on
first-fresh installs.

### New in v0.6.4-alpha

Fix: `torii-arena-ws.service` (and `torii-cors-proxy.service`) were shipping
with `MemoryDenyWriteExecute=true` in their systemd units. V8's baseline JIT
needs `mprotect(PROT_WRITE|PROT_EXEC)` on code pages, which MDWE forbids;
Node core-dumped with `SIGTRAP` + errno 12 on startup and systemd bounced
the service in a restart loop. Dropped MDWE from both units; kept the rest
of the hardening stack. Verified live on Ubuntu 26.04.

### New in v0.6.3-alpha

Pins `TORII_BASE_REF` default `main` -> `v0.1.1`. torii-base v0.1.1 installs
`/etc/sudoers.d/torii-nginx` so the sidecar (running as the unprivileged
`torii` user) can `sudo -n nginx -t` + `sudo -n nginx -s reload`. Without
that, every `torii register` call from the app installers returned
`500 {"error":"nginx_reload_failed"}` and the `[2/6] Continuum` stage of a
fresh install died.

### New in v0.6.2-alpha

Fix: first-install of Continuum failed in v0.6.0-alpha and v0.6.1-alpha with
`mv: cannot overwrite directory '/var/www/torii/continuum' with non-directory
'/var/www/torii/continuum.new'`. `install-continuum.sh` pre-created
`/var/www/torii/continuum` as a real directory, then tried to replace it with
the atomic-flip symlink. Fix: only create the parent directory; migrate any
legacy real directory aside on re-run.

### New in v0.6.1-alpha

`TORII_QUEST_REF` default: `main` -> `v0.2.369-alpha` (the first Quest tag
carrying `server/arena-ws.js`). Full multiplayer stack now lights up on a
fresh install with no overrides.

### New in v0.6.0-alpha

Two opt-in slices added in this release:

| Variable                                    | What                                                                              |
| ------------------------------------------- | --------------------------------------------------------------------------------- |
| `CONTINUUM_RATE_LIMIT_ENABLED`              | `1` (default) enables per-IP rate limiting on `/api/auth/*`. Set `0` for dev only |
| `CONTINUUM_RATE_LIMIT_CHALLENGE_PER_MIN`    | Max `POST /api/auth/challenge` per IP per minute (default `10`)                   |
| `CONTINUUM_RATE_LIMIT_VERIFY_PER_MIN`       | Max `POST /api/auth/verify` per IP per minute (default `20`)                      |
| `CONTINUUM_RATE_LIMIT_MAX_CHALLENGES`       | Hard ceiling on pending in-memory challenges (default `1000`)                     |
| `INSTALL_ARENA_WS`                          | `1` (default) installs Quest's `arena-ws` multiplayer backend + `/mp` nginx proxy |
| `ARENA_WS_PORT`                             | Loopback port for `arena-ws` (default `8788`)                                     |
| `ARENA_WS_MODE`                             | `authoritative` (default) or `advisory` (rollback to MP-1 relay semantics)        |

When `INSTALL_ARENA_WS=1`, `install-quest.sh` builds Quest, brings up
`torii-arena-ws.service`, and adds a WebSocket-upgrade nginx block so
authenticated clients can dial `wss://<your-domain>/mp`.

---

## Hosting options

You have three paths from "I want a Torii" to a running VPS:

- **BYO VPS** — Namecheap, Hetzner, DigitalOcean, whatever. Fastest and cheapest
  if you already have a provider. Pay in fiat.
- **[Sovereign Hybrid Compute](https://sovereignhybridcompute.com)** — Bitcoin-billed
  VPS with npub-based agent delegation. If you want to buy compute with sats
  and never hand over a card, this is the intended fit.
- **Any other Ubuntu 22.04/24.04 VPS provider** — the installer only needs
  root and a domain. It doesn't care who bills you.

Full comparison and step-by-step recipes: [`docs/HOSTING.md`](docs/HOSTING.md).

---

## Non-coder onboarding

If you don't want to touch a terminal, `torii-suite` ships a
**7-tap browser-side onboarding flow** that provisions everything above from
your phone. Nothing but a Lightning invoice ever touches Torii servers — your
browser talks directly to your hosting provider's API.

Preview the wireframe at [`onboarding/prototype.html`](onboarding/prototype.html).

Trust boundary and rationale: [`docs/ONBOARDING_ARCHITECTURE.md`](docs/ONBOARDING_ARCHITECTURE.md).

The bridges the onboarding flow depends on live in this repo under
[`bridges/`](bridges/). As of v0.1.2 the **CORS proxy** and **WebSSH bridge**
are shipped and installable via `installers/install-bridges.sh` (off by
default — set `INSTALL_ONBOARDING_BRIDGES=1` and populate the two allowlists).
A third bridge for DNS zone control is planned for a later revision. Both
shipped bridges run on plain Linux + nginx + systemd — no Cloudflare, no
PaaS, no third-party infrastructure of any kind. Anyone can self-host the
full set on any VPS with root access.

---

## Ollama: a fallback, not a daily driver

Continuum defaults to **Routstr first, Ollama second**. Routstr calls out to
hosted models via a Nostr provider marketplace, paid per-request in Cashu —
fast and high-quality. When Routstr is unreachable or your wallet is empty,
the agent falls back to the local Ollama daemon this installer sets up.

On a CPU-only VPS the default `llama3.2:3b` model will produce roughly:

| Host                       | Approximate throughput             |
| -------------------------- | ---------------------------------- |
| 2 vCPU / 4 GB RAM VPS      | 1–3 tok/s — fallback only          |
| 8 vCPU / 16 GB RAM VPS     | 5–10 tok/s — workable for short prompts |
| RTX 3060 12 GB (desktop)   | 40–70 tok/s — daily-driver range   |
| RTX 4090 / A100            | 100+ tok/s                         |

### Remote Ollama endpoint

If you already run Ollama somewhere with real horsepower — a homelab GPU box,
a Tailscale/WireGuard LAN, a private VPS — the suite can skip the local
install and wire Continuum at your existing endpoint. Keep the public VPS
small, get daily-driver latency without paying VPS GPU rates.

During the interactive install, the fourth question is:

```
→ Ollama LLM fallback: [local] install here, or [remote] use existing? remote
→ Remote Ollama URL (e.g. http://10.0.0.5:11434 or https://ollama.example.com): http://ollama-box.tailnet.ts.net:11434
→ Auth header for remote endpoint (or blank if none): 
```

Or non-interactively via `.env`:

```
OLLAMA_MODE=remote
OLLAMA_URL=http://ollama-box.tailnet.ts.net:11434
OLLAMA_AUTH_HEADER=          # blank for LAN/Tailscale, or 'Authorization: Bearer sk-...'
```

What happens:

- **Preflight probe.** Before running any stages, bootstrap does
  `GET ${OLLAMA_URL}/api/tags` (5s timeout, with the auth header if you gave
  one). If it fails, install aborts with a clear message — no half-installed
  system to clean up.
- **Local install stage is skipped.** No systemd unit, no model pull, no
  loopback bind. The stage counter reflects this.
- **Continuum config is rewritten.** `agent/config.yaml` gets
  `ollama.enabled: true`, `ollama.host: <your URL>`, and (if provided)
  `ollama.auth_header: <your header>` — the file stays at mode 0600.
- **Live benchmark still runs** against the remote endpoint. The final
  summary card shows the measured tok/s you'll actually get.

Security notes:

- Plaintext `http://` to a public-looking host emits a warning — inference
  traffic is in the clear. RFC1918, loopback, Tailscale (`*.ts.net`,
  `100.64/10`), and `*.internal`/`*.lan`/`*.local`/`*.home` addresses are
  treated as private and don't warn. For public endpoints, use `https://`.
- The auth header is only useful for endpoints behind a reverse proxy that
  requires it (nginx `auth_basic`, oauth2-proxy, a bearer-token gateway).
  Vanilla Ollama has no auth of its own — don't expose it to the internet
  without one.

### Swapping local models

```bash
sudo -u root ollama pull qwen2.5:7b
sudo -u continuum sed -i 's|llama3.2:3b|qwen2.5:7b|g' /home/continuum/agent/repo/agent/config.yaml
sudo systemctl restart continuum-agent
```

---

## Nostr git-mirror infra

`INSTALL_NOSTR_GIT=1` (on by default) gives the VPS its own sovereign Nostr
relay and a read-only git mirror host. Both ride the shared torii-base domain.

| Surface | URL | What lives there |
| --- | --- | --- |
| Nostr relay | `wss://your-domain/relay` | strfry — the VPS's own Nostr ingress |
| Git host | `https://your-domain/git/` | read-only bare repos (NIP-34 `clone` targets) |

**strfry is built from source.** strfry publishes no prebuilt release binaries,
so the stage clones `hoytech/strfry` at the pinned `STRFRY_REF` tag, initialises
its golpe submodule, and compiles the binary itself. No opaque blob is
downloaded — you compile from reviewed source, which is the sovereign path.
The first build pulls in C++ build deps (`g++ make libssl-dev zlib1g-dev
liblmdb-dev libflatbuffers-dev libsecp256k1-dev libzstd-dev`) and takes a few
minutes; re-runs skip the build when the binary already exists at the pinned
tag. strfry is [GPLv3](https://github.com/hoytech/strfry/blob/master/LICENSE);
the suite itself stays MIT.

**The VPS is keyless.** It holds no `nsec` and signs nothing. The relay's NIP-11
identity carries no admin pubkey. This stage only provisions empty infra:
`/opt/torii/git` (the bare-repo store) plus a running strfry bound to loopback
behind nginx. Continuum (slice `CONT-NIP34-MIRROR-1`) populates the git store
with repos you publish from your NIP-07 browser signer (Plebeian Signer,
nos2x) via `kind:30617` NIP-34 events.

**Read-only by design.** The git host serves fetch/clone only. Push
(`service=git-receive-pack`) is blocked at nginx with `403`, and per-repo
`http.receivepack=false` is set by the mirror job as belt-and-braces. No one
— not even the operator — can push to the mirror over HTTP; repos are
populated by the on-box Continuum mirror job that writes the bare store
directly.

### Verifying it works

The bootstrap summary card reports two smokes:

- **`RELAY_SMOKE_RESULT`** — strfry answered a NIP-11 relay-info probe on
  loopback (`curl -H 'Accept: application/nostr+json' http://127.0.0.1:7777/`).
- **`GIT_SMOKE_RESULT`** — `git-http-backend` served a smart-HTTP
  `info/refs?service=git-upload-pack` advert for a throwaway repo under
  `/opt/torii/git`, and fcgiwrap is active so the nginx→fcgiwrap→backend route
  has a live adapter.

Once Continuum has published a repo, verify the public path end-to-end:

```bash
git clone https://your-domain/git/<repo>.git
# fetch works; push is rejected:
git push origin main            # -> 403 (service=git-receive-pack blocked)
```

And confirm the relay speaks Nostr from a client that supports custom relays
by adding `wss://your-domain/relay` to its relay list.

---

## Updating

Re-run the same one-liner (it re-clones and pulls the latest tag), or:

```bash
cd /opt/torii-suite/checkout   # or wherever you cloned it manually
git pull --ff-only
sudo -E ./bootstrap.sh
```

Every stage detects "already installed" and either pulls the newest ref, or
skips work when the resolved commit hasn't changed.

To pin a specific ref (useful for reproducible rollouts):

```bash
# In .env:
TORII_BASE_REF=main
TORII_CONTINUUM_REF=v0.2.10-alpha
TORII_QUEST_REF=v0.2.374-alpha
```

### Reinstall the hardened Quest update runner

If your VPS still runs the pre-v0.7.17 `/usr/local/sbin/torii-quest-update-runner`
(it works, but predates the detached-HEAD hardening), adopt the hardened
checkout at the terminal (root):

```bash
cd /opt/torii-suite/checkout        # or wherever you cloned it
git pull --ff-only
sudo install -m 0755 installers/torii-quest-update-runner.sh /usr/local/sbin/torii-quest-update-runner
```

The next `Update Now` cycle then resolves the latest tag from a local branch
(`torii-quest-deploy`), never a detached HEAD. No restart beyond that cycle.

---

## Uninstall

Suite v0.2.0 does not ship an uninstaller. To tear down:

```bash
sudo torii unregister continuum
sudo torii unregister quest
sudo torii unregister plebeian
sudo torii unregister bridges 2>/dev/null || true
sudo systemctl disable --now continuum-agent
sudo systemctl disable --now ollama 2>/dev/null || true
sudo systemctl disable --now torii-cors-proxy torii-webssh 2>/dev/null || true
sudo rm /etc/systemd/system/continuum-agent.service
sudo rm -f /etc/systemd/system/torii-cors-proxy.service /etc/systemd/system/torii-webssh.service
sudo rm -rf /etc/systemd/system/ollama.service.d
sudo rm /opt/torii/nginx-fragments/continuum.conf
sudo rm /opt/torii/nginx-fragments/quest.conf
sudo rm -f /opt/torii/nginx-fragments/bridges.conf
sudo rm -rf /var/www/torii/{continuum,continuum-releases,quest,quest-releases}
sudo rm -rf /home/continuum /opt/torii/bridges
sudo torii reload
```

To also remove Ollama and its models (frees ~2 GB per model):

```bash
sudo systemctl stop ollama
sudo rm -f /usr/local/bin/ollama
sudo rm -f /etc/systemd/system/ollama.service
sudo rm -rf /usr/share/ollama
sudo userdel ollama 2>/dev/null || true
```

To remove torii-base itself, follow the uninstall steps in the torii-base repo.

---

## Contributing

- Bump `VERSION` on **every** change, no exceptions (see project handoff docs).
- Every change goes to `main` via a PR.
- Do not commit device names, hostnames, or any local machine identifiers.
- Run `shellcheck --exclude=SC1091 bootstrap.sh installers/*.sh` before pushing.

---

## License

MIT — see [`LICENSE`](LICENSE).

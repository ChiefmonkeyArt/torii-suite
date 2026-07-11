# torii-suite

**One VPS. One domain. Continuum + Quest + Ollama + Plebeian, side by side.**

## Install in one line

On a fresh Ubuntu 22.04 / 24.04 / 26.04 VPS, as root:

```bash
curl -fsSL https://raw.githubusercontent.com/ChiefmonkeyArt/torii-suite/v0.6.2-alpha/bootstrap.sh | sudo bash
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
curl -fsSL https://raw.githubusercontent.com/ChiefmonkeyArt/torii-suite/v0.6.2-alpha/bootstrap.sh | sudo bash
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

### New in v0.6.2-alpha

Fix: first-install of Continuum failed in v0.6.0-alpha and v0.6.1-alpha with
`mv: cannot overwrite directory '/var/www/torii/continuum' with non-directory
'/var/www/torii/continuum.new'`. `install-continuum.sh` pre-created
`/var/www/torii/continuum` as a real directory, then tried to replace it with
the atomic-flip symlink. Fix: only create the parent directory; migrate any
legacy real directory aside on re-run.

### New in v0.6.1-alpha

`TORII_QUEST_REF` default: `main` -> `v0.2.367-alpha` (the first Quest tag
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
TORII_QUEST_REF=v0.2.362-alpha
```

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

# torii-suite

**One VPS. One domain. Continuum + Quest + Plebeian, side by side.**

`torii-suite` is a meta-installer. It composes the individual Torii apps into
a single deployment on a fresh Ubuntu VPS:

```
https://your-domain.com/                — Torii launcher
https://your-domain.com/continuum/      — Continuum (AI-powered app builder)
https://your-domain.com/agent/          — Continuum agent (Fastify, proxied)
https://your-domain.com/quest/          — Torii Quest (3D open-world game)
https://your-domain.com/plebeian/       — Plebeian Market (external tile)
```

Everything is opt-in. Install only Continuum if that's all you want. Add Quest
later by re-running `bootstrap.sh` with `INSTALL_QUEST=1`.

---

## Repo layout

```
torii-suite/
├── VERSION                       # e.g. 0.1.0-alpha — bump on every change
├── bootstrap.sh                  # the one-command entrypoint
├── .env.example                  # env contract (copy to .env)
├── installers/
│   ├── install-continuum.sh      # frontend + agent + systemd + nginx fragment
│   ├── install-quest.sh          # static bundle at /quest/ + nginx fragment
│   ├── register-plebeian.sh      # launcher tile only (Plebeian is external)
│   └── install-bridges.sh        # onboarding bridges (planned, v0.1.2+)
├── onboarding/
│   └── prototype.html            # non-coder onboarding wireframe (browser-side)
├── bridges/                      # onboarding infra (planned, v0.1.2+)
│   ├── cors-proxy/               # stateless CORS forwarder for the SHC API
│   └── webssh/                   # SSH-over-WebSocket bridge (webssh2 fork)
├── docs/
│   ├── HOSTING.md                # BYO VPS vs SHC vs any-other-provider
│   └── ONBOARDING_ARCHITECTURE.md  # ephemeral browser-side design
└── LICENSE                       # MIT
```

---

## Quick install

**Requirements:** Ubuntu 22.04 or 24.04, root (or a passwordless-sudo user),
a DNS `A` record pointing at your VPS, and an email address for Let's Encrypt.
You will also need a **NIP-07 signer** (Plebeian Signer, nos2x, or similar) so
you can hand the installer your `npub`.

```bash
# 1. Point your domain at the VPS, then SSH in as root:
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

That's it. In roughly 5–10 minutes on a small VPS you'll have all three apps
running behind a Let's Encrypt certificate.

---

## What the bootstrap does

Five stages, each idempotent (safe to re-run):

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
3. **Quest** — clones torii-quest, patches `vite.config.js` for a `/quest/`
   base path (see [`docs/HOSTING.md`](docs/HOSTING.md) §Quest sub-path), builds,
   snapshots into `/var/www/torii/quest-releases/<stamp>/`, atomically flips
   the symlink, drops an nginx fragment.
4. **Plebeian** — registers a launcher tile that opens
   `$PLEBEIAN_EXTERNAL_URL` (default `https://plebeian.market`). No install,
   no nginx fragment — Plebeian is a hosted external service.
5. **Doctor** — runs `torii status` and `torii doctor` from torii-base to
   verify every app registered, its nginx fragment loads, and (for Continuum)
   the agent is reachable, Routstr is up, and the Cashu wallet directory
   exists.

Everything is atomic-symlink deployed. The last 3 releases of each app are
retained under `<app>-releases/` for rollback via `ln -sfn`.

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

The three bridges the onboarding flow depends on (CORS proxy, WebSSH,
DNS zone controller) all live in this repo under `bridges/`. They run on
plain Linux VPS via `installers/install-bridges.sh` — no Cloudflare, no
PaaS, no third-party infrastructure of any kind. Anyone can self-host the
full set on any VPS with root access.

---

## Updating

Re-run the bootstrap:

```bash
cd torii-suite
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

Suite v0.1.0 does not ship an uninstaller. To tear down:

```bash
sudo torii unregister continuum
sudo torii unregister quest
sudo torii unregister plebeian
sudo systemctl disable --now continuum-agent
sudo rm /etc/systemd/system/continuum-agent.service
sudo rm /opt/torii/nginx-fragments/continuum.conf
sudo rm /opt/torii/nginx-fragments/quest.conf
sudo rm -rf /var/www/torii/{continuum,continuum-releases,quest,quest-releases}
sudo rm -rf /home/continuum
sudo torii reload
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

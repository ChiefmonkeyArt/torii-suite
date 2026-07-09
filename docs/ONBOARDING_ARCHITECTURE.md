# Onboarding architecture — ephemeral browser-side

`torii-suite` ships a **7-tap onboarding flow** for people who don't want to
touch a terminal. It provisions a full Torii instance (VPS + Continuum + Quest
+ Plebeian tile + first character setup) end-to-end from a phone.

The core design decision: **nothing but a Lightning invoice touches Torii
servers**. Every long-lived secret lives on the user's device or in their
NIP-07 signer. Torii-hosted infrastructure is limited to a stateless static
site, a stateless SSH-over-WebSocket bridge, and a stateless DNS zone
controller. All three of them are open-source, run on plain Linux VPS with no
KYC or centralized-service dependencies, and can be self-hosted by any
paranoid user; none of them have anything worth stealing.

---

## The 7 taps

1. **Welcome** — a one-screen "what you're about to get" summary + total cost.
2. **Pick a name** — subdomain on `*.torii.host` (default) or your own domain.
3. **Connect signer** — NIP-07 handshake, we read `npub` only.
4. **Pick a character** — Continuum ships a curated set; pick one or "blank".
5. **Pick a plot** — SVG map picker for the initial Quest spawn plot.
6. **Review + pay** — one Lightning invoice covering VPS + domain + support fee.
7. **Building** — 10-step progress list runs to completion (2-5 min).

Then a **Done** screen shows the finished URLs and (once) the backup
passphrase for the browser-stored SSH key. The passphrase is displayed with an
"I've written this down" checkbox; the user's own Nostr DM-to-self is the
recommended long-term store.

Wireframe: [`../onboarding/prototype.html`](../onboarding/prototype.html).

---

## Trust boundary

```
┌───────────────────────────────────────────────────────────────────┐
│  User's browser tab                                               │
│                                                                   │
│  • SHC API key         (tab-lifetime, dropped on close)           │
│  • SSH keypair         (generated in tab, private half never left)│
│  • Backup passphrase   (generated in tab, shown once)             │
│  • Orchestration state (progress bar, retries)                    │
│                                                                   │
│  ── NIP-07 signer ──────────────────────────────────────────────  │
│    • npub                                                         │
│    • ALL signing (SHC delegation, character root, DNS updates)    │
│    • nsec NEVER LEAVES the signer                                 │
└───────────────────────────────────────────────────────────────────┘
                              │
                              │  ephemeral outbound calls
                              ▼
┌─────────────────────────┬─────────────────────────┬───────────────┐
│  SHC API                │  User's fresh VPS       │  DNS zone     │
│                         │                         │  controller   │
│  • buy VPS              │  • ssh over websocket   │  (torii.host  │
│  • get IPv4             │  • curl bootstrap.sh    │   only)       │
│  • Lightning invoice    │  • run installer        │  • one npub-  │
│                         │                         │    signed     │
│                         │                         │    write per  │
│                         │                         │    tap 2      │
└─────────────────────────┴─────────────────────────┴───────────────┘
                              │
                              │  the ONLY Torii-hosted pieces:
                              ▼
┌───────────────────────────────────────────────────────────────────┐
│  torii-suite static site (served from a plain nginx on any VPS)   │
│    → serves the onboarding SPA                                    │
│    → zero state, zero secrets, zero logs                          │
│                                                                   │
│  Stateless CORS proxy                                             │
│    → wraps SHC API calls that don't set CORS                      │
│    → keeps no logs, holds no keys, ~50 lines of Node              │
│                                                                   │
│  Stateless SSH-over-WebSocket bridge                              │
│    → wraps outbound SSH-to-user-VPS as a websocket                │
│    → keeps no logs, holds no keys                                 │
│                                                                   │
│  torii.host DNS zone controller                                   │
│    → one endpoint: PUT /zones/<npub>/<name>                       │
│    → npub-signed writes only, rate-limited                        │
│    → holds only the zone file, no user data                       │
└───────────────────────────────────────────────────────────────────┘
```

**What Torii NEVER sees:** the user's SHC password, their VPS root password,
their SSH private key, their backup passphrase, their Cashu wallet, or any
long-lived credential.

---

## The four hard technical bits

These are the pieces that make the browser-side approach non-trivial. Each
has a stated shipping path.

### H1. CORS proxy

SHC's user API doesn't set `Access-Control-Allow-Origin` for arbitrary web
origins, so the browser can't call it directly. The fix is a tiny stateless
HTTP forwarder — the browser calls the proxy, the proxy calls SHC, adds the
missing header on the way back.

- **Lives at:** [`../bridges/cors-proxy/`](../bridges/cors-proxy/) (planned;
  scaffold lands in a follow-up PR).
- **What it is:** ~50 lines of Node.js. Zero state, zero logs, no persistence
  layer. It cannot store a credential because it has nowhere to put one.
- **Where it runs:** a plain Linux VPS. The reference deployment lives on the
  same host as the torii-suite static site — no separate provider, no PaaS,
  no CDN. Users who want to self-host it clone `torii-suite`, run
  `installers/install-bridges.sh`, and point their onboarding SPA at their
  own instance via a config setting.
- **Retire path.** If SHC ever whitelists `*.torii.host` origins directly,
  this bridge disappears. Until then it's scaffolding.

### H2. WebSSH — SSH-over-WebSocket bridge

The browser can't open a raw TCP SSH connection. The bridge terminates a
WebSocket on one side and opens an SSH session to the user's fresh VPS on
the other. The ephemeral SSH keypair generated in the browser tab is used;
the bridge holds no keys and logs no session content.

- **Lives at:** [`../bridges/webssh/`](../bridges/webssh/) (planned;
  scaffold lands in a follow-up PR).
- **What it is:** a fork of [webssh2](https://github.com/billchurch/webssh2),
  stripped down to accept ephemeral browser-generated keypairs only (no
  user/password auth, no server-side key stores) and configured with logging
  disabled.
- **Where it runs:** the same VPS as the CORS proxy. One systemd unit, one
  nginx location block on the shared HTTPS server.
- **Self-hostable.** The whole point. Anyone who doesn't trust the reference
  instance runs their own with the same installer.

### H3. DNS control for `*.torii.host`

If the user picks the default `*.torii.host` subdomain, we need to write one
A record per tenant. Torii runs a tiny DNS zone controller with a single
endpoint:

```
PUT /zones/<npub>/<name>   { "ip": "1.2.3.4" }
Authorization: NostrEvent <event signed by npub>
```

- **Only npub-signed writes** — no API keys, no shared secrets.
- **One name per npub** — prevents squatting.
- **Rate-limited** — max 5 writes/day per npub.
- **No reads** — the zone file is served publicly via the authoritative DNS,
  so a read endpoint would add attack surface without value.
- **Lives at:** planned as a third bridge, sibling to the CORS proxy and
  WebSSH bridge. Same repo, same deploy model.

### H4. BYO domain skips H3

Users who bring their own domain skip the torii.host path entirely. The
onboarding flow shows them a two-line "Set an A record for `torii.example.com`
to `1.2.3.4`" screen and polls DNS until it resolves. Everything downstream
is identical.

---

## Deployment model — no third parties, ever

The three bridges (CORS proxy, WebSSH, DNS controller) all follow the same
deployment rules. This is a hard constraint, not a preference:

- **No Cloudflare, no Fly, no Railway, no Deno Deploy, no Vercel, no Netlify,
  no serverless PaaS.** Every one of those introduces a centralized operator
  who sees traffic, can revoke access, and requires an account. That defeats
  the point of a sovereign stack.
- **No third-party auth, no OAuth, no KYC.** The only identity is the user's
  npub.
- **No managed databases.** All three bridges are stateless.
- **Runs on any Linux VPS with root and ports 80/443.** Same requirements as
  the rest of `torii-suite`.

The reference bridge instance is expected to run on the same infrastructure
as the onboarding static site — one small VPS bought from any provider (SHC
if you want Bitcoin billing, any other host if you don't). The whole thing
is one nginx server block, three Node processes, three systemd units.
`installers/install-bridges.sh` will bring the whole set up on a fresh VPS.

Anyone who doesn't trust the reference instance clones `torii-suite`, runs
the same installer on their own VPS, and points their onboarding SPA at
their own bridge host via a build-time environment variable. There is no
technical difference between "the reference bridges" and "your bridges" —
they're the same code from the same repo. This is the intended long-term
state.

---

## What lives where at rest

After the flow completes, here's where every piece of state ends up:

| Item                          | Where                              | Recovery path                     |
| ----------------------------- | ---------------------------------- | --------------------------------- |
| `nsec` (user's Nostr key)     | User's NIP-07 signer only          | Existing Nostr backup workflow    |
| SSH keypair to the VPS        | Nostr DM-to-self, encrypted with passphrase | Re-derive from passphrase + key   |
| Backup passphrase             | Written down by the user (once shown) | Nowhere else — this is the root  |
| SHC API key                   | Discarded when the tab closes      | Generate a new one via SHC login  |
| VPS root password             | The VPS itself (SSH-key-only login) | Recover via SHC console access    |
| Cashu wallet                  | `/home/continuum/agent/repo/agent/memory/wallet/` on the VPS | Continuum → Wallet export flow    |
| Continuum session secret      | `/home/continuum/agent/repo/agent/config.yaml` on the VPS | Regenerated on install; rotatable |

The critical property: **losing the browser tab loses nothing that matters.**
Everything that survives beyond the tab is either on the VPS (behind SSH) or
in the user's own Nostr identity (behind their signer). The backup passphrase
is the one thing the user has to remember; the DM-to-self makes it easy.

---

## What we deliberately don't do

- **No account system.** Torii never creates a user record. `npub` is your
  identity everywhere.
- **No email.** No password reset, no notifications, no marketing.
- **No server-side session.** The static site is stateless; the bridges are
  stateless; the DNS controller is stateless.
- **No analytics.** The bridges and DNS controller log nothing. The static
  site loads no third-party scripts.
- **No custody.** Torii never holds a Bitcoin balance, a Cashu token, or an
  API key for a service the user pays for. Every payment goes user →
  provider directly.
- **No third-party infrastructure.** No CDN, no PaaS, no managed serverless.
  Plain Linux VPS, plain nginx, plain systemd, plain Node. If it needs
  someone's dashboard to configure, it doesn't belong here.

If any of the above changes in a future version, this document changes with
it. The version bump on this file is the audit trail.

---

## Version history

- **v0.1.0-alpha** — initial spec + wireframe. No live implementation yet;
  the flow is buildable but requires H1–H3 to ship the bridges.
- **v0.1.1-alpha** — dropped Cloudflare/PaaS mentions. Bridges now
  explicitly live inside `torii-suite/bridges/` and deploy to plain Linux
  VPS via `installers/install-bridges.sh`. No third-party, KYC, or
  centralized-service dependencies anywhere in the stack.

# Onboarding architecture — ephemeral browser-side

`torii-suite` ships a **7-tap onboarding flow** for people who don't want to
touch a terminal. It provisions a full Torii instance (VPS + Continuum + Quest
+ Plebeian tile + first character setup) end-to-end from a phone.

The core design decision: **nothing but a Lightning invoice touches Torii
servers**. Every long-lived secret lives on the user's device or in their
NIP-07 signer. Torii-hosted infrastructure is limited to a stateless static
site, a stateless SSH-over-WebSocket bridge, and a stateless DNS zone
controller. Any of them could be self-hosted by a paranoid user; none of them
have anything worth stealing.

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
│  torii-suite static site (S3 or Cloudflare Pages)                 │
│    → serves the onboarding SPA                                    │
│    → zero state, zero secrets, zero logs                          │
│                                                                   │
│  Stateless CORS-and-SSH-tunnel bridge                             │
│    → wraps SHC API calls that don't set CORS                      │
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
has a stated shipping path:

### H1. CORS on the SHC API

SHC's user API doesn't set `Access-Control-Allow-Origin` for arbitrary web
origins, so the browser can't call it directly. Two options:

- **A. Torii ships a stateless dumb proxy** at `api-proxy.torii.host` that
  adds CORS and forwards. It logs nothing, holds no state, is one file of
  code. Users who don't trust the proxy can self-host it — publish the source.
- **B. Petition SHC to whitelist `*.torii.host` and `onboard.torii.host`.**
  This is the correct long-term answer. Path A ships first as a fallback.

### H2. WebSSH — websocket-to-SSH bridge

The browser can't open a raw TCP SSH connection. Torii ships a small
`ssh-bridge.torii.host` that terminates a websocket on one side and opens an
SSH session on the other. The user's ephemeral SSH keypair is used; the
bridge holds no keys and logs no session content. Source is published so the
user can self-host or verify.

Tools that already do this well: [webssh2](https://github.com/billchurch/webssh2),
[GateOne](https://github.com/liftoff/GateOne). We're likely to fork rather
than write from scratch.

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

### H4. BYO domain skips H3

Users who bring their own domain skip the torii.host path entirely. The
onboarding flow shows them a two-line "Set an A record for `torii.example.com`
to `1.2.3.4`" screen and polls DNS until it resolves. Everything downstream
is identical.

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
- **No server-side session.** The static site is stateless; the bridge is
  stateless; the DNS controller is stateless.
- **No analytics.** The bridge and DNS controller log nothing. The static
  site loads no third-party scripts.
- **No custody.** Torii never holds a Bitcoin balance, a Cashu token, or an
  API key for a service the user pays for. Every payment goes user →
  provider directly.

If any of the above changes in a future version, this document changes with
it. The version bump on this file is the audit trail.

---

## Version history

- **v0.1.0-alpha** — initial spec + wireframe. No live implementation yet;
  the flow is buildable but requires H1–H3 to ship the bridges.

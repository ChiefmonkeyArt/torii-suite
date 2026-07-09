# torii-suite bridges

Two small, self-hosted bridges that enable the browser-side non-coder
onboarding flow shipped in `onboarding/`. Both are **opt-in**, **stateless**,
and run on the same VPS as the Torii suite. No Cloudflare, no PaaS, no
third-party dependency of any kind — just plain Linux + nginx + systemd.

```
bridges/
├── cors-proxy/   Stateless allowlisted HTTP forwarder (zero deps)
└── webssh/       WebSocket-to-SSH bridge with ephemeral-key sessions
```

Deployed via [`installers/install-bridges.sh`](../installers/install-bridges.sh),
gated behind `INSTALL_ONBOARDING_BRIDGES=1` in `bootstrap.sh`.

---

## Why these exist

The onboarding wireframe (`onboarding/prototype.html`) provisions a full
Torii deployment from a phone in ~7 taps. To do that, the browser needs to
speak to two things it can't reach directly:

1. **The VPS provider's REST API** — for provisioning, billing, and status.
   The provider (e.g. SHC) doesn't set `Access-Control-Allow-Origin` for our
   onboarding origin, so a same-origin proxy on our own domain is required.
   That's `cors-proxy/`.
2. **The freshly-provisioned VPS over SSH** — to run `bootstrap.sh` on it
   the first time. The browser can't open a raw TCP socket, so we tunnel
   SSH inside a WebSocket. That's `webssh/`.

Both bridges are single-purpose, stateless, and reject anything outside a
narrow allowlist. They never see the user's npub, nsec, or Cashu wallet;
those all stay in the browser.

---

## cors-proxy — allowlisted HTTP forwarder

**What:** Node HTTP server. Forwards `/cors-proxy/<upstream-host>/<path>`
to `https://<upstream-host>/<path>` iff `<upstream-host>` is in
`CORS_PROXY_UPSTREAM_ALLOW` and the request `Origin` is in
`CORS_PROXY_ORIGIN_ALLOW`. Adds the correct `Access-Control-Allow-Origin`
header echoing the caller's origin — never `*`.

**Deps:** zero. Node built-ins only.

**Refuses to start if:** either allowlist is empty (exit 2). This is
deliberate — a wide-open CORS proxy is a footgun.

**Never does:**
- No caching, no logging of bodies, no auth interception.
- Never rewrites URLs in response bodies. Only forwards.
- Never sends `Access-Control-Allow-Origin: *`.

See [`cors-proxy/README.md`](cors-proxy/README.md) for the exact request
grammar and response codes.

---

## webssh — WebSocket-to-SSH bridge

**What:** Node WebSocket server on `/webssh`. Accepts a JSON `connect`
message with `{ host, port, username, privateKey, command }`, opens an
outbound SSH connection with those ephemeral credentials, and pipes
stdout/stderr back over the socket. Closes when the command exits or the
15-minute session cap fires.

**Deps:** `ws@^8.18`, `ssh2@^1.16`. No others.

**Command allowlist:** the `command` field is regex-checked against a
narrow set of bootstrap-shaped invocations:

- `bash <(curl -fsSL https://…/bootstrap.sh) [ENV=val …]`
- `sudo -E bash <(curl -fsSL https://…/bootstrap.sh) [ENV=val …]`
- `curl -fsSL https://…/bootstrap.sh | bash`
- `curl -fsSL https://…/bootstrap.sh | sudo -E bash`

Anything else is rejected before touching SSH. The bridge cannot be used
as a general-purpose shell.

**Refuses to start if:** `WEBSSH_ORIGIN_ALLOW` is empty (exit 2).

**Per-IP concurrency cap:** default 3 simultaneous sessions per source IP,
tunable via `WEBSSH_MAX_PER_IP`. Fourth request from the same IP is
rejected with `too many concurrent sessions from your IP`.

**Weak-algo refusal:** the bridge tells `ssh2` to refuse deprecated
ciphers, MACs, KEX, and host-key algorithms (no `ssh-rsa` with SHA-1, no
`hmac-sha1`, no `diffie-hellman-group1-sha1`, etc.).

**Never does:**
- Never persists the private key. Reference is dropped after handoff to
  `ssh2`; `ssh2` holds it only for the lifetime of the SSH connection.
- Never opens an interactive shell. Only `exec` with the allowlisted
  command string.
- Never accepts a password. Key-based auth only.

See [`webssh/README.md`](webssh/README.md) for the protocol and message
schemas.

---

## Deploy model

Both services run under a dedicated `torii-bridges` system user on the
suite VPS, one `systemd` unit each:

- `torii-cors-proxy.service` — listens on `127.0.0.1:${CORS_PROXY_PORT}`
- `torii-webssh.service` — listens on `127.0.0.1:${WEBSSH_PORT}`

Both units are hardened: `NoNewPrivileges`, `ProtectSystem=strict`,
`ProtectHome=true`, `PrivateTmp`, `PrivateDevices`, `RestrictNamespaces`,
`LockPersonality`, empty `CapabilityBoundingSet`, and
`RestrictAddressFamilies=AF_INET AF_INET6`. The CORS proxy additionally
runs with `MemoryDenyWriteExecute=true`; WebSSH does not, because `ssh2`
JIT-compiles some crypto paths.

Traffic is fronted by the suite's existing nginx via
`/opt/torii/nginx-fragments/bridges.conf`, so both bridges reuse the
suite's Let's Encrypt cert. `wss://<domain>/webssh` uses a
`proxy_read_timeout` of 900s to match the 15-minute session cap.

Both are registered with `torii-base-sidecar` as the single `bridges`
launcher tile.

---

## Configuration

All bridge config lives in `torii-suite/.env` (see `.env.example`):

| Var | Required when bridges on | Default | Notes |
|-----|--------------------------|---------|-------|
| `INSTALL_ONBOARDING_BRIDGES` | — | `0` | Set to `1` to install |
| `CORS_PROXY_ORIGIN_ALLOW` | yes | (empty) | Comma-separated browser origins |
| `CORS_PROXY_UPSTREAM_ALLOW` | no | `blesta.sovereignhybridcompute.com` | Comma-separated upstream hosts |
| `CORS_PROXY_PORT` | no | `8801` | Localhost bind port |
| `WEBSSH_ORIGIN_ALLOW` | yes | (empty) | Comma-separated browser origins |
| `WEBSSH_PORT` | no | `8802` | Localhost bind port |
| `WEBSSH_MAX_PER_IP` | no | `3` | Concurrent sessions per source IP |
| `WEBSSH_MAX_SESSION_MS` | no | `900000` | Hard session cap (ms) |

---

## Local development

Each bridge is standalone Node — run either without root:

```bash
# cors-proxy (zero deps, just run it)
CORS_PROXY_ORIGIN_ALLOW=http://localhost:5173 \
CORS_PROXY_UPSTREAM_ALLOW=blesta.sovereignhybridcompute.com \
CORS_PROXY_PORT=8801 \
  node bridges/cors-proxy/index.mjs

# webssh (install deps first)
cd bridges/webssh && npm ci --omit=dev && cd ../..
WEBSSH_ORIGIN_ALLOW=http://localhost:5173 \
WEBSSH_PORT=8802 \
  node bridges/webssh/index.mjs
```

Both expose `/_health` returning `{ ok: true }` — use it for readiness checks.

---

## Not shipped in v0.1.2

- **DNS zone controller** — the third bridge referenced in the onboarding
  architecture doc. It lives in a future revision; the wireframe currently
  fakes it. Adding it requires picking a plain-Linux nameserver stack
  (Knot / NSD / PowerDNS) and is out of scope for this release.
- **Rate limiting** beyond the WebSSH per-IP concurrency cap. If you expose
  either bridge to the open internet, put a proper rate limiter in front
  of nginx (e.g. `limit_req_zone` or fail2ban).
- **Multi-tenant separation.** Both bridges are single-tenant: one
  onboarding origin, one operator. Running an onboarding-as-a-service
  would need per-tenant allowlists and quotas.

---

## Security posture (short version)

- **No secrets ever leave the browser.** The bridges pass through
  credentials the user typed into their own device; they never mint,
  store, or log them.
- **Every request is allowlisted twice** — by origin and by target.
- **Empty allowlist = refuse to start**, not "accept anything".
- **The command surface is a regex**, not a shell. WebSSH cannot be
  turned into a general remote-exec by design.
- **Systemd-hardened**, so a compromise of either process still cannot
  read `/home`, write `/etc`, or open UNIX sockets.
- **No third-party CDN, WAF, or PaaS** sits between the user and their
  hosting provider. This is a decentralization requirement, not a
  performance choice.

# torii-webssh

SSH-over-WebSocket bridge. Lets the onboarding SPA run one specific
command (the torii-suite bootstrap) on a freshly-provisioned VPS without
the user opening a terminal.

**Two runtime dependencies:** `ws` and `ssh2`. Both mature and widely
deployed. Node 20+.

## How it works

1. Browser generates an ephemeral SSH keypair in-tab (WebCrypto).
2. Browser pushes the public half to the fresh VPS during provisioning
   (via SHC's cloud-init `authorized_keys` field, or via the SPA's
   password-then-key handoff flow).
3. Browser opens a WebSocket to `wss://<bridge-host>/webssh`.
4. Browser sends a `connect` handshake with the private half + the exact
   command to run (must match `WEBSSH_CMD_ALLOW_REGEX`).
5. Bridge opens an SSH session to the target and runs the command in a
   PTY. stdout/stderr stream back over the WebSocket in real time.
6. When the WebSocket closes (tab shut, session finished, or 15-min
   timeout), the SSH connection is torn down.

The private key exists only in the WebSocket message and in RAM for the
duration of the SSH connection. It is never written to disk and never
logged.

## Command allowlist — the security anchor

The bridge only runs commands matching `WEBSSH_CMD_ALLOW_REGEX`. The
default regex accepts only these shapes:

```
bash <(curl -fsSL https://…/bootstrap.sh) [ENV=val ...]
sudo -E bash <(curl -fsSL https://…/bootstrap.sh) [ENV=val ...]
curl -fsSL https://…/bootstrap.sh | bash [ENV=val ...]
curl -fsSL https://…/bootstrap.sh | sudo -E bash [ENV=val ...]
```

No semicolons, no backticks, no arbitrary pipes, no filesystem commands.
This means even a fully-compromised browser or MITM'd handshake can only
trigger a bootstrap-shaped invocation of a public URL. Combined with
ephemeral keys that die with the tab, the blast radius is a wasted VPS,
not a persistent foothold.

Operators who need a broader command set can override the regex via
`WEBSSH_CMD_ALLOW_REGEX`. Do so carefully.

## Configuration

All configuration is via environment variables. There is no config file.

| Variable                  | Default                        | Purpose                                              |
| ------------------------- | ------------------------------ | ---------------------------------------------------- |
| `WEBSSH_PORT`             | `8802`                         | Localhost port to listen on                          |
| `WEBSSH_ORIGIN_ALLOW`     | *(empty — refuses to start)*   | Comma-separated allowlist of browser origins         |
| `WEBSSH_MAX_SESSION_MS`   | `900000` (15 min)              | Hard session timeout                                 |
| `WEBSSH_MAX_PER_IP`       | `3`                            | Concurrent sessions from a single client IP          |
| `WEBSSH_CMD_ALLOW_REGEX`  | *(bootstrap shapes only)*      | Regex the requested command must match               |
| `WEBSSH_LOG_LEVEL`        | `silent`                       | `silent` (boot line only) or `info`                  |

`WEBSSH_ORIGIN_ALLOW` must be non-empty at boot. The bridge exits with
code 2 if it is empty.

## Wire protocol

Every message is a UTF-8 JSON object on the WebSocket.

### Client → bridge (handshake, exactly once)

```json
{
  "type": "connect",
  "host": "1.2.3.4",
  "port": 22,
  "username": "root",
  "privateKey": "-----BEGIN OPENSSH PRIVATE KEY-----\n…",
  "command": "bash <(curl -fsSL https://raw.githubusercontent.com/ChiefmonkeyArt/torii-suite/main/bootstrap.sh) TORII_DOMAIN=torii.example.com …"
}
```

### Client → bridge (post-handshake, optional)

```json
{ "type": "stdin",  "data": "…base64…" }
{ "type": "resize", "cols": 80, "rows": 24 }
{ "type": "close" }
```

### Bridge → client

```json
{ "type": "ready" }
{ "type": "stdout", "data": "…base64…" }
{ "type": "stderr", "data": "…base64…" }
{ "type": "exit",   "code": 0 }
{ "type": "error",  "message": "…" }
```

## Health check

```bash
curl http://127.0.0.1:8802/_health
# {"ok":true,"service":"torii-webssh"}
```

## Running locally

```bash
npm install
WEBSSH_ORIGIN_ALLOW="http://localhost:5173" \
WEBSSH_LOG_LEVEL=info \
node index.mjs
```

Then, from the SPA, open a WebSocket to `ws://127.0.0.1:8802/webssh` and
follow the handshake protocol above.

## Deployment

Deployed by `torii-suite/installers/install-bridges.sh`:

- Runs as the `torii-bridges` system user
- Listens on `127.0.0.1:8802` — never exposed directly
- Fronted by nginx at `wss://<bridge-host>/webssh`
- systemd unit at `/etc/systemd/system/torii-webssh.service`
- Full sandbox hardening (`ProtectSystem=strict`, `NoNewPrivileges=true`, etc.)

## Threat model

- **A malicious script in the user's browser** cannot escape the allowlist
  regex, so the worst it can do is trigger a bootstrap install on the
  user's own fresh VPS.
- **A compromised bridge** could observe SSH keys and stdout in flight.
  Mitigations: hardened systemd unit, no on-disk state, minimal code, and
  published source so paranoid users self-host.
- **A network attacker** cannot see anything — the WebSocket runs over
  TLS terminated at nginx.
- **A bridge operator** cannot bill the user, forge Nostr events, or
  touch their signer — those all stay on-device.

## Why not fork webssh2 or GateOne?

Both are excellent tools for their intended use case: interactive
web-terminal access with user/password login. That's the opposite of what
this bridge does — we do ephemeral-key-only, one-command sessions, no
interactive login. Writing ~350 lines that do only that turned out
smaller and safer than stripping features from a general-purpose
web-terminal.

## License

MIT — see `../../LICENSE`.

# torii-cors-proxy

Stateless CORS-adding HTTP forwarder. Wraps upstream APIs that don't set
`Access-Control-Allow-Origin` so the onboarding SPA can call them from a
browser.

**Zero runtime dependencies.** Node 20+, one file, ~280 lines. Auditable in
one sitting.

## What it does

- Terminates browser requests at `POST/GET/PUT/DELETE/PATCH https://<bridge-host>/cors-proxy/<upstream-host>/<path>`
- Verifies the request `Origin` is in an env-driven allowlist
- Verifies `<upstream-host>` is in an env-driven allowlist
- Filters request/response headers to a small allowlist
- Streams the body through with a size cap (default 10 MiB)
- Adds `Access-Control-Allow-Origin: <origin>` on the response — never `*`

## What it does NOT do

- Log request or response bodies
- Persist any state
- Forward cookies (both `Cookie` and `Set-Cookie` are stripped)
- Accept wildcard origins or wildcard upstreams
- Handle WebSocket upgrades (that's the WebSSH bridge's job)

## Configuration

All configuration is via environment variables. There is no config file.

| Variable                       | Default                                  | Purpose                                              |
| ------------------------------ | ---------------------------------------- | ---------------------------------------------------- |
| `CORS_PROXY_PORT`              | `8801`                                   | Localhost port to listen on                          |
| `CORS_PROXY_UPSTREAM_ALLOW`    | `blesta.sovereignhybridcompute.com`      | Comma-separated allowlist of upstream hosts          |
| `CORS_PROXY_ORIGIN_ALLOW`      | *(empty — refuses to start)*             | Comma-separated allowlist of browser origins         |
| `CORS_PROXY_MAX_BODY_BYTES`    | `10485760`                               | Hard cap on request AND response body size (bytes)   |
| `CORS_PROXY_LOG_LEVEL`         | `silent`                                 | `silent` (boot line only) or `info`                  |

Both allowlists must be non-empty at boot. The proxy exits with code 2 if
either is empty — this prevents "oops I forgot to set it and now it's an
open proxy" mistakes.

## Running locally

```bash
CORS_PROXY_ORIGIN_ALLOW="http://localhost:5173" \
CORS_PROXY_LOG_LEVEL=info \
node index.mjs
```

Then, from your SPA:

```js
const res = await fetch(
  "http://127.0.0.1:8801/cors-proxy/blesta.sovereignhybridcompute.com/api/vps",
  { method: "POST", headers: { "content-type": "application/json" }, body: "{}" }
);
```

## Health check

```bash
curl http://127.0.0.1:8801/_health
# {"ok":true,"service":"torii-cors-proxy"}
```

`torii doctor` (from torii-base) uses this endpoint to verify the bridge
is live.

## Deployment

Deployed by `torii-suite/installers/install-bridges.sh`:

- Runs as the `torii-bridges` system user
- Listens on `127.0.0.1:8801` — never exposed directly
- Fronted by nginx at `https://<bridge-host>/cors-proxy/`
- systemd unit at `/etc/systemd/system/torii-cors-proxy.service`
- Full sandbox hardening (`ProtectSystem=strict`, `NoNewPrivileges=true`, etc.)

## Threat model

This bridge sits in the network path of every SHC API call the onboarding
SPA makes. Reasoning about what a compromised bridge could do:

- **Cannot read the user's SHC API key at rest** — the proxy holds nothing
  between requests, so "read the database" is not a threat.
- **Could observe the API key in flight** — mitigated by keeping the bridge
  code minimal and auditable, running it as a hardened systemd unit, and
  publishing the source so paranoid users self-host.
- **Could tamper with responses** — same mitigations. TLS between browser
  and bridge, plus SHC's own request signing where present.
- **Cannot pivot to other services** — the upstream allowlist is a Set
  check with no wildcards.

## License

MIT — see `../../LICENSE`.

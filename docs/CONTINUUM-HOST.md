# Continuum on its own host (v0.9.31-alpha)

Opt-in: `INSTALL_CONTINUUM_HOST=1` (needs `INSTALL_CONTINUUM=1`). Host:
`CONTINUUM_HOST`, default `continuum.<domain>`; add a DNS A record first.

## Why

On the main domain, Continuum shares an origin with Quest and every other app
under `/`. Its owner token lives in `localStorage`, which any script on that
origin can read. Its own origin removes that path. It is also the host the
Torii Teams app lets frame it (`frame-ancestors`, docs/TEAMS.md).

## What it does

- `https://continuum.<domain>/` includes the same fragment
  `install-continuum.sh` writes (`/continuum/`, `/agent/`) and the torii-base
  `/api/` snippet, so there is one copy of each location. `/` goes to
  `/continuum/`; every other path is 404.
- `https://<domain>/continuum/*` gets a 301 to the same path and query on the
  Continuum host (`/opt/torii/nginx-fragments/continuum-host.conf`). The
  redirect is written only once the host has a certificate.
- `/api/` and `/agent/` stay on the main domain too, for the other apps.
- Headers (`/opt/torii/nginx-snippets/continuum-headers.inc`, included in every
  Continuum location): HSTS, `nosniff`, `frame-ancestors 'none'` plus
  `X-Frame-Options: DENY` (nothing frames Continuum), and a Permissions-Policy
  that gives the microphone to the Teams origin only, never Continuum itself
  (`microphone=("https://<teams host>")`, or `()` without a Teams host;
  v0.9.73-alpha, ADR 0006): the Team view iframe allows
  `clipboard-write; microphone` since Continuum v0.2.212-alpha, for voice notes.
- `bootstrap.sh` exports `CONTINUUM_HOST`, so `install-teams-app.sh` writes it
  into `/torii-node.json` (`"continuum"`) and the Teams CSP.

Sign-in does not bind to the origin, so nothing in Continuum changes. After the
move, everyone signs in once on the new host. The old token stays in the main
domain's storage until it expires; rotate the session secret
(`installers/rotate-session-secret.sh`) to end it at once.

## Rollback

```bash
sudo CONTINUUM_HOST_REMOVE=1 TORII_DOMAIN=<domain> /opt/torii-suite/checkout/installers/install-continuum-host.sh
```

This removes the redirect, the vhost link and the headers snippet. The
certificate is kept.

## Tests

`test/install-continuum-host.test.sh` (contract + helpers) and
`test/continuum-host-live.sh` (real nginx on high ports with the real fragment,
26 checks: redirect, headers, `/api/`, `/agent/`, 404s). CI:
`.github/workflows/continuum-host.yml`.

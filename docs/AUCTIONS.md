# Plebeian Auctions on a Torii node

Team-only, fake-sats auction arena ([Suite ADR 0002](adr-0002-team-only-auctions.md)).
No launcher card: share `https://auctions.<domain>/` with the team directly.

## Install

Point `auctions.<domain>` at the VPS (an A record), then, with the Suite
checkout at a release that has this installer:

```bash
sudo INSTALL_AUCTIONS=1 TORII_DOMAIN=<domain> bash /opt/torii-suite/checkout/installers/install-auctions.sh
```

The release repo is public, so the VPS downloads the pinned tarball itself
(`AUCTIONS_TARBALL=/path/plebeian-auctions-v0.2.0.tar.gz` installs a local copy).

Escrow (v0.2.0): bids lock to one FROST 3-of-4 group key; each validator keeps
its share in `/var/lib/plebeian-auctions/chain/vN/config/frost_key.json` (0600).
A chain without these shares (v0.1.x) is re-created on the next start.

## Files and services

| What | Where |
|---|---|
| Releases (last 2) | `/apps/plebeian-auctions/releases/`, `current` symlink |
| Mint settings, key (0600) | `/etc/torii/auctions/mint.env` |
| Chain state, validator logs | `/var/lib/plebeian-auctions/` |
| Mint database | `/var/lib/plebeian-auctions-mint/` |
| Vhost | `/etc/nginx/sites-available/auctions.<domain>.conf` |
| Headers | `/opt/torii/nginx-snippets/auctions-headers.inc` |
| Units | `plebeian-auctions-mint`, `plebeian-auctions` |

Loopback ports: gateway 8795 (`AUCTIONS_PORT`), mint 13338
(`AUCTIONS_MINT_PORT`), validators 26656-26687 and 7101-7104. If the gateway or mint default is busy
on a first install, the next free port is used and saved in
`/etc/torii/auctions/ports`; validator ports must be free.

## Operate

```bash
systemctl status plebeian-auctions plebeian-auctions-mint
journalctl -u plebeian-auctions -n 50
```

- Upgrade: pin the new `AUCTIONS_TAG` and `AUCTIONS_SHA256` in the installer
  through a Suite PR, then rerun it. The mint key is kept.
- Start again with no fake sats: rerun with `AUCTIONS_RESET=1`.
- Remove: `AUCTIONS_REMOVE=1` (state and settings are kept).

## Tests

- `bash test/install-auctions.test.sh`: contract and helper checks, any user.
- `sudo bash test/auctions-live.sh <tarball> [e2e.mjs]`: real install against
  nginx with a self-signed cert on a throwaway host; with the arena's
  `tests/e2e.mjs` it also runs the 34 acceptance checks over HTTPS.

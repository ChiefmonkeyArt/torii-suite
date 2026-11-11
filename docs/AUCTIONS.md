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
(`AUCTIONS_TARBALL=/path/plebeian-auctions-v0.4.2.tar.gz` installs a local copy).

Escrow (v0.2.0+): bids lock to one FROST 3-of-4 group key; each validator keeps
its share in `/var/lib/plebeian-auctions/chain/vN/config/frost_key.json` (0600).
The gateway unit runs `arena init -if-needed`: a chain whose
`/var/lib/plebeian-auctions/chain/FORMAT` does not match the release (v0.3.0-v0.3.4:
`3`; v0.4.0+: `4`) is re-created on the next start. v0.3.1 to v0.3.4 kept the v0.3.0
chain; upgrading to v0.4.0 re-creates it (lots, bids and block history go; fake-sats
wallet balances stay in the browser, and a bid still locked to the old group key
can be reclaimed alone once its lock time passes).

Making room (Suite v0.9.61+): after the new release is verified and unpacked, and
before it is copied, the installer deletes older `plebeian-auctions-v*.tar.gz`
downloads and any release folder (other than `current`) missing a file every release
has. If the chain's FORMAT differs from the pinned release's
(`AUCTIONS_CHAIN_FORMAT`, known for the pinned tag), it stops the services and
deletes the old chain now instead of on start. It then needs twice the release's
size plus 512 MiB free; otherwise it restarts anything it stopped, prints the
largest directories and exits without changing the install.

State snapshots (v0.3.3+, arena ADR 0003 §2): each validator writes its app state to
`chain/vN/data/app-state/<height>.json` (mode 0600, the newest 2 kept) every 1,000
blocks and on a clean stop, and starts from the newest one instead of replaying every
block from genesis. A snapshot is used only if its hash, canonical form, file name and
the app hash the chain recorded for that height all agree; otherwise the validator
refuses to start (delete the bad file to fall back to the previous one). The first
start after upgrading from v0.3.2 still replays once (v0.3.2 wrote no snapshots).

Block growth (v0.4.0+, arena ADR 0003 §1, §4): no empty blocks while idle (one
heartbeat block a minute), and the app hash leaves out height and time, so an idle
chain barely grows. Each validator keeps only its last 100,000 blocks; every
transaction's outcome goes first to an append-only archive,
`chain/vN/data/ledger.jsonl` (one JSON line per transaction, fsynced). Back up
that file, not the block store. Block times come from proposer-based timestamps
(2 s message delay), and the validators close a lot on chain within about a
second of its end.

Live push and void bids (v0.4.0+, arena ADR 0007): the page listens on
`/api/events` (Server-Sent Events, one stream per tab, pinged every 15 s, ended
after 15 min, at most 512 per gateway) and fetches the view only when a block
lands; it falls back to polling if the stream drops. The vhost gives that path its
own location: HTTP/1.1, no buffering, no gzip, 60 s read timeout, and the same cap
of 16 long-lived connections per address as `/mint/v1/ws`. A bid that loses a race
(outbid in the same block, or sent after the close) is recorded as void, so its
fake sats are refundable at once instead of locked until the margin passes.

Polling (v0.3.1+, arena ADR 0004): the page reads `/api/state?view=client`, a
slim view without Cashu proofs that answers `304` when nothing changed, and the
gateway gzips API JSON. The vhost needs no change: nginx passes `ETag`,
`If-None-Match` and `Content-Encoding` through.

Mint WebSocket (v0.3.2+, arena ADR 0005): Coco subscribes to the mint's NUT-17
updates on `/mint/v1/ws`. The vhost passes `Upgrade`/`Connection` on that one
location only (HTTP/1.1, 600 s timeouts, at most 16 open sockets per address);
the gateway caps a socket at 10 minutes and refuses upgrades on any other path.

Settings (v0.3.0+): `AUCTIONS_LOCK_MARGIN` (default 86400 s) is how long after
an auction's hard end a bid stays locked before the bidder can reclaim it
alone; the seller must collect within it. `AUCTIONS_DEMO_CONTROLS` (default 1)
keeps the unauthenticated validator stop/start route for the team demo; with
0 it answers 404. Set it to 0 before real sats. Security review:
[arena audit](https://github.com/ChiefmonkeyArt/plebeian-arena-auctions/blob/main/docs/SECURITY_AUDIT_2026-11-10.md).

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

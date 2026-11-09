# ADR 0002 (Suite): Plebeian Auctions as a team-only app

Date: 2026-11-09. Status: **Accepted** (owner, 2026-11-09: "add plebeian
auctions to the Torii suite as an app like any other do not create a card for
it on the homepage it's not for public just for the team"; "Add only Plebeian
Auctions to the Torii Suite, with no homepage card").

## Context

The fake-sats auction arena (`ChiefmonkeyArt/plebeian-arena-auctions`: four
CometBFT validators, 3-of-4 Cashu escrow, Nutshell FakeWallet mint, C Arena
front end) ran only in a Computer workspace. The team needs a stable place to
try it. It is unaudited demo software and is not for the public.

## Decision

1. **Opt-in installer, like the Teams app.** `installers/install-auctions.sh`
   runs only with `INSTALL_AUCTIONS=1` (default 0). It installs a prebuilt
   release pinned by tag and SHA-256 (the checksum is never read from the
   release). Nothing is built on the VPS: the tarball carries a static Go
   binary, the built front end and a private CPython 3.12 with Nutshell from
   hash-pinned wheels.
2. **No homepage card.** The installer never calls `torii register` and
   writes no main-domain fragment, so the launcher never lists it. The address
   is shared with the team directly. Every response carries
   `X-Robots-Tag: noindex, nofollow`, and the app ships `robots.txt`
   `Disallow: /`.
3. **Own origin.** `https://auctions.<domain>/` on its own certificate, so
   the per-browser Nostr keys and ecash wallets in localStorage stay apart
   from Quest, Continuum and Teams. Strict CSP: own origin only, inline script
   hashed, never framed.
4. **Loopback and sandboxed.** The gateway (8795), mint (13338) and the four
   validators (26656-26687, 7101-7104) bind 127.0.0.1. The two systemd units
   run as dynamic users that may reach only localhost, with state in
   `/var/lib/plebeian-auctions{,-mint}`. A first install fails closed if any
   of those ports is in use. nginx allows only GET/HEAD (and POST to the API
   and mint) and rate-limits both.
5. **Fake sats only.** The mint is FakeWallet: invoices pay themselves and
   nothing touches Lightning. The mint key is created once and kept, so
   escrows survive upgrades; `AUCTIONS_RESET=1` wipes all fake sats.

## Consequences

- An unlisted address is not access control: anyone who has the link can
  bid, and can use the arena's Network panel to stop and start validators. A
  sign-in gate is separate, later work.
- The release repo is private, so the VPS cannot download the release by
  itself. Either the repo is made public (as torii-teams is), or the operator
  supplies the tarball with `AUCTIONS_TARBALL=<path>`.
- Deploying needs an `auctions` stage in Continuum's `suite-stages-vps.yml`
  allowlist, or an operator run of the installer over SSH, with operator
  approval either way.
- Rollback: `AUCTIONS_REMOVE=1 installers/install-auctions.sh` stops the
  units and removes the vhost; state and settings are kept.

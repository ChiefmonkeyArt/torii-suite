# ADR 0001 (Suite): The FIPS node on every install

Date: 2026-11-09. Status: **Accepted** (owner, 2026-11-09, "Build Suite
ADR 0001 as written"; raised by the owner, 2026-11-04: "FIPS on by
default across all apps", high priority after the Teams MVP; 2026-11-09:
"Suite first, then apps"). First of the FIPS-default ADRs: this one covers
only the Suite's node. Continuum and Quest get their own ADRs next. Plebeian
(market and CMS) is out of scope for now; the Suite only links to it.

## Context

Since v0.9.24-alpha the Suite can run a FIPS node (pinned upstream v0.5.3,
checksummed, binaries only; see `docs/FIPS.md`). But it is installed only as
a side step of the Quest installer (`install-quest.sh` calls
`install-fips.sh` when the home relay exists). So a node without Quest has
no FIPS, Teams' private git (`torii-teams-git`, mesh port 7334) depends on
Quest having run first, and nothing reports whether FIPS is up.

## Decision

1. **Its own stage, on by default.** `bootstrap.sh` gets a "FIPS node"
   stage straight after the relay stage. It runs `install-fips.sh` when
   `INSTALL_FIPS=1` (the default) and the home relay is installed
   (`INSTALL_NOSTR_GIT=1`, also the default), whatever apps are chosen.
2. **Same node, same limits.** No change to what `install-fips.sh` does:
   stable node key (never a personal nsec), zero peers until an operator
   enrols one, default-deny mesh firewall, only the relay on mesh port 7778
   plus the Teams `members` chain, 192 MiB and 20% CPU ceilings, 8 MiB
   volatile logs.
3. **No relay, no FIPS, said plainly.** With `INSTALL_NOSTR_GIT=0`,
   bootstrap warns "FIPS needs the node relay, skipping FIPS" and goes on,
   as it does for Teams today. The same goes for a host without a TUN
   device (`/dev/net/tun`), which `install-fips.sh` would otherwise refuse,
   failing the whole install. (Added while building.)
4. **Opt-out unchanged.** `INSTALL_FIPS=0` skips it on install and rerun.
   An independently managed FIPS (`/etc/fips/fips.yaml` or `fips.service`)
   is still never replaced.
5. **Quest and Teams just use it.** Quest keeps its idempotent call so the
   Quest updater still works on older boxes, but skips it when bootstrap's
   stage already ran in the same install (`TORII_FIPS_STAGE=1`); Teams no longer needs Quest
   first, only the FIPS stage.
6. **Status says whether it is up.** The doctor stage, after `torii
status`, runs `scripts/fips-status.sh`, which shows one line (`torii
status` itself lives in torii-base and is unchanged): FIPS running or not, and the number of peers. No mesh
   addresses, keys or hostnames are printed, because deploy logs end up on
   GitHub.
7. **Existing nodes.** Nothing changes until the operator deploys the new
   Suite tag; the existing `suite-stages-vps.yml` `fips` stage installs it
   alone. Each operator approves their own VPS.

## Consequences

- Every default Suite install has a FIPS node with no peers, ready for the
  app ADRs to use; about 21 MB on disk.
- Bootstrap gains one stage and one status line; no new download source, no
  new open port, no player or member setup.
- Installs without the relay are unchanged apart from the warning.

## Tests

- Bootstrap: the FIPS stage runs after the relay stage and before Quest and
  Teams; it is skipped with `INSTALL_FIPS=0`, and skipped with a warning
  when `INSTALL_NOSTR_GIT=0`.
- Status: the FIPS line shows running or not running and the peer count,
  and never an `fd…` address or npub.
- `test/install-fips.test.sh` unchanged and passing.

# Torii Teams services (TEAMS-2b)

Status: v0.9.26-alpha, opt-in (`INSTALL_TEAMS=1`). Decision record: Continuum
`docs/adr-team-collaboration.md`, addendum "TEAMS-2b packaging". The Torii Teams
app itself lives in `ChiefmonkeyArt/torii-teams`; v0.9.27-alpha adds its
opt-in installer (see "The app" below).

## What it installs

| Service | What | Reachable from |
|---|---|---|
| `torii-teams-coord` | Cordn coordinator ([cordn-rs](https://github.com/Cordn-msg/cordn-rs) `v0.5.1-next.3`, MIT) | Talks only to the node relay on `127.0.0.1:${NOSTR_RELAY_PORT}`. Members chat through the existing public `wss://relay.<domain>`; messages are MLS-encrypted end to end. |
| `torii-teams-git` | Private [ngit-grasp](https://ngit.dev/ngit-grasp.git) `v3.0.10` (MIT) | The FIPS mesh only: bound to this node's `fd..` address, port 7334, private mode. |
| `torii-teams-backup.timer` | Daily tarball of keys, member lists and both data directories | Root only, `/var/backups/torii-teams` (0700), keeps `TEAMS_BACKUP_KEEP` (7). |

The owner chose "chat public, git mesh" on 2026-10-31. Git has no public
nginx route; `NGIT_BASE_PATH` stays `/` and is reserved for a later public option.

Binaries are pinned by SHA-256. ngit-grasp has no upstream binary release, so
`.github/workflows/teams-deps.yml` builds it at commit `9493a5a` on Ubuntu 22.04
runners and publishes the `deps-ngit-grasp-v3.0.10` prerelease with build
provenance. No compiler runs on the VPS.

## The app (v0.9.27-alpha, `INSTALL_TEAMS_APP=1`)

`installers/install-teams-app.sh` serves the Torii Teams web app at
`https://teams.<domain>/` (`TORII_TEAMS_HOST`). Design: torii-teams
`docs/torii/adr-0001-node-mount.md`. It needs the services above
(`INSTALL_TEAMS=1`) and one more DNS A record, for `teams.<domain>`.

- Own origin, not `/teams/`: the app assumes it owns `/`, and a separate origin
  keeps chat keys in the browser apart from Quest and Continuum. The launcher
  tile `/teams/` redirects there.
- Prebuilt release from torii-teams (`<upstream>-torii.<n>` tags), checked
  against a SHA-256 pinned in the installer (never one fetched from the
  release). No build on the box. Releases in `/apps/teams-app/releases`, last 3
  kept, `current` flipped atomically. Upstream Cordn identity files
  (`.well-known/`) are dropped.
- `/etc/torii/teams/torii-node.json` (0644 root, outside the release tree) is
  served at `/torii-node.json`, no-store: version 1, the coordinator from
  `coord.pub` (the install fails closed if it is missing), `wss://relay.<domain>`,
  the mesh git URL when FIPS is up, and `continuum: https://<domain>` when
  Continuum is installed. On first open the app adds that coordinator as the
  preselected one; a member's own choice is never changed.
- On https the app uses only the `wss://` relay. The `.fips` git URL is for
  native clients and the CLI on the mesh (browsers block mixed content).
- Continuum member sign-in is cross-origin, so the installer adds
  `https://teams.<domain>` to the Continuum agent's `server.cors_origins`, and
  (v0.9.28-alpha) sets `teams.app_url` to it. Continuum's Team view shows "Open
  team chat" (`<app_url>/chat`) only when that is set. The agent restarts only
  when the config changed.
- Headers on every location: a per-build Content-Security-Policy (hashes of the
  inline start-up scripts; `connect-src 'self' https: wss:` because members
  upload to Blossom servers and may add relays), HSTS, `nosniff`,
  `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`, a Permissions-Policy
  allowing only the microphone (voice notes) and COOP. Only GET and HEAD.
- With no certificate yet (`SKIP_CERTBOT=1` or DNS not ready) the host answers
  plain text; the app is never served over HTTP. Rerun once DNS points here.

No release is pinned until the first torii-teams tag is approved. Until then the
installer stops with "no Torii Teams release pinned yet"; an operator can pin one
with both `TEAMS_APP_TAG` and `TEAMS_APP_SHA256`.

Tests: `bash test/install-teams-app.test.sh` (any user) and
`sudo bash test/teams-app-live.sh [artifact.tar.gz]` (throwaway host: real nginx,
self-signed cert, served headers, wrong checksum, missing `coord.pub`). CI:
`teams-app.yml`.

## Files

- `/etc/torii/teams/coord.key` (0600, root): coordinator service key, generated
  once and passed to the service with `LoadCredential`. Never a person's nsec.
  `coord.pub` is the pubkey members' app uses.
- `/etc/torii/teams/git-members`: one npub per line; private git admits only
  these. First install seeds `TEAMS_OWNER_NPUB` (default `CONTINUUM_ADMIN_NPUB`).
- `/etc/torii/teams/member-nodes`: one FIPS device npub per line. Only these
  devices can open the mesh git port.
- `/etc/torii/fips/fips.d/teams.nft`: generated allow list, loaded by the Suite
  FIPS firewall through the new `members` chain. Do not edit.
- `/var/lib/torii-teams/{coord,git}`: data, one system user per service.

Reruns never replace the key or the member lists. TEAMS-2a-4 will write the two
member files from the signed roster; until then the operator edits them.

## Operating

```bash
sudo torii-teams status
sudo torii-teams apply     # after editing git-members or member-nodes
sudo torii-teams backup
```

`apply` validates the whole firewall with `nft -c` before reloading, then
restarts git. Git is skipped (not failed) until FIPS is installed and there is
at least one member.

Members map the shortname to this node in their own FIPS hosts file
(`torii-teams <node npub>`) and use `http://torii-teams.fips:7334`. Never use
`<npub>.fips` as the git host: ngit truncates URLs at the first `npub1`.

## Restore

```bash
sudo systemctl stop torii-teams-git torii-teams-coord
sudo tar -C / -xzf /var/backups/torii-teams/torii-teams-<stamp>.tar.gz
sudo systemctl start torii-teams-coord torii-teams-git
```

## Migrating from the FIPS trial

The trial (`ops/fips-trial` in torii-continuum) also binds port 7334, so the
installer refuses to run while it is up. After the trial ends: run the trial's
`action=teardown`, optionally copy the trial coordinator key into
`/etc/torii/teams/coord.key` (0600) to keep existing chat groups, then install.

## Hardening

Both units: dedicated user, `ProtectSystem=strict`, no capabilities,
`MemoryDenyWriteExecute`, private `/tmp` and devices. The coordinator also has
`IPAddressDeny=any` with loopback allowed. Git keeps outbound network for now;
narrowing it to loopback and `fd00::/8` needs a push/fetch proof first.

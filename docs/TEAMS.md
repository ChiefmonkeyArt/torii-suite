# Torii Teams services (TEAMS-2b)

Status: v0.9.26-alpha, opt-in (`INSTALL_TEAMS=1`). Decision record: Continuum
`docs/adr-team-collaboration.md`, addendum "TEAMS-2b packaging". The Torii Teams
app itself lives in `ChiefmonkeyArt/torii-teams`.

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

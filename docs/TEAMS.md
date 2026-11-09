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
  team chat" (`<app_url>/chat`) only when that is set. The node file's
  `continuum` is `https://$CONTINUUM_HOST` when set (v0.9.31), else
  `https://<domain>`; with it, the app's sidebar is one channel per project. The agent restarts only
  when the config changed.
- Headers on every location: a per-build Content-Security-Policy (hashes of the
  inline start-up scripts). With the node file server (default with Continuum,
  v0.9.37-alpha) the app may connect only to itself, Continuum and the node
  relay (`connect-src 'self' blob: https://<continuum host> wss://<relay host>`)
  and show images and media only from itself (`img-src 'self' data: blob:`).
  Without it, `connect-src 'self' blob: https: wss:` because members upload to
  public Blossom servers. `blob:` lets the app read files a member picks;
  it is not a network source. Also HSTS, `nosniff`,
  `frame-ancestors` limited to the Continuum hosts (`https://$CONTINUUM_HOST`
  when set, see docs/CONTINUUM-HOST.md, and `https://<domain>`) so Continuum's Team view can embed the app
  (torii-teams ADR 0002), or `'none'` without Continuum; no `X-Frame-Options`
  (v0.9.30-alpha). Also `Referrer-Policy: no-referrer`, a Permissions-Policy
  denying geolocation, microphone, camera and payment (v0.9.34-alpha; before
  that it allowed the microphone for voice notes), and COOP. Only GET and HEAD.
- With no certificate yet (`SKIP_CERTBOT=1` or DNS not ready) the host answers
  plain text; the app is never served over HTTP. Rerun once DNS points here.

### Removal finishes before you leave (v0.9.46-alpha, torii-teams ADR 0015)

After a Continuum save, the embedded Teams answers `torii:roster-synced`
`{slug, left, error}` (counts only, exact origin), and the Team page says
when a removed person is out of the chat. Needs Continuum v0.2.202-alpha;
either alone keeps the old behaviour. Pin only: no installer or CSP change.
Deploy Continuum, then `teams_app`.

### Shisa icons and logo (v0.9.45-alpha, torii-teams ADR 0014)

The tab and home-screen icons are the two painted shisa heads (the release
replaces the plain "T"), and the plain sign-in card shows the painted logo.
The install icons ship in `pwa/` but the app no longer downloads them on a
first visit; the browser fetches them when someone installs Teams. Pin only:
no installer, CSP or Continuum change. Deploy `teams_app`.

### One shisa look (v0.9.44-alpha, torii-teams ADR 0013)

The welcome art is one painted shisa pair at a laptop (44 KB, in the release),
washed in the theme colour on coloured themes. Pin only: no installer, CSP or
Continuum change. Deploy `teams_app`.

### Remove while away, gzip (v0.9.43-alpha, torii-teams ADR 0012)

Any member's Teams removes people the owner took off the project, even while
the owner is away; it uses the signed member list Continuum already serves.
Invite links get a QR code (Continuum v0.2.201-alpha). The installer now
writes a `.gz` copy of each text file in the release (`gzip -9 -k -n`, files
over 1 KB) and the vhost has `gzip_static on; gzip_vary on;`: about 1.8 MB to
about 565 KB on a first visit, with no per-request work. Static files only, so
no secrets go through compression. Deploy Continuum first, then `teams_app`.

### Join while the owner is away (v0.9.42-alpha, torii-teams ADR 0011)

People let in join the chat themselves, with nobody else online. Members'
Teams clients keep a GroupInfo "join card" on Continuum (no key; the node
can't read the chat), and the newcomer's client joins from it with the
owner-signed member list or grant as proof. Needs Continuum v0.2.200-alpha
(`/api/projects/:slug/teams/groupinfo`); with an older Continuum the owner's
client adds people as before. No Suite config changes: the app only talks to
the Continuum host it already allows. Deploy Continuum first, then
`teams_app`.

### Joining that works (v0.9.40-alpha, torii-teams ADR 0010)

A personal link (Continuum's Add person) lets the person straight in. A group
link either asks the owner first (the default) or lets people straight in
under one owner-signed grant (kind 27098) that sets its places and expiry.
Group links default to the seats left on the project instead of one use.
Continuum keeps one hidden Teams frame open after the owner signs in, so the
owner's client adds people from any Continuum page. Embedded, Teams hides its
own account footer. No Suite config changes: the existing `frame-src` and
`frame-ancestors` already cover every Continuum page. Needs Continuum
v0.2.199-alpha (an older Continuum keeps the torii.9 behaviour: group links ask
first). Deploy Continuum first, then `teams_app`.

### Invite links (v0.9.39-alpha, torii-teams ADR 0009)

The owner copies a link in Continuum's Team view:
`https://<teams host>/chat/join/<id>#<secret>`. The secret is in the fragment,
so it never reaches nginx logs or a `Referer`; Teams reads it at startup and
clears the address bar. Continuum stores only a hash of it. An open link lets
anyone holding it ask to join; the owner presses Let in (one roster signature)
or Decline. A named link signs only the listed person in. The vhost's
`try_files $uri /index.html` already serves `/chat/join/...`; no Suite config
changes. Needs Continuum v0.2.198-alpha (older Continuum answers every link as
"no longer works"; plain sign-in is unaffected). Deploy Continuum first, then
`teams_app`.

### One sign-in (v0.9.38-alpha, torii-teams ADR 0008)

Teams shows one consent card and asks the signer once (remote signers get every
permission in the connect request). The Continuum team session is kept in the
Teams origin's localStorage and renewed with `POST /api/team/auth/refresh` (no
signer) until Continuum's `session_max_lifetime_sec` (7 days). Inside
Continuum's Team view the owner's session is handed to the frame by
`POST /api/team/auth/handoff`. No Suite config changes; CORS already allows the
Teams origin. Needs Continuum v0.2.197-alpha; deploy Continuum first, then
`teams_app`.

### Node file server (v0.9.37-alpha, torii-teams ADR 0007)

With Continuum, images and files sent in Teams are stored on this server, not
on public Blossom hosts. `torii-teams-files` (`/opt/torii/teams-files/server.mjs`,
Node built-ins only) listens on `127.0.0.1:${TEAMS_FILES_PORT:-8805}` and nginx
serves it at `https://<teams host>/files/`. It runs as a systemd `DynamicUser`
with its data in `/var/lib/torii-teams-files` and settings in
`/etc/torii/teams/files.env`.

- Uploads (`PUT /files/upload`) and deletes need the member's Continuum Teams
  session (`Authorization: Bearer`). The server asks Continuum
  `GET /api/team/files-ok` over loopback and caches the answer for 60 s. Only
  the owner or someone on a project roster may store files; only the uploader
  or the owner may delete one.
- Reads are open: every blob is end-to-end encrypted. They are sent as
  `application/octet-stream`, `attachment`, `nosniff` and
  `Content-Security-Policy: default-src 'none'; sandbox`.
- Limits: `TEAMS_FILES_MAX_MB` per file (default 100) and `TEAMS_FILES_QUOTA_GB`
  in total (default 10).
- The node file gains `"files": "https://<teams host>/files"`. Teams then uses
  only the node: no public upload fallback, and media stored elsewhere shows
  "Stored outside this node". Images sent before this release that are on
  public Blossom no longer show.
- `TEAMS_FILES=0` keeps the old behaviour (public Blossom, wide CSP). Without
  Continuum it is always off.

Pinned release (v0.9.46-alpha): torii-teams `0.6.1-torii.16` (commit 68bcc62),
SHA-256 `ca8e4cb692fd32fca623a5cea82b40e96847e00487269d7b1666f013e4b917b5`. An operator can pin another one with both `TEAMS_APP_TAG` and
`TEAMS_APP_SHA256`.

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

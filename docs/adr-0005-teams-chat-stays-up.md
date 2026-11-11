# ADR 0005 (Suite): Teams chat stays up

Date: 2026-11-11. Status: **Accepted** (owner, 2026-11-11: "Accept, ship and deploy"; asked by owner, 2026-11-11: "do all the
things", after a live test with a second person where messages never reached
the other screen). Target: Suite `v0.9.69-alpha` (stage `teams`), with Teams
`0.6.1-torii.21` (torii-teams ADR 0020).

## Context

- On 2026-11-11 the chat coordinator (`torii-teams-coord`) was
  `inactive (dead) since 04:22:46 UTC` until the owner restarted it at about
  16:45. For those 12 hours every message looked sent on the sender's screen
  and never reached anyone else. The relay stayed up the whole time.
- The daily backup timer fires at 04:20 with up to 30 minutes of random delay.
  `torii-teams backup` stops git and the coordinator for a consistent copy,
  writes the tarball, then starts them again.
- That night the disk was full. The tarball write failed, `set -e` ended the
  script, and the EXIT trap that should start the services again read a
  function-local array that no longer existed: `was: unbound variable`.
  Nothing was started again. Reproduced in a plain bash test.
- A stop by `systemctl stop` is a clean stop, so `Restart=on-failure` does not
  apply. Nothing else noticed: the journal had been cleared while freeing
  space, and the only sign was in the Teams client.
- The failed run also leaves a partial `*.tar.gz.part` behind, which takes more
  of the disk that was already full.

## Decision

1. **The backup always starts again what it stopped.** The list of stopped
   services is global, so the EXIT trap can still read it. A failed run removes
   its `.part` file. Before stopping anything, the backup checks that the disk
   has room for the copy (the size of the data plus 64 MiB). If it doesn't, the
   backup is skipped, nothing is stopped, and the reason is logged.
2. **The coordinator restarts after any exit.** `Restart=always` (5 s apart,
   no start limit) instead of `Restart=on-failure`, so a clean exit of the
   binary (for example on a write error) is also recovered. Git keeps
   `Restart=on-failure`: until FIPS and a member exist its `ExecCondition`
   skips it, and `always` would retry that skip every 5 seconds.
3. **A one-minute check.** New `torii-teams-watch.timer` runs `torii-teams
   watch` every minute: any enabled Teams service that is not running is
   started, and one line goes to the journal (`torii-teams-watch`). Git is
   checked only when its own start condition passes, so an unconfigured git
   stays quiet. It skips
   while a backup holds the shared lock, and it does nothing while
   `/etc/torii/teams/paused` exists (an operator's deliberate stop:
   `torii-teams pause` / `torii-teams resume`). It also logs a warning when
   the Teams data disk has less than 256 MiB free.
4. **The client says so.** Teams shows "Chat server is down" when the node
   coordinator stops answering (torii-teams ADR 0020). Continuum's Team page
   shows it through the embedded chat, so Continuum needs no change.

## Consequences

- A stuck backup or a crash costs at most about a minute of chat, not a day.
- An operator who wants the chat down must use `torii-teams pause`; a plain
  `systemctl stop` is undone within a minute. The command is listed in
  `docs/TEAMS.md`.
- The check runs as root (it starts system units). It reads only
  `systemctl` state and `df`, writes only to the journal, and takes the same
  lock as the backup.
- The watch checks that the process runs, not that it answers. A process that
  runs but doesn't answer is caught by the client warning (ADR 0020), not
  restarted.

## Tests

- `test/install-teams.test.sh`: unit and timer contracts, and behaviour with
  stubbed `systemctl`, `tar` and `df`. A failed tarball still starts both
  services and removes the `.part` file. A full disk skips the backup without
  stopping anything. `watch` starts a stopped service, does nothing while
  paused, and skips while the lock is held.
- `teams-build.yml` (real systemd): `systemctl stop torii-teams-coord` is
  undone by `torii-teams watch`; the watch timer is armed.

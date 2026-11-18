# ADR 0007 (Suite): Continuum's project AI gets the chat server's key and relay

Date: 2026-11-18. Status: **Accepted** 2026-11-18 after the local review
(owner: "Yes and do all the things still to do"). Proposed by the owner
(2026-11-18: "@mentions first, both model options with the label, and Owners
and Maintainers only to begin with." / "Let's go with this"). Target: Suite
`v0.9.79-alpha` (stage `teams_app`), with Continuum `v0.2.214-alpha`
(`docs/adr-team-ai-member.md`) and Teams `0.6.1-torii.28` (torii-teams ADR 0024).

## Context

Continuum's project AI member joins the node's Teams chats as a Cordn client
from the agent itself. To do that it needs the node's chat server
(coordinator) pubkey and a relay to reach it. Continuum's config has no way to
learn them; the Suite already holds both (`/etc/torii/teams/coord.pub` and
`RELAY_PORT` in `/etc/torii/teams/teams.env`). Without them the AI stays off
and Continuum's Team page shows no Project AI box.

## Decision

1. `install-teams-app.sh` step 5 (with Continuum) also writes
   `teams.coordinator: "<coord.pub hex>"` and
   `teams.relay: "ws://127.0.0.1:<RELAY_PORT>"` into Continuum's `config.yaml`,
   beside `teams.app_url`. `RELAY_PORT` comes from `teams.env` (default 7777).
2. The relay is the node relay on loopback: the agent and the relay are on the
   same host, so the AI's traffic never leaves it. The Cordn link itself is
   still transport-encrypted. `teams_continuum_config` accepts only a 64-hex
   key and `ws://127.0.0.1:<port>` or `wss://<host>`, and replaces existing
   lines in place (idempotent; the agent restarts only when something changed).
3. Pins torii-teams `0.6.1-torii.28`, which shows the AI's label and the
   "only Owners and Maintainers can ask" hint.

## Consequences

- One deploy of stage `teams_app` after Continuum v0.2.214-alpha turns the AI
  on for an existing node; the owner still adds it per project on the Team
  page.
- No new service, port or firewall change. Nodes without Continuum are
  unchanged.
- Tests: `test/install-teams-app.test.sh` (keys written, replaced,
  idempotent; bad key and off-loopback `ws://` refused).

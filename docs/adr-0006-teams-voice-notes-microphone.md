# ADR 0006 (Suite): The microphone for Teams voice notes, and only Teams

Date: 2026-11-12. Status: **Accepted** 2026-11-12 after a local review (owner:
"Accept and ship"). Proposed (owner, 2026-11-12: "Do all the things
1-9", item 9: voice notes in the project chat). Target: Suite `v0.9.73-alpha`
(stages `continuum_host`, `teams_app`), with Teams `0.6.1-torii.25`
(torii-teams ADR 0023) and Continuum `v0.2.212-alpha`.

## Context

Teams ADR 0005 dropped voice notes, so since v0.9.34/v0.9.36 both hosts deny
the microphone to every origin: the Teams app sends
`Permissions-Policy: microphone=()` and Continuum's host sends
`microphone=()`. Teams ADR 0023 brings voice notes back to project chats. A
framed page can use the microphone only when all three agree: the top page's
policy lists the frame's origin, the iframe has `allow="microphone"`, and the
frame's own policy allows itself.

## Decision

1. Teams app: `microphone=(self)`. Geolocation, camera and payment stay `()`.
2. Continuum host: `microphone=("https://<teams host>")` when a Teams host is
   set; Continuum itself gets no microphone. With no Teams host it stays `()`.
3. Continuum's frame carries `allow="clipboard-write; microphone"`.
4. The browser still asks the person the first time they hold the mic button.

## Consequences

- Tests: `install-continuum-host.test.sh`, `continuum-host-live.sh` and
  `install-teams-app.test.sh` check the exact policies.
- Deploy runs the `continuum_host` and `teams_app` stages.
- Other apps (Quest, auctions) keep `microphone=()`.

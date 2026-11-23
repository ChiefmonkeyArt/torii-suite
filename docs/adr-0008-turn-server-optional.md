# ADR 0008 (Suite): your own TURN server for voice calls, optional

Date: 2026-11-23. Status: **Accepted** (owner, 2026-11-23: "Yes to all these
things", answering "set up coturn on your VPS using docs/CALLS.md"). Target:
Suite `v0.9.81-alpha`, with Continuum's `suite-stages-vps.yml` stage `turn`.

## Context

- Torii Companion 0.9.0 (Tab5) makes voice calls with 0xchat users: Nostr
  signalling (kind 25050 in NIP-59 wraps) and WebRTC audio, sealed with
  DTLS-SRTP.
- A direct path fails behind strict routers, mobile carriers and many hotel or
  office networks. The call then rings but has no audio unless both sides can
  reach a TURN relay.
- Public TURN services (Google, Twilio, Cloudflare and others) see who calls
  whom, when, and from which IP. The Tab5 contacts none by default.
- With "Hide my IP", the Tab5 offers only relay addresses, so a caller never
  learns the owner's home IP. That needs a relay the owner trusts.

## Decision

1. New opt-in stage `turn` (`INSTALL_TURN=1`, `installers/install-turn.sh`):
   coturn from the distribution, configured before the package is unpacked so
   it never starts with the open default config.
2. One long-term login (`torii`, 32 random characters), kept root-only in
   `/etc/torii/turn/credentials` and kept across re-runs
   (`TORII_TURN_ROTATE=1` makes a new one). The owner types it into the Tab5
   (Settings > Calls), where it is stored sealed.
3. Relays refuse every special-purpose address (RFC 6890: loopback, private,
   link-local, CGNAT, documentation, multicast, IPv6 ULA/link-local). The
   server's own public address stays allowed so two callers relaying through
   it can reach each other; services on that address are already public.
4. UDP relays only (`no-tcp-relay`), no CLI, no TLS listener, no software
   banner, 20 relay ports (49160-49179), 10 allocations in total and 64 kB/s
   per allocation. A personal server, not an open relay.
5. Listens on the main IPv4 address only, never on FIPS, Docker or loopback.
6. Logs go to a volatile journal namespace (1 day, 8 MB). No log files.
7. When ufw is active it opens 3478 udp/tcp and the relay ports, nothing else.
   A provider firewall must be opened by the owner.
8. apt is retried as root (`APT::Sandbox::User=root`) when its sandbox user
   cannot resolve the mirrors, as seen on chiefmonkey.art in v0.9.66.

## Consequences

- Calls connect from almost any network, and "Hide my IP" works without any
  outside service. The relay passes sealed packets and cannot hear calls.
- Bandwidth: about 10 kB/s per relayed call leg.
- The password is a shared secret on the owner's devices. If it leaks, the
  limits cap misuse; rotate with `TORII_TURN_ROTATE=1`.
- Not yet: TURN over TLS on 443 (for networks that block UDP), time-limited
  credentials, IPv6 relays.

# TURN server for voice calls

Your own relay for Torii Companion (Tab5) and 0xchat calls (ADR 0008).

## Why

- Calls connect even when a router or mobile network blocks a direct path.
- With "Hide my IP" on the Tab5, callers only see your server, never your home.
- No Google, Twilio or Cloudflare relay sees who you call. Audio stays
  end-to-end encrypted; the relay cannot hear it.

## Install

Set `INSTALL_TURN=1` in `.env` and run the installer, or run the stage alone
(Continuum's `suite-stages-vps.yml`, stage `turn`). Then show the login:

```bash
sudo cat /etc/torii/turn/credentials
```

On the Tab5: Settings > Calls > Your TURN server. Enter the `server`, `user`
and `password` lines, then turn on Hide my IP if you want it.

If your provider has its own firewall, open 3478 udp and tcp, and
49160-49179 udp.

## Change the password

Run the stage again with `TORII_TURN_ROTATE=1`, then update the Tab5.

## Behind 1:1 NAT

If the server's own address is private, set `TORII_TURN_EXTERNAL_IP` to its
public IPv4 address.

## What it refuses

Relays to loopback, private, link-local, CGNAT and other special addresses,
TCP relays, and more than 10 allocations at once. Logs are kept in memory for
one day at most.

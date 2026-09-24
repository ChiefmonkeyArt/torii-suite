# FIPS background node integration

Candidate release v0.9.24-alpha, paired with Quest v0.2.886-alpha. This is the first two-node implementation slice, not the broader hybrid/collector rollout.

## Player behavior

Nothing to install, approve or configure as a player. Existing controls, world downloads and multiplayer continue on the existing paths. The node checks public heartbeat availability in the background and falls back to ordinary WSS if FIPS is unavailable.

## Operator provisioning

The Suite Quest installer calls `installers/install-fips.sh` before changing the active application when a local strfry config is present. It extracts only the two required binaries from the [pinned upstream v0.5.1 package](https://github.com/jmcorgan/fips/releases/tag/v0.5.1), verifies an embedded SHA-256 and does not execute upstream package scripts or alter global DNS.

The installer requires root, TUN, a local relay, nginx, Node and 256 MiB free disk headroom. It refuses an independently managed `/etc/fips/fips.yaml` or active `fips.service`. Generated configuration lives under `/etc/torii/fips`; the node's private key stays root-only and is preserved across reruns. No personal nsec is accepted.

Fresh nodes start with zero configured peers. The component is installed, but a two-node exchange cannot be claimed until both operators approve installation and exchange transport identities. This intentional bootstrap step is operator work, never player setup.

## Known-peer enrollment

Obtain the other node's public `/etc/torii/fips/fips.pub`, expected heartbeat signer, owner pubkey, zone ID and canonical world URL through an operator-verified channel. Confirm the heartbeat signer against their running home relay; the event's self-asserted owner tag alone is insufficient.

Write `/etc/torii/fips/peers.json` as root, mode 0644, using this schema and replacing placeholders:

```json
{
  "version": 1,
  "peers": [{
    "transportNpub": "npub1...",
    "beaconPubkey": "64 lowercase hex characters",
    "ownerPubkey": "64 lowercase hex characters",
    "zoneId": "quest-torii",
    "website": "https://peer.example/quest/"
  }]
}
```

At most one peer is permitted. Rerun the installer from the reviewed Suite tag and restart Quest to reload the pins. The generated FIPS YAML is derived from this file and should not be edited separately.

Both VPS/provider firewalls must permit UDP 2121 between the two public hosts. The installer does not disable or broaden a pre-existing host firewall. This slice uses static UDP endpoints derived from the verified world hostname, not open discovery or NAT traversal. Changes to endpoint policy need a separate review.

Only the npub-derived mesh IPv6 on port 7778 proxies to the existing loopback strfry port. The main nginx process and admin services are not exposed through the mesh. The strfry service remains a public relay with its existing policy; this proxy is not a new private-access grant or a new relay write policy.

## Resource and storage budget

- **Binary footprint:** install only `fips` and `fipsctl`, approximately 20.7 MB in the verified amd64 package before filesystem overhead. Download/extraction temporary files are removed on exit; platform dependencies can add more.
- **Identity/configuration:** small persistent root-owned files; no browser or owner secret copied to the node.
- **Heartbeats:** Quest holds one latest peer event in RAM, at most 8 KiB, with original expiry. It does not persist the remote event or replicate relay history.
- **Logs:** an 8 MiB volatile journal namespace shared by FIPS and its mesh proxy. Access logs are disabled; no writable profiler directory is granted.
- **Runtime ceilings:** FIPS 192 MiB and 20% of one CPU; proxy 64 MiB and 10%. These are initial protection limits, not measured steady-state consumption.
- **Visited worlds:** this integration never fetches, pins, imports or republishes their assets. Existing world loading, browser cache and strfry storage policy remain unchanged.

## Verification and rollback

`GET /mp/node-presence` exposes only a bounded public signed event plus route provenance (`fips` versus `wss`) and timestamps. An empty event list is not proof the world is globally offline. An invalid/absent peer configuration disables the optional read path without stopping Quest.

The GitHub build test provisions a fresh runner twice, checks stable key identity and service readiness, and validates firewall syntax. Quest's separate real-network harness tests two FIPS daemons in isolated namespaces, both heartbeat directions, outage, recovery, forged rejection and blocked wildcard admin ports. Mocked tests do not substitute for this proof.

For rollback, stop and disable `torii-fips-relay.service` and `torii-fips.service`, keep the default-deny firewall rules, and set the peer list to empty before restarting Quest. Set `INSTALL_FIPS=0` to prevent future provisioning. Do not remove the transport key unless deliberately retiring that node identity; do not delete any relay database or owned world.

Before production acceptance, complete the coordinated PR/tag/live release process, operator-approved peer enrollment, real strfry exchange, resource/storage soak and the player-performance thresholds recorded in [Quest ADR-0125](https://github.com/ChiefmonkeyArt/torii-quest/blob/feat/fips-two-node-presence/docs/adr/0125-fips-two-node-background-presence.md). No live rollout is implied by this candidate documentation.

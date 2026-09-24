// Installer-only: no private signing key is read or accepted here.
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';

export function renderConfig(input, addressFor) {
  if (input.version !== 1 || !Array.isArray(input.peers) || input.peers.length > 1) {
    throw new Error('expected one remote peer at most');
  }
  const peers = input.peers.map(p => {
    if (!/^[0-9a-f]{64}$/.test(p.beaconPubkey) || !/^[0-9a-f]{64}$/.test(p.ownerPubkey)
      || typeof p.zoneId !== 'string' || !p.zoneId || p.zoneId.length > 128) throw new Error('invalid heartbeat pin');
    const url = new URL(p.website);
    if (url.protocol !== 'https:' || url.username || url.password || url.port || url.search || url.hash
      || !/^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$/i.test(url.hostname)
      || /\.(local|localhost|internal|test|invalid)$/i.test(url.hostname)) throw new Error('expected public world HTTPS URL');
    if (!/^npub1[023456789acdefghjklmnpqrstuvwxyz]{58}$/.test(p.transportNpub)
      || !/^fd[0-9a-f:]+$/i.test(addressFor(p.transportNpub))) throw new Error('invalid FIPS identity');
    return {
      npub: p.transportNpub,
      addresses: [{ transport: 'udp', addr: `${url.hostname}:2121` }],
      connect_policy: 'auto_connect',
    };
  });
  // JSON is a YAML subset accepted by FIPS. No new global DNS routes, adverts,
  // open discovery, relay forwarding policy, or personal identity broadcast.
  return {
    node: {
      identity: { persistent: true }, log_level: 'warn',
      control: { socket_path: '/run/torii-fips/control.sock' },
    },
    tun: { enabled: true, name: 'fips0', mtu: 1280 },
    dns: { enabled: false },
    transports: { udp: { bind_addr: '0.0.0.0:2121' } },
    peers,
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [input, output, ctl] = process.argv.slice(2);
  const text = readFileSync(input, 'utf8');
  if (Buffer.byteLength(text) > 4096) throw new Error('peer file exceeds 4 KiB');
  const config = renderConfig(JSON.parse(text), npub =>
    execFileSync(ctl, ['address', npub], { encoding: 'utf8', timeout: 2000 }).trim());
  writeFileSync(output, JSON.stringify(config, null, 2) + '\n', { mode: 0o600 });
}

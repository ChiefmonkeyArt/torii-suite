// Root helper (torii-continuum docs/adr-fips-default.md §4): turn an
// operator-signed peer list, dropped by the unprivileged Continuum agent,
// into /etc/torii/fips/peers.json + fips.yaml. The agent can only pass the
// operator's signed words through; it can't write peers itself.
//
//   node apply-peer-request.mjs <request> <admin.npub> <last> <peers.out> <yaml.out> <fipsctl>
//
// Exit 0 with "peers: N" when applied, 3 when there is nothing new, 1 on refusal
// (one-line reason, never file contents).
import { readFileSync, writeFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { verifyNostrEvent, npubToHex } from './schnorr.mjs';
import { renderConfig, MAX_PEERS } from './render-config.mjs';
import { readAgentFile } from './agent-file.mjs';

export const PEER_REQUEST_KIND = 27532;
export const PEER_REQUEST_TAG = 'torii-fips-peers';
export const MAX_REQUEST_BYTES = 16384;
const FIELDS = ['transportNpub', 'beaconPubkey', 'ownerPubkey', 'zoneId', 'website'];

/** Validate a parsed request against the admin and the last applied time. */
export function checkRequest(body, { adminHex, lastAt = 0, now = Math.floor(Date.now() / 1000) }) {
  if (!/^[0-9a-f]{64}$/.test(adminHex || '')) throw new Error('no node admin configured');
  const e = body?.event;
  if (!verifyNostrEvent(e)) throw new Error('signature does not verify');
  if (e.kind !== PEER_REQUEST_KIND) throw new Error('wrong kind');
  if (!e.tags.some((t) => t[0] === 't' && t[1] === PEER_REQUEST_TAG)) throw new Error('missing tag');
  if (e.pubkey !== adminHex) throw new Error('not signed by this node\'s admin');
  if (e.created_at <= lastAt) throw new Error('not newer than the last applied list');
  if (e.created_at > now + 600 || e.created_at < now - 86400) throw new Error('request time out of range');
  const content = JSON.parse(e.content);
  if (content?.version !== 1 || !Array.isArray(content.peers) || content.peers.length > MAX_PEERS) {
    throw new Error(`expected a list of at most ${MAX_PEERS} peers`);
  }
  // Keep only the five known fields; renderConfig checks every one of them.
  const peers = content.peers.map((p) => Object.fromEntries(FIELDS.map((k) => [k, p?.[k]])));
  return { peers, createdAt: e.created_at };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [request, adminFile, lastFile, peersOut, yamlOut, ctl] = process.argv.slice(2);
  try {
    let lastAt = 0;
    try { lastAt = Number(readFileSync(lastFile, 'utf8').trim()) || 0; } catch { /* first run */ }
    const adminHex = npubToHex(readFileSync(adminFile, 'utf8').trim());
    let body;
    try { body = JSON.parse(readAgentFile(request, MAX_REQUEST_BYTES)); } catch (e) {
      throw new Error(e.message.startsWith('request') ? e.message : 'request is not readable JSON');
    }
    const { peers, createdAt } = checkRequest(body, { adminHex, lastAt });
    const input = { version: 1, peers };
    const yaml = renderConfig(input, (npub) =>
      execFileSync(ctl, ['address', npub], { encoding: 'utf8', timeout: 2000 }).trim());
    writeFileSync(peersOut, JSON.stringify(input) + '\n', { mode: 0o644 });
    writeFileSync(yamlOut, JSON.stringify(yaml, null, 2) + '\n', { mode: 0o600 });
    writeFileSync(lastFile + '.next', String(createdAt) + '\n', { mode: 0o644 });
    console.log(`peers: ${peers.length}`);
  } catch (e) {
    if (/not newer/.test(e.message)) { console.log('nothing new'); process.exit(3); }
    console.error(`torii-fips-peers: refused: ${e.message}`);
    process.exit(1);
  }
}

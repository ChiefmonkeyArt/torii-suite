// Root helper for torii-teams sync (torii-continuum docs/adr-fips-default.md
// §3, torii-teams ADR 0016): turn the Continuum agent's mesh file into
// /etc/torii/teams/git-members and member-nodes. Root believes only
// signatures: a person comes from an owner-signed member list (kind 30098)
// or an owner-signed invite grant (kind 27098, within its use limit); a
// computer comes only from that person's own device note (kind 27531).
//
//   node mesh-sync.mjs <mesh.json> <owner.npub> <state.json> <git-members.out> <member-nodes.out>
//
// Exit 0 with a one-line summary; 1 on refusal (one-line reason, nothing
// written). Writes <state.json>.next for the caller to keep once installed.
import { readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { verifyNostrEvent, npubToHex, hexToNpub } from '../fips/schnorr.mjs';
import { readAgentFile } from '../fips/agent-file.mjs';

export const ROSTER_KIND = 30098;
export const GRANT_KIND = 27098;
export const DEVICE_KIND = 27531;
export const DEVICE_TAG = 'torii-teams-devices';
export const MAX_MESH_BYTES = 1024 * 1024;
export const MAX_PROJECTS = 64;
export const MAX_HUMANS = 12;
export const MAX_ENTRIES = 32;
export const MAX_DEVICES = 3;
const HEX64 = /^[0-9a-f]{64}$/;
const SLUG = /^[a-z0-9][a-z0-9-]{0,47}$/;
const LISTED = new Set(['maintainer', 'contributor', 'viewer']);
const HEADER = '# Written from Continuum by torii-teams sync. Do not edit.';

const refuse = (m) => { throw new Error(m); };
const tagValue = (e, name) => {
  const all = e.tags.filter((t) => Array.isArray(t) && t[0] === name);
  return all.length === 1 && typeof all[0][1] === 'string' ? all[0][1] : null;
};
const signed = (e, kind) => e && typeof e === 'object' && e.kind === kind && Array.isArray(e.tags)
  && Number.isInteger(e.created_at) && verifyNostrEvent(e);

/** Owner-signed member list → { created_at, members:Set, humans:Set } or throws. */
function checkRoster(e, slug, owner) {
  if (!signed(e, ROSTER_KIND) || e.pubkey !== owner) refuse(`${slug}: member list not signed by the owner`);
  if (e.content !== '' || tagValue(e, 'd') !== slug || e.tags.length > MAX_ENTRIES + 4) refuse(`${slug}: bad member list`);
  const members = new Set([owner]), humans = new Set([owner]);
  for (const t of e.tags) {
    if (!Array.isArray(t) || t[0] !== 'p') continue;
    const [, pk, role, of] = t;
    if (!HEX64.test(String(pk)) || members.has(pk)) refuse(`${slug}: bad member entry`);
    if (role === 'agent') { if (!HEX64.test(String(of))) refuse(`${slug}: bad agent entry`); }
    else if (LISTED.has(role)) humans.add(pk);
    else refuse(`${slug}: unknown role`);
    members.add(pk);
  }
  if (humans.size > MAX_HUMANS) refuse(`${slug}: more than ${MAX_HUMANS} people`);
  return { created_at: e.created_at, members, humans };
}

/** Owner-signed invite grant for this project → { id, role, uses } or null. */
function checkGrant(e, slug, owner) {
  if (!signed(e, GRANT_KIND) || e.pubkey !== owner || e.content !== '') return null;
  const uses = Number(tagValue(e, 'uses'));
  const role = tagValue(e, 'role');
  if (tagValue(e, 'project') !== slug || !LISTED.has(role) || !Number.isInteger(uses) || uses < 1 || uses > 11) return null;
  return { id: e.id, role, uses };
}

function checkDeviceNote(e) {
  if (!signed(e, DEVICE_KIND) || !e.tags.some((t) => Array.isArray(t) && t[0] === 't' && t[1] === DEVICE_TAG)) return null;
  let c;
  try { c = JSON.parse(e.content); } catch { return null; }
  if (c?.v !== 1 || !Array.isArray(c.devices) || c.devices.length > MAX_DEVICES) return null;
  const npubs = c.devices.map((d) => d?.npub);
  if (!npubs.every((n) => npubToHex(n))) return null;
  return [...new Set(npubs)];
}

/**
 * Pure check. Returns the two lists and the next state, or throws.
 * @param {object} mesh  parsed mesh file
 * @param {{owner:string, state?:{rosters?:object, devices?:object}}} ctx
 */
export function checkMesh(mesh, { owner, state = {} }) {
  if (!HEX64.test(owner || '')) refuse('no project owner configured');
  if (mesh?.version !== 1 || !Array.isArray(mesh.projects) || !Array.isArray(mesh.devices)) refuse('not a mesh file');
  if (mesh.projects.length > MAX_PROJECTS) refuse(`more than ${MAX_PROJECTS} projects`);
  if (mesh.devices.length > MAX_HUMANS * MAX_PROJECTS) refuse('too many device notes');
  const rosters = { ...(state.rosters || {}) }, deviceAt = { ...(state.devices || {}) };
  const git = new Set([owner]), humans = new Set([owner]);
  const seenSlug = new Set();
  let dropped = 0;
  for (const p of mesh.projects) {
    const slug = p?.slug;
    if (!SLUG.test(String(slug)) || seenSlug.has(slug)) refuse('bad project');
    seenSlug.add(slug);
    const r = p.roster ? checkRoster(p.roster, slug, owner) : { created_at: 0, members: new Set([owner]), humans: new Set([owner]) };
    if (r.created_at < (rosters[slug] || 0)) refuse(`${slug}: member list is older than the one applied`);
    if (r.created_at) rosters[slug] = r.created_at;
    // People who joined by an owner-signed link, counted against its use limit.
    const used = new Map();
    const admitted = Array.isArray(p.admitted) ? p.admitted : [];
    if (admitted.length > MAX_HUMANS) refuse(`${slug}: too many joined by link`);
    for (const a of admitted) {
      const g = a && HEX64.test(String(a.pubkey)) && !r.members.has(a.pubkey) ? checkGrant(a.grant, slug, owner) : null;
      if (!g || g.role !== a.role || (used.get(g.id) || 0) >= g.uses || r.humans.size >= MAX_HUMANS) { dropped++; continue; }
      used.set(g.id, (used.get(g.id) || 0) + 1);
      r.members.add(a.pubkey); r.humans.add(a.pubkey);
    }
    for (const m of r.members) git.add(m);
    for (const h of r.humans) humans.add(h);
  }
  // Each listed person's newest note; a note from anyone else is ignored.
  const nodes = new Set(), notePer = new Set();
  for (const e of mesh.devices) {
    const pk = e?.pubkey;
    if (!humans.has(pk) || notePer.has(pk)) { dropped++; continue; }
    const list = checkDeviceNote(e);
    if (!list) { dropped++; continue; }
    if (e.created_at < (deviceAt[pk] || 0)) refuse('a device note is older than the one applied');
    notePer.add(pk);
    deviceAt[pk] = e.created_at;
    for (const n of list) nodes.add(n);
  }
  return {
    gitMembers: [...git].map(hexToNpub).sort(),
    memberNodes: [...nodes].sort(),
    state: { rosters, devices: deviceAt },
    dropped,
  };
}

export const render = (list) => [HEADER, ...list].join('\n') + '\n';

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [meshFile, ownerFile, stateFile, gitOut, nodesOut] = process.argv.slice(2);
  try {
    const owner = npubToHex(readFileSync(ownerFile, 'utf8').trim());
    let state = {};
    try { state = JSON.parse(readFileSync(stateFile, 'utf8')); } catch { /* first run */ }
    let mesh;
    try { mesh = JSON.parse(readAgentFile(meshFile, MAX_MESH_BYTES)); } catch (e) {
      throw new Error(e.code === 'ELOOP' ? 'mesh file is a link'
        : e.message.startsWith('request') ? e.message.replace('request', 'mesh file') : 'mesh file is not readable JSON');
    }
    const out = checkMesh(mesh, { owner, state });
    writeFileSync(gitOut, render(out.gitMembers), { mode: 0o644 });
    writeFileSync(nodesOut, render(out.memberNodes), { mode: 0o644 });
    writeFileSync(stateFile + '.next', JSON.stringify(out.state) + '\n', { mode: 0o600 });
    console.log(`git members: ${out.gitMembers.length}, member devices: ${out.memberNodes.length}${out.dropped ? `, ignored: ${out.dropped}` : ''}`);
  } catch (e) {
    console.error(`torii-teams sync: refused: ${e.message}`);
    process.exit(1);
  }
}

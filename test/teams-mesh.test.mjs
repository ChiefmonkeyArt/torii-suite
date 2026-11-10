// node --test test/teams-mesh.test.mjs — teams/mesh-sync.mjs (torii-teams ADR 0016).
// Fixtures are real nostr-tools signatures (test/fixtures/teams-mesh.json).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, symlinkSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { checkMesh, render } from '../teams/mesh-sync.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const F = JSON.parse(readFileSync(join(ROOT, 'test/fixtures/teams-mesh.json'), 'utf8'));
const N = F.npubs;
const owner = F.ownerHex;
const mesh = () => structuredClone(F.mesh);
const run = (m, state) => checkMesh(m, { owner, state });

test('signed lists become git members and member devices', () => {
  const out = run(mesh());
  assert.deepEqual(out.gitMembers, [N.owner, N.alice, N.bob, N.bot, N.carol].sort());
  assert.deepEqual(out.memberNodes, [N.d1, N.d2, N.d3].sort());
  assert.equal(out.dropped, 2); // dave over the link's use limit; mallory not on a project
  assert.ok(out.state.rosters.site && out.state.devices[owner]);
});

test('an invite link admits no more people than its use limit', () => {
  const m = mesh();
  m.projects[0].admitted.reverse();
  const out = run(m);
  assert.ok(out.gitMembers.includes(N.dave) && !out.gitMembers.includes(N.carol));
});

test('a changed or wrongly-signed member list refuses the whole file', () => {
  const m = mesh();
  m.projects[0].roster.tags.push(['p', 'e'.repeat(64), 'maintainer']);
  assert.throws(() => run(m), /not signed by the owner/);
  const s = mesh();
  s.projects[0].roster = F.strangerRoster;
  assert.throws(() => run(s), /not signed by the owner/);
});

test('an older member list or device note than the one applied is refused', () => {
  const first = run(mesh());
  const m = mesh();
  m.projects[0].roster = F.olderRoster;
  assert.throws(() => run(m, first.state), /older than the one applied/);
  const d = mesh();
  d.devices[0] = F.olderAliceNote;
  assert.throws(() => run(d, first.state), /older than the one applied/);
});

test('a newer device note replaces the old one', () => {
  const first = run(mesh());
  const m = mesh();
  m.devices[0] = F.newerAliceNote;
  const out = run(m, first.state);
  assert.deepEqual(out.memberNodes, [N.d1, N.d2, N.d3].sort()); // d1 stays: the owner lists it too
  assert.equal(out.state.devices[F.newerAliceNote.pubkey], F.newerAliceNote.created_at);
});

test('bad entries are dropped one by one', () => {
  const m = mesh();
  m.projects[0].admitted[0].role = 'maintainer'; // grant says contributor
  m.devices[0].content = m.devices[0].content.replace('pc0', 'px0'); // breaks alice's signature
  const out = run(m);
  assert.ok(!out.gitMembers.includes(N.carol) && out.gitMembers.includes(N.dave));
  assert.ok(!out.memberNodes.includes(N.d2));
});

test('without a member list only the owner is on the project', () => {
  const m = mesh();
  m.projects = [{ slug: 'site', roster: null, admitted: [] }];
  const out = run(m);
  assert.deepEqual(out.gitMembers, [N.owner]);
  assert.deepEqual(out.memberNodes, [N.d1]);
});

test('shape and size limits', () => {
  assert.throws(() => run({ version: 2, projects: [], devices: [] }), /not a mesh file/);
  assert.throws(() => run({ version: 1, projects: Array.from({ length: 65 }, (_, i) => ({ slug: `p${i}` })), devices: [] }), /more than 64/);
  assert.throws(() => run({ version: 1, projects: [{ slug: 'a' }, { slug: 'a' }], devices: [] }), /bad project/);
  assert.throws(() => run({ version: 1, projects: [{ slug: '../x' }], devices: [] }), /bad project/);
  assert.throws(() => checkMesh(mesh(), { owner: '' }), /no project owner/);
});

test('command line: writes both files and next state, refuses cleanly', () => {
  const d = mkdtempSync(join(tmpdir(), 'teams-mesh-'));
  const p = (f) => join(d, f);
  writeFileSync(p('owner.npub'), N.owner + '\n');
  writeFileSync(p('mesh.json'), JSON.stringify(F.mesh));
  const args = [join(ROOT, 'teams/mesh-sync.mjs'), p('mesh.json'), p('owner.npub'), p('state.json'), p('git'), p('nodes')];
  const ok = execFileSync('node', args, { encoding: 'utf8' });
  assert.match(ok, /git members: 5, member devices: 3, ignored: 2/);
  assert.equal(readFileSync(p('git'), 'utf8'), render([N.owner, N.alice, N.bob, N.bot, N.carol].sort()));
  assert.ok(existsSync(p('state.json.next')));
  // Refusal: older roster against the applied state.
  writeFileSync(p('state.json'), readFileSync(p('state.json.next')));
  const m = mesh(); m.projects[0].roster = F.olderRoster;
  writeFileSync(p('mesh.json'), JSON.stringify(m));
  const r = spawnSync('node', args, { encoding: 'utf8' });
  assert.equal(r.status, 1);
  assert.match(r.stderr, /^torii-teams sync: refused: site: member list is older/);
  // Root never follows a link planted in place of the mesh file.
  const l = p('link.json');
  symlinkSync(p('owner.npub'), l);
  const s = spawnSync('node', [args[0], l, ...args.slice(2)], { encoding: 'utf8' });
  assert.equal(s.status, 1);
  assert.match(s.stderr, /mesh file is a link/);
});

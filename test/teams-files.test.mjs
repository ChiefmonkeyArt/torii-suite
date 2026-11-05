// node --test test/teams-files.test.mjs — lib/teams-files.mjs (torii-teams ADR 0007).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, rmSync, statSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { configFromEnv, createFilesServer } from '../lib/teams-files.mjs';

const ALICE = 'a'.repeat(64);
const BOB = 'b'.repeat(64);
const OWNER = 'c'.repeat(64);
const sha = (b) => createHash('sha256').update(b).digest('hex');

async function rig(env = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'teams-files-'));
  const cfg = configFromEnv({
    TEAMS_FILES_DIR: dir, TEAMS_FILES_PUBLIC_URL: 'https://teams.example.org/files',
    TEAMS_FILES_MAX_MB: '1', TEAMS_FILES_QUOTA_GB: String(3 / 1024), ...env,
  });
  const calls = [];
  const tokens = { 'tok-alice': ALICE, 'tok-bobby': BOB, 'tok-owner': OWNER };
  let down = false;
  const fetchFn = async (url, opts) => {
    calls.push(url);
    if (down) throw new Error('down');
    const t = opts.headers.authorization.slice(7);
    if (t === 'tok-removed') return new Response('{"error":"not on any project"}', { status: 403 });
    if (!tokens[t]) return new Response('{}', { status: 401 });
    return Response.json({ ok: true, pubkey: tokens[t], owner: t === 'tok-owner' });
  };
  const clock = { t: 1_700_000_000_000 };
  const { server, usage } = await createFilesServer(cfg, { fetchFn, now: () => clock.t });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  const req = (method, path, { token, body, headers = {} } = {}) => fetch(`${base}${path}`, {
    method, body, headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...headers },
  });
  return {
    dir, calls, clock, usage, req, setDown: (v) => { down = v; },
    done: async () => { await new Promise((r) => server.close(r)); rmSync(dir, { recursive: true, force: true }); },
  };
}

test('config refuses non-https public URLs and non-loopback Continuum', () => {
  assert.throws(() => configFromEnv({ TEAMS_FILES_PUBLIC_URL: 'http://teams.example.org/files' }));
  assert.throws(() => configFromEnv({ TEAMS_FILES_PUBLIC_URL: 'https://teams.example.org/files', TEAMS_FILES_CONTINUUM: 'http://10.0.0.1:8787' }));
  assert.equal(configFromEnv({ TEAMS_FILES_PUBLIC_URL: 'https://teams.example.org/files' }).maxBytes, 100 * 1024 * 1024);
});

test('upload needs a Continuum session; descriptor, dedupe, open reads with safe headers', async () => {
  const r = await rig();
  try {
    const body = Buffer.from('ciphertext bytes');
    const h = sha(body);
    assert.equal((await r.req('PUT', '/upload', { body })).status, 401);
    assert.equal((await r.req('PUT', '/upload', { body, token: 'tok-nobody' })).status, 401);
    const removed = await r.req('PUT', '/upload', { body, token: 'tok-removed' });
    assert.equal(removed.status, 403);
    assert.equal(removed.headers.get('x-reason'), 'not on any project');

    const up = await r.req('PUT', '/upload', { body, token: 'tok-alice', headers: { 'x-sha-256': h } });
    assert.equal(up.status, 201);
    assert.deepEqual(await up.json(), { url: `https://teams.example.org/files/${h}`, sha256: h, size: body.length, type: 'application/octet-stream', uploaded: 1_700_000_000 });
    assert.equal(statSync(join(r.dir, 'blobs', h)).mode & 0o777, 0o600);
    assert.equal(r.usage(), body.length);

    const again = await r.req('PUT', '/upload', { body, token: 'tok-bobby' });
    assert.equal(again.status, 200, 'same bytes: stored once');
    assert.equal(r.usage(), body.length);

    const get = await r.req('GET', `/files/${h}`);
    assert.equal(get.status, 200);
    assert.equal(get.headers.get('content-type'), 'application/octet-stream');
    assert.equal(get.headers.get('x-content-type-options'), 'nosniff');
    assert.equal(get.headers.get('content-disposition'), 'attachment');
    assert.equal(get.headers.get('content-security-policy'), "default-src 'none'; sandbox");
    assert.deepEqual(Buffer.from(await get.arrayBuffer()), body);
    assert.equal((await r.req('HEAD', `/${h}.bin`)).status, 200, 'BUD-01 extension and stripped prefix');
    assert.equal((await r.req('GET', `/${'0'.repeat(64)}`)).status, 404);
    assert.equal((await r.req('GET', '/../etc/passwd')).status, 404);
    assert.equal((await r.req('POST', '/upload', { token: 'tok-alice', body })).status, 405);
  } finally { await r.done(); }
});

test('limits: hash mismatch, size, quota, preflight, rate, and Continuum outages', async () => {
  const r = await rig();
  try {
    const body = Buffer.from('abc');
    const bad = await r.req('PUT', '/upload', { body, token: 'tok-alice', headers: { 'x-sha-256': 'f'.repeat(64) } });
    assert.equal(bad.status, 400);
    assert.deepEqual(readdirSync(join(r.dir, 'blobs')), [], 'nothing kept');
    assert.deepEqual(readdirSync(join(r.dir, 'tmp')), [], 'no temp left behind');

    const big = Buffer.alloc(1024 * 1024 + 1);
    assert.equal((await r.req('PUT', '/upload', { body: big, token: 'tok-alice' })).status, 413);
    assert.equal((await r.req('HEAD', '/upload', { token: 'tok-alice', headers: { 'x-content-length': String(big.length) } })).status, 413);
    assert.equal((await r.req('HEAD', '/upload', { token: 'tok-alice', headers: { 'x-content-length': '10' } })).status, 200);

    // Quota is 3 MiB: three 1 MiB files fit, the fourth does not.
    for (let i = 0; i < 3; i++) {
      assert.equal((await r.req('PUT', '/upload', { body: Buffer.alloc(1024 * 1024, i + 1), token: 'tok-alice' })).status, 201);
    }
    assert.equal((await r.req('PUT', '/upload', { body: Buffer.alloc(16, 9), token: 'tok-alice' })).status, 507);

    // The answer is cached for 60 s, then Continuum is asked again.
    const before = r.calls.length;
    await r.req('HEAD', '/upload', { token: 'tok-bobby' });
    await r.req('HEAD', '/upload', { token: 'tok-bobby' });
    assert.equal(r.calls.length, before + 1);
    r.setDown(true);
    r.clock.t += 61_000;
    assert.equal((await r.req('HEAD', '/upload', { token: 'tok-bobby' })).status, 503);
    r.setDown(false);

    let last;
    for (let i = 0; i < 61; i++) last = await r.req('PUT', '/upload', { body: Buffer.from('x'), token: 'tok-bobby' });
    assert.equal(last.status, 429);
  } finally { await r.done(); }
});

test('delete: uploader or owner only; frees quota', async () => {
  const r = await rig();
  try {
    const body = Buffer.from('to delete');
    const h = sha(body);
    await r.req('PUT', '/upload', { body, token: 'tok-alice' });
    assert.equal((await r.req('DELETE', `/${h}`)).status, 401);
    assert.equal((await r.req('DELETE', `/${h}`, { token: 'tok-bobby' })).status, 403);
    assert.equal((await r.req('DELETE', `/${h}`, { token: 'tok-alice' })).status, 200);
    assert.equal(r.usage(), 0);
    assert.equal((await r.req('DELETE', `/${h}`, { token: 'tok-alice' })).status, 404);
    await r.req('PUT', '/upload', { body, token: 'tok-alice' });
    assert.equal((await r.req('DELETE', `/${h}`, { token: 'tok-owner' })).status, 200, 'owner may delete');
  } finally { await r.done(); }
});

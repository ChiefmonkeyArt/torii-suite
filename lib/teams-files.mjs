#!/usr/bin/env node
// torii-suite/lib/teams-files.mjs — the node's file server for Torii Teams
// (torii-teams docs/torii/adr-0007-node-files.md). Installed by
// installers/install-teams-app.sh as /opt/torii/teams-files/server.mjs and run
// by torii-teams-files.service on loopback; nginx mounts it at
// https://<teams host>/files/ (prefix stripped).
//
// The Blossom subset Teams uses: GET/HEAD /<sha256>, PUT /upload,
// HEAD /upload (BUD-06), DELETE /<sha256>. Blobs are end-to-end encrypted by
// the client, so reads are open; uploads and deletes need a Continuum session
// (Authorization: Bearer <token>), checked against Continuum's
// /api/team/files-ok. Node built-ins only.
import { createServer } from 'node:http';
import { createHash, randomBytes } from 'node:crypto';
import { createReadStream, createWriteStream } from 'node:fs';
import { mkdir, readdir, readFile, rename, rm, stat, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const SHA = /^\/([0-9a-f]{64})(?:\.[a-z0-9]{1,10})?$/;
const BEARER = /^Bearer ([A-Za-z0-9._~+/=-]{8,4096})$/;
const AUTH_TTL_MS = 60_000;
const AUTH_CACHE_MAX = 500;
const UPLOADS_PER_MIN = 60;
// Served with every blob: opaque bytes that can never render or run here.
const BLOB_HEADERS = {
  'content-type': 'application/octet-stream',
  'x-content-type-options': 'nosniff',
  'content-disposition': 'attachment',
  'content-security-policy': "default-src 'none'; sandbox",
  'cache-control': 'public, max-age=31536000, immutable',
  'cross-origin-resource-policy': 'same-origin',
};

export function configFromEnv(env = process.env) {
  const mb = Number(env.TEAMS_FILES_MAX_MB || 100);
  const gb = Number(env.TEAMS_FILES_QUOTA_GB || 10);
  const publicUrl = String(env.TEAMS_FILES_PUBLIC_URL || '').replace(/\/+$/, '');
  const continuum = String(env.TEAMS_FILES_CONTINUUM || 'http://127.0.0.1:8787').replace(/\/+$/, '');
  if (!/^https:\/\/[a-z0-9.-]+(?::\d{1,5})?\/files$/.test(publicUrl) && !/^http:\/\/127\.0\.0\.1:\d{1,5}(\/files)?$/.test(publicUrl)) {
    throw new Error('TEAMS_FILES_PUBLIC_URL must be https://<teams host>/files');
  }
  if (!/^http:\/\/(127\.0\.0\.1|localhost):\d{1,5}$/.test(continuum)) throw new Error('TEAMS_FILES_CONTINUUM must be a loopback http URL');
  if (!(mb > 0 && mb <= 4096) || !(gb > 0 && gb <= 100000)) throw new Error('bad TEAMS_FILES_MAX_MB / TEAMS_FILES_QUOTA_GB');
  return {
    dir: env.TEAMS_FILES_DIR || env.STATE_DIRECTORY || '/var/lib/torii-teams-files',
    port: Number(env.TEAMS_FILES_PORT || 8805),
    publicUrl, continuum,
    maxBytes: Math.floor(mb * 1024 * 1024),
    quotaBytes: Math.floor(gb * 1024 * 1024 * 1024),
  };
}

export async function createFilesServer(cfg, { fetchFn = fetch, now = Date.now } = {}) {
  const blobs = join(cfg.dir, 'blobs');
  const meta = join(cfg.dir, 'meta');
  const tmp = join(cfg.dir, 'tmp');
  for (const d of [blobs, meta, tmp]) await mkdir(d, { recursive: true, mode: 0o700 });
  await rm(tmp, { recursive: true, force: true });
  await mkdir(tmp, { mode: 0o700 });
  let used = 0;
  for (const name of await readdir(blobs)) used += (await stat(join(blobs, name))).size;

  const authCache = new Map(); // sha256(token) -> { at, ok, status, pubkey, owner }
  const rate = new Map(); // pubkey -> { minute, n }

  async function caller(req) {
    const m = BEARER.exec(req.headers.authorization || '');
    if (!m) return { status: 401, reason: 'Continuum sign-in required' };
    const key = createHash('sha256').update(m[1]).digest('hex');
    const hit = authCache.get(key);
    if (hit && now() - hit.at < AUTH_TTL_MS) return hit;
    let res;
    try {
      res = await fetchFn(`${cfg.continuum}/api/team/files-ok`, {
        headers: { authorization: `Bearer ${m[1]}` }, signal: AbortSignal.timeout(5000),
      });
    } catch {
      return { status: 503, reason: 'Continuum unreachable' };
    }
    let entry;
    if (res.status === 200) {
      const body = await res.json().catch(() => ({}));
      entry = /^[0-9a-f]{64}$/.test(body.pubkey || '')
        ? { at: now(), status: 200, pubkey: body.pubkey, owner: body.owner === true }
        : { at: now(), status: 503, reason: 'bad Continuum answer' };
    } else if (res.status === 401 || res.status === 403) {
      entry = { at: now(), status: res.status, reason: res.status === 401 ? 'session invalid' : 'not on any project' };
    } else {
      return { status: 503, reason: `Continuum answered ${res.status}` };
    }
    if (authCache.size >= AUTH_CACHE_MAX) authCache.delete(authCache.keys().next().value);
    authCache.set(key, entry);
    return entry;
  }

  function limited(pubkey) {
    const minute = Math.floor(now() / 60_000);
    const r = rate.get(pubkey);
    if (!r || r.minute !== minute) { rate.set(pubkey, { minute, n: 1 }); return false; }
    return ++r.n > UPLOADS_PER_MIN;
  }

  const fail = (res, status, reason) => {
    res.writeHead(status, { 'content-type': 'application/json', 'x-reason': reason, 'cache-control': 'no-store' });
    res.end(JSON.stringify({ error: reason }));
  };
  const descriptor = (sha256, size, uploaded) => ({
    url: `${cfg.publicUrl}/${sha256}`, sha256, size, type: 'application/octet-stream', uploaded,
  });

  async function upload(req, res, who) {
    if (limited(who.pubkey)) return fail(res, 429, 'too many uploads');
    const declared = req.headers['content-length'];
    if (declared === undefined) return fail(res, 411, 'Content-Length required');
    const len = Number(declared);
    if (!Number.isSafeInteger(len) || len < 1) return fail(res, 400, 'empty upload');
    if (len > cfg.maxBytes) return fail(res, 413, `file larger than ${Math.round(cfg.maxBytes / 1048576)} MB`);
    if (used + len > cfg.quotaBytes) return fail(res, 507, 'node storage is full');
    const want = String(req.headers['x-sha-256'] || '').toLowerCase();
    if (want && !/^[0-9a-f]{64}$/.test(want)) return fail(res, 400, 'bad X-SHA-256');

    const part = join(tmp, randomBytes(12).toString('hex'));
    const hash = createHash('sha256');
    let size = 0;
    const ok = await new Promise((resolve) => {
      const out = createWriteStream(part, { mode: 0o600 });
      req.on('data', (chunk) => {
        size += chunk.length;
        if (size > len) { req.destroy(); out.destroy(); resolve(false); return; }
        hash.update(chunk);
        if (!out.write(chunk)) { req.pause(); out.once('drain', () => req.resume()); }
      });
      req.on('end', () => out.end(() => resolve(size === len)));
      req.on('error', () => { out.destroy(); resolve(false); });
      req.on('aborted', () => { out.destroy(); resolve(false); });
    });
    if (!ok) { await rm(part, { force: true }); if (!res.headersSent && !res.destroyed) fail(res, 400, 'upload incomplete'); return; }
    const sha256 = hash.digest('hex');
    if (want && want !== sha256) { await rm(part, { force: true }); return fail(res, 400, 'X-SHA-256 does not match the body'); }
    const target = join(blobs, sha256);
    const existing = await stat(target).catch(() => null);
    let uploaded = Math.floor(now() / 1000);
    if (existing) {
      await rm(part, { force: true });
      const m = await readFile(join(meta, `${sha256}.json`), 'utf8').then(JSON.parse).catch(() => null);
      if (m?.uploaded) uploaded = m.uploaded;
    } else {
      await rename(part, target);
      used += size;
      await writeFile(join(meta, `${sha256}.json`), JSON.stringify({ uploader: who.pubkey, size, uploaded }), { mode: 0o600 });
    }
    res.writeHead(existing ? 200 : 201, { 'content-type': 'application/json', 'cache-control': 'no-store' });
    res.end(JSON.stringify(descriptor(sha256, size, uploaded)));
  }

  async function remove(res, sha256, who) {
    const target = join(blobs, sha256);
    const s = await stat(target).catch(() => null);
    if (!s) return fail(res, 404, 'not found');
    const m = await readFile(join(meta, `${sha256}.json`), 'utf8').then(JSON.parse).catch(() => null);
    if (!who.owner && m?.uploader !== who.pubkey) return fail(res, 403, 'only the uploader or the owner may delete');
    await rm(target, { force: true });
    await rm(join(meta, `${sha256}.json`), { force: true });
    used = Math.max(0, used - s.size);
    res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' });
    res.end(JSON.stringify({ ok: true }));
  }

  async function read(req, res, sha256) {
    const target = join(blobs, sha256);
    const s = await stat(target).catch(() => null);
    if (!s) return fail(res, 404, 'not found');
    res.writeHead(200, { ...BLOB_HEADERS, 'content-length': s.size, etag: `"${sha256}"` });
    if (req.method === 'HEAD') return res.end();
    createReadStream(target).on('error', () => res.destroy()).pipe(res);
  }

  const server = createServer(async (req, res) => {
    try {
      const path = new URL(req.url, 'http://x').pathname.replace(/^\/files(?=\/)/, '');
      const blob = SHA.exec(path);
      if (blob && (req.method === 'GET' || req.method === 'HEAD')) return await read(req, res, blob[1]);
      const authed = (path === '/upload' && (req.method === 'PUT' || req.method === 'HEAD')) || (blob && req.method === 'DELETE');
      if (!authed) return fail(res, path === '/upload' || blob ? 405 : 404, path === '/upload' || blob ? 'method not allowed' : 'not found');
      const who = await caller(req);
      if (who.status !== 200) { req.resume(); return fail(res, who.status, who.reason); }
      if (req.method === 'DELETE') return await remove(res, blob[1], who);
      if (req.method === 'HEAD') {
        // BUD-06 preflight: X-Content-Length says how big the upload will be.
        const len = Number(req.headers['x-content-length'] || 0);
        if (len > cfg.maxBytes) return fail(res, 413, `file larger than ${Math.round(cfg.maxBytes / 1048576)} MB`);
        if (used + len > cfg.quotaBytes) return fail(res, 507, 'node storage is full');
        res.writeHead(200, { 'cache-control': 'no-store' });
        return res.end();
      }
      return await upload(req, res, who);
    } catch {
      if (!res.headersSent) fail(res, 500, 'server error'); else res.destroy();
    }
  });
  server.requestTimeout = 15 * 60_000;
  return { server, usage: () => used };
}

if (import.meta.url === pathToFileURL(process.argv[1] || '').href) {
  const cfg = configFromEnv();
  const { server } = await createFilesServer(cfg);
  server.listen(cfg.port, '127.0.0.1', () => console.log(`torii-teams-files on 127.0.0.1:${cfg.port}`));
}

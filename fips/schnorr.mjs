// BIP-340 Schnorr verification and Nostr event checks for root helpers.
// Dependency-free on purpose: root must never load code from an app's
// node_modules (the Continuum agent owns those files). Verify only; no keys.
import { createHash } from 'node:crypto';

const P = 2n ** 256n - 2n ** 32n - 977n;
const N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;
const G = [
  0x79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798n,
  0x483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8n,
];
const HEX = (n) => new RegExp(`^[0-9a-f]{${n}}$`);
const mod = (a, m = P) => ((a % m) + m) % m;
const big = (buf) => BigInt('0x' + (Buffer.from(buf).toString('hex') || '0'));
const bytes32 = (n) => Buffer.from(n.toString(16).padStart(64, '0'), 'hex');

function pow(b, e, m = P) {
  let r = 1n; b = mod(b, m);
  for (; e > 0n; e >>= 1n) { if (e & 1n) r = (r * b) % m; b = (b * b) % m; }
  return r;
}
const inv = (a) => pow(a, P - 2n);

// Jacobian coordinates [X, Y, Z]; Z = 0 is the point at infinity.
function dbl([X, Y, Z]) {
  if (Z === 0n || Y === 0n) return [0n, 1n, 0n];
  const S = mod(4n * X * Y * Y), M = mod(3n * X * X);
  const X3 = mod(M * M - 2n * S);
  return [X3, mod(M * (S - X3) - 8n * Y ** 4n), mod(2n * Y * Z)];
}
function add(p, q) {
  if (p[2] === 0n) return q;
  if (q[2] === 0n) return p;
  const [X1, Y1, Z1] = p, [X2, Y2, Z2] = q;
  const Z1Z1 = mod(Z1 * Z1), Z2Z2 = mod(Z2 * Z2);
  const U1 = mod(X1 * Z2Z2), U2 = mod(X2 * Z1Z1);
  const S1 = mod(Y1 * Z2 * Z2Z2), S2 = mod(Y2 * Z1 * Z1Z1);
  if (U1 === U2) return S1 === S2 ? dbl(p) : [0n, 1n, 0n];
  const H = mod(U2 - U1), R = mod(S2 - S1), H2 = mod(H * H), H3 = mod(H * H2);
  const X3 = mod(R * R - H3 - 2n * U1 * H2);
  return [X3, mod(R * (U1 * H2 - X3) - S1 * H3), mod(H * Z1 * Z2)];
}
function mul(k, [x, y]) {
  let r = [0n, 1n, 0n], q = [x, y, 1n];
  for (; k > 0n; k >>= 1n) { if (k & 1n) r = add(r, q); q = dbl(q); }
  return r;
}
function affine([X, Y, Z]) {
  if (Z === 0n) return null;
  const zi = inv(Z), zi2 = mod(zi * zi);
  return [mod(X * zi2), mod(Y * zi2 * zi)];
}
function liftX(x) {
  if (x >= P) return null;
  const c = mod(x ** 3n + 7n), y = pow(c, (P + 1n) / 4n);
  if (mod(y * y) !== c) return null;
  return [x, y & 1n ? P - y : y];
}
function taggedHash(tag, ...parts) {
  const t = createHash('sha256').update(tag).digest();
  const h = createHash('sha256').update(t).update(t);
  for (const p of parts) h.update(p);
  return h.digest();
}

/** BIP-340 verify. msg, pub (32 bytes) and sig (64 bytes) as hex strings. */
export function schnorrVerify(sigHex, msgHex, pubHex) {
  if (!HEX(128).test(sigHex) || !HEX(64).test(msgHex) || !HEX(64).test(pubHex)) return false;
  const sig = Buffer.from(sigHex, 'hex'), m = Buffer.from(msgHex, 'hex'), px = Buffer.from(pubHex, 'hex');
  const Pt = liftX(big(px));
  const r = big(sig.subarray(0, 32)), s = big(sig.subarray(32));
  if (!Pt || r >= P || s >= N) return false;
  const e = mod(big(taggedHash('BIP0340/challenge', bytes32(r), px, m)), N);
  const R = affine(add(mul(s, G), mul(mod(N - e, N), Pt)));
  return !!R && (R[1] & 1n) === 0n && R[0] === r;
}

/** NIP-01 id + signature check of the seven canonical fields. */
export function verifyNostrEvent(e) {
  if (!e || typeof e !== 'object' || !HEX(64).test(e.pubkey || '') || !HEX(64).test(e.id || '')
    || !Number.isSafeInteger(e.created_at) || !Number.isSafeInteger(e.kind)
    || !Array.isArray(e.tags) || typeof e.content !== 'string') return false;
  if (e.tags.some((t) => !Array.isArray(t) || t.some((v) => typeof v !== 'string'))) return false;
  const id = createHash('sha256')
    .update(JSON.stringify([0, e.pubkey, e.created_at, e.kind, e.tags, e.content])).digest('hex');
  return id === e.id && schnorrVerify(String(e.sig || ''), e.id, e.pubkey);
}

const B32 = 'qpzry9x8gf2tvdw0s3jn54khce6mua7l';
const HRP = [...'npub'].map((c) => c.charCodeAt(0));
const HRP_X = [...HRP.map((c) => c >> 5), 0, ...HRP.map((c) => c & 31)];
function polymod(values) {
  const G5 = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
  let chk = 1;
  for (const v of values) {
    const top = chk >>> 25;
    chk = ((chk & 0x1ffffff) << 5) ^ v;
    for (let i = 0; i < 5; i++) if ((top >>> i) & 1) chk ^= G5[i];
  }
  return chk;
}

/** npub1… → 64-hex, or null. Bech32 checksum verified. */
export function npubToHex(npub) {
  const s = String(npub || '');
  if (!/^npub1[023456789acdefghjklmnpqrstuvwxyz]{58}$/.test(s)) return null;
  const data = [...s.slice(5)].map((c) => B32.indexOf(c));
  if (polymod([...HRP_X, ...data]) !== 1) return null;
  let acc = 0, bits = 0; const out = [];
  for (const v of data.slice(0, -6)) {
    acc = ((acc << 5) | v) & 0xfff; bits += 5;
    while (bits >= 8) { bits -= 8; out.push((acc >>> bits) & 0xff); }
  }
  return out.length === 32 ? Buffer.from(out).toString('hex') : null;
}

/** 64-hex → npub1…, or null. */
export function hexToNpub(hex) {
  if (!/^[0-9a-f]{64}$/.test(String(hex || ''))) return null;
  const data = [];
  let acc = 0, bits = 0;
  for (const b of Buffer.from(hex, 'hex')) {
    acc = ((acc << 8) | b) & 0xfff; bits += 8;
    while (bits >= 5) { bits -= 5; data.push((acc >>> bits) & 31); }
  }
  if (bits) data.push((acc << (5 - bits)) & 31);
  const mod = polymod([...HRP_X, ...data, 0, 0, 0, 0, 0, 0]) ^ 1;
  for (let i = 0; i < 6; i++) data.push((mod >>> (5 * (5 - i))) & 31);
  return 'npub1' + data.map((d) => B32[d]).join('');
}

// nostr-crypto.mjs — passphrase-based envelope encryption for the
// optional relay-hosted recovery blob.
//
// v0.1.5-alpha (torii-suite/onboarding)
//
// Design intent: give the user a *defence-in-depth* backup path. If they
// opt in, we encrypt the full recovery bundle with a passphrase they type
// at onboarding — NOT with their nsec — and publish it as a NIP-33
// parameterized replaceable event (kind 30078) to their own relays.
//
// Threat model this defends against:
//   1. Their nsec leaks later. Every NIP-17 DM they ever received is now
//      decryptable retroactively. The passphrase-encrypted blob is NOT,
//      because the passphrase is independent of the nsec.
//   2. A relay is compromised or aggregates events. The blob is
//      indistinguishable from any other kind-30078 app-data payload and
//      is memory-hard to brute-force.
//
// We follow the NIP-49 shape (scrypt → XChaCha20-Poly1305) but wrap an
// arbitrary JSON payload instead of a single private key. Rationale:
// scrypt is memory-hard, so offline attacks cost real RAM per guess; the
// same primitives are already vetted by the Nostr community and are the
// default recommendation for anything password-protected on nostr.
//
// Zero third-party dependencies. WebCrypto + tweetnacl-style ChaCha20
// implementation via a tiny WASM-free JS fallback. We deliberately do
// NOT reach for a full crypto library because it would bloat the
// onboarding bundle and any additional dep enlarges the attack surface
// on a page that touches the user's SSH key.
//
// Two exports:
//
//   encryptRecoveryBundle(plaintext, passphrase, opts)  →  { ncrypt, meta }
//   decryptRecoveryBundle(ncrypt, passphrase)           →  plaintext
//
// `ncrypt` is a bech32-like ASCII string prefixed `torii-ncrypt1` so it
// won't be mistaken for a NIP-49 ncryptsec by a real nostr client. The
// wire format is versioned; v0 uses the parameters below.

const enc = new TextEncoder();
const dec = new TextDecoder();

// --- Parameters -----------------------------------------------------------
// LOG_N = 17 → scrypt N = 131072. Same order of magnitude as NIP-49's
// recommended range (14..20). Chosen conservatively so an in-browser
// derivation on a five-year-old laptop finishes in ~1s. Higher LOG_N is
// safer against brute force but hurts UX on low-end devices.
const DEFAULT_LOG_N = 17;
const SCRYPT_R = 8;
const SCRYPT_P = 1;
const KEY_LEN = 32;    // XChaCha20 key
const NONCE_LEN = 24;  // XChaCha20 nonce
const SALT_LEN = 16;
const VERSION = 0x00;

// --- Public API -----------------------------------------------------------

/**
 * Encrypt a JSON-serializable payload with a user-typed passphrase.
 *
 * @param {object} plaintextObj  arbitrary JSON-serializable payload
 * @param {string} passphrase    UTF-8 string; will be NFKC-normalized
 * @param {object} [opts]
 * @param {number} [opts.logN=DEFAULT_LOG_N]  scrypt work factor (11..20)
 * @returns {Promise<{ncrypt: string, meta: {logN:number, saltHex:string, nonceHex:string}}>}
 */
export async function encryptRecoveryBundle(plaintextObj, passphrase, opts = {}) {
  if (typeof passphrase !== "string" || passphrase.length < 8) {
    throw new Error("recovery passphrase must be at least 8 characters");
  }
  const logN = clampLogN(opts.logN ?? DEFAULT_LOG_N);

  const normalized = passphrase.normalize("NFKC");
  const salt  = crypto.getRandomValues(new Uint8Array(SALT_LEN));
  const nonce = crypto.getRandomValues(new Uint8Array(NONCE_LEN));

  const key = await scrypt(enc.encode(normalized), salt, logN, SCRYPT_R, SCRYPT_P, KEY_LEN);
  const plaintext = enc.encode(JSON.stringify(plaintextObj));
  const ciphertext = xchacha20poly1305Encrypt(key, nonce, plaintext, new Uint8Array(0));

  // Wipe the derived key from JS memory as best we can — the GC will
  // eventually reclaim the buffer but overwriting removes it from any
  // heap snapshot taken between now and GC.
  key.fill(0);

  const body = concatBytes(
    new Uint8Array([VERSION, logN]),
    salt,
    nonce,
    ciphertext,
  );
  return {
    ncrypt: "torii-ncrypt1" + base64UrlEncode(body),
    meta: {
      logN,
      saltHex: bytesToHex(salt),
      nonceHex: bytesToHex(nonce),
    },
  };
}

/**
 * Decrypt a `torii-ncrypt1…` blob produced by encryptRecoveryBundle.
 *
 * @param {string} ncrypt       the ASCII envelope
 * @param {string} passphrase   the passphrase used at encryption time
 * @returns {Promise<object>}   the original JSON payload
 */
export async function decryptRecoveryBundle(ncrypt, passphrase) {
  if (typeof ncrypt !== "string" || !ncrypt.startsWith("torii-ncrypt1")) {
    throw new Error("not a torii-ncrypt1 envelope");
  }
  const body = base64UrlDecode(ncrypt.slice("torii-ncrypt1".length));
  if (body.length < 2 + SALT_LEN + NONCE_LEN + 16) {
    throw new Error("torii-ncrypt1 envelope truncated");
  }
  const version = body[0];
  if (version !== VERSION) throw new Error(`unsupported torii-ncrypt version ${version}`);
  const logN  = body[1];
  const salt  = body.slice(2, 2 + SALT_LEN);
  const nonce = body.slice(2 + SALT_LEN, 2 + SALT_LEN + NONCE_LEN);
  const ct    = body.slice(2 + SALT_LEN + NONCE_LEN);

  const normalized = passphrase.normalize("NFKC");
  const key = await scrypt(enc.encode(normalized), salt, logN, SCRYPT_R, SCRYPT_P, KEY_LEN);
  let plaintext;
  try {
    plaintext = xchacha20poly1305Decrypt(key, nonce, ct, new Uint8Array(0));
  } finally {
    key.fill(0);
  }
  return JSON.parse(dec.decode(plaintext));
}

// --- scrypt (RFC 7914) — minimal in-JS implementation --------------------
//
// We implement scrypt in-JS rather than relying on WebCrypto because
// SubtleCrypto.deriveBits() does not offer scrypt; only PBKDF2 and HKDF.
// PBKDF2 is not memory-hard, which is the whole point here.
//
// The implementation below is straightforward and follows the RFC. It's
// deliberately compact rather than fast — an onboarding flow runs it once,
// so a ~1s derivation on middling hardware is acceptable.

async function scrypt(password, salt, logN, r, p, dkLen) {
  const N = 1 << logN;
  // Step 1: derive p × 128r-byte blocks via PBKDF2-SHA256.
  const pbkdfKey = await crypto.subtle.importKey(
    "raw", password, { name: "PBKDF2" }, false, ["deriveBits"],
  );
  const b = new Uint8Array(await crypto.subtle.deriveBits(
    { name: "PBKDF2", salt, iterations: 1, hash: "SHA-256" },
    pbkdfKey,
    p * 128 * r * 8,
  ));

  // Step 2: mix each block with ROMix (sequential memory-hard).
  const blockSize = 128 * r;
  for (let i = 0; i < p; i++) {
    const block = b.subarray(i * blockSize, (i + 1) * blockSize);
    scryptROMix(block, N, r);
  }

  // Step 3: final PBKDF2 with mixed B as salt.
  const finalKey = await crypto.subtle.importKey(
    "raw", password, { name: "PBKDF2" }, false, ["deriveBits"],
  );
  const out = new Uint8Array(await crypto.subtle.deriveBits(
    { name: "PBKDF2", salt: b, iterations: 1, hash: "SHA-256" },
    finalKey,
    dkLen * 8,
  ));
  b.fill(0);
  return out;
}

function scryptROMix(block, N, r) {
  const blockSize = 128 * r;
  const V = new Uint8Array(N * blockSize);
  let X = new Uint8Array(block);
  for (let i = 0; i < N; i++) {
    V.set(X, i * blockSize);
    X = scryptBlockMix(X, r);
  }
  for (let i = 0; i < N; i++) {
    const j = integerify(X, r) & (N - 1);
    for (let k = 0; k < blockSize; k++) {
      X[k] ^= V[j * blockSize + k];
    }
    X = scryptBlockMix(X, r);
  }
  block.set(X);
  V.fill(0);
}

function scryptBlockMix(B, r) {
  // B is 128r bytes = 2r 64-byte blocks. See RFC 7914 §4.
  let X = B.slice(B.length - 64);
  const Y = new Uint8Array(B.length);
  for (let i = 0; i < 2 * r; i++) {
    for (let k = 0; k < 64; k++) X[k] ^= B[i * 64 + k];
    X = salsa20_8(X);
    // Interleave outputs per the RFC: even blocks first, then odd.
    const outIdx = i % 2 === 0 ? (i / 2) * 64 : (r + (i - 1) / 2) * 64;
    Y.set(X, outIdx);
  }
  return Y;
}

function integerify(B, r) {
  // Last 64-byte block, treat first 4 bytes as little-endian uint32.
  const off = (2 * r - 1) * 64;
  return (B[off] | (B[off + 1] << 8) | (B[off + 2] << 16) | (B[off + 3] << 24)) >>> 0;
}

function salsa20_8(input) {
  // Salsa20 core, 8 rounds. Input/output: 64 bytes.
  const x = new Uint32Array(16);
  for (let i = 0; i < 16; i++) {
    x[i] = input[i * 4] | (input[i * 4 + 1] << 8) | (input[i * 4 + 2] << 16) | (input[i * 4 + 3] << 24);
  }
  const s = new Uint32Array(x);
  for (let i = 0; i < 4; i++) {
    // Column rounds
    s[ 4] ^= rotl(s[ 0] + s[12] | 0,  7);  s[ 8] ^= rotl(s[ 4] + s[ 0] | 0,  9);
    s[12] ^= rotl(s[ 8] + s[ 4] | 0, 13);  s[ 0] ^= rotl(s[12] + s[ 8] | 0, 18);
    s[ 9] ^= rotl(s[ 5] + s[ 1] | 0,  7);  s[13] ^= rotl(s[ 9] + s[ 5] | 0,  9);
    s[ 1] ^= rotl(s[13] + s[ 9] | 0, 13);  s[ 5] ^= rotl(s[ 1] + s[13] | 0, 18);
    s[14] ^= rotl(s[10] + s[ 6] | 0,  7);  s[ 2] ^= rotl(s[14] + s[10] | 0,  9);
    s[ 6] ^= rotl(s[ 2] + s[14] | 0, 13);  s[10] ^= rotl(s[ 6] + s[ 2] | 0, 18);
    s[ 3] ^= rotl(s[15] + s[11] | 0,  7);  s[ 7] ^= rotl(s[ 3] + s[15] | 0,  9);
    s[11] ^= rotl(s[ 7] + s[ 3] | 0, 13);  s[15] ^= rotl(s[11] + s[ 7] | 0, 18);
    // Row rounds
    s[ 1] ^= rotl(s[ 0] + s[ 3] | 0,  7);  s[ 2] ^= rotl(s[ 1] + s[ 0] | 0,  9);
    s[ 3] ^= rotl(s[ 2] + s[ 1] | 0, 13);  s[ 0] ^= rotl(s[ 3] + s[ 2] | 0, 18);
    s[ 6] ^= rotl(s[ 5] + s[ 4] | 0,  7);  s[ 7] ^= rotl(s[ 6] + s[ 5] | 0,  9);
    s[ 4] ^= rotl(s[ 7] + s[ 6] | 0, 13);  s[ 5] ^= rotl(s[ 4] + s[ 7] | 0, 18);
    s[11] ^= rotl(s[10] + s[ 9] | 0,  7);  s[ 8] ^= rotl(s[11] + s[10] | 0,  9);
    s[ 9] ^= rotl(s[ 8] + s[11] | 0, 13);  s[10] ^= rotl(s[ 9] + s[ 8] | 0, 18);
    s[12] ^= rotl(s[15] + s[14] | 0,  7);  s[13] ^= rotl(s[12] + s[15] | 0,  9);
    s[14] ^= rotl(s[13] + s[12] | 0, 13);  s[15] ^= rotl(s[14] + s[13] | 0, 18);
  }
  const out = new Uint8Array(64);
  for (let i = 0; i < 16; i++) {
    const v = (s[i] + x[i]) >>> 0;
    out[i * 4]     = v & 0xff;
    out[i * 4 + 1] = (v >>> 8)  & 0xff;
    out[i * 4 + 2] = (v >>> 16) & 0xff;
    out[i * 4 + 3] = (v >>> 24) & 0xff;
  }
  return out;
}

function rotl(x, n) { return ((x << n) | (x >>> (32 - n))) >>> 0; }

// --- ChaCha20-Poly1305 (XChaCha20 variant) --------------------------------
// Implements RFC 8439 ChaCha20-Poly1305 with the XChaCha20 24-byte nonce
// extension via HChaCha20. This is what NIP-49 (and NIP-44 v2) use.

function xchacha20poly1305Encrypt(key, nonce24, plaintext, ad) {
  const { subKey, nonce12 } = hchacha20(key, nonce24);
  const ct = new Uint8Array(plaintext.length);
  chacha20(subKey, nonce12, plaintext, ct, 1);

  // Poly1305 key derived from the first block of ChaCha20 counter=0.
  const polyKey = new Uint8Array(32);
  const zero = new Uint8Array(32);
  chacha20(subKey, nonce12, zero, polyKey, 0);
  const tag = poly1305Compute(polyKey, ad, ct);

  const out = new Uint8Array(ct.length + 16);
  out.set(ct, 0);
  out.set(tag, ct.length);
  subKey.fill(0);
  polyKey.fill(0);
  return out;
}

function xchacha20poly1305Decrypt(key, nonce24, sealed, ad) {
  if (sealed.length < 16) throw new Error("ciphertext too short for auth tag");
  const ct  = sealed.slice(0, sealed.length - 16);
  const tag = sealed.slice(sealed.length - 16);

  const { subKey, nonce12 } = hchacha20(key, nonce24);
  const polyKey = new Uint8Array(32);
  const zero = new Uint8Array(32);
  chacha20(subKey, nonce12, zero, polyKey, 0);
  const expectTag = poly1305Compute(polyKey, ad, ct);
  polyKey.fill(0);

  if (!constantTimeEq(tag, expectTag)) {
    subKey.fill(0);
    throw new Error("recovery blob failed authentication (wrong passphrase?)");
  }
  const pt = new Uint8Array(ct.length);
  chacha20(subKey, nonce12, ct, pt, 1);
  subKey.fill(0);
  return pt;
}

function hchacha20(key, nonce24) {
  // HChaCha20: derive a 32-byte subkey and a 12-byte nonce from a 24-byte
  // input nonce, per RFC 8439 sec 2.3 / RFC-draft xchacha20 sec 2.
  const state = new Uint32Array(16);
  state[0] = 0x61707865; state[1] = 0x3320646e; state[2] = 0x79622d32; state[3] = 0x6b206574;
  for (let i = 0; i < 8; i++) state[4 + i] = leU32(key, i * 4);
  for (let i = 0; i < 4; i++) state[12 + i] = leU32(nonce24, i * 4);
  chachaRounds(state);
  const subKey = new Uint8Array(32);
  for (let i = 0; i < 4; i++) writeLeU32(subKey, i * 4, state[i]);
  for (let i = 0; i < 4; i++) writeLeU32(subKey, 16 + i * 4, state[12 + i]);
  const nonce12 = new Uint8Array(12);
  // First 4 bytes are zero (block counter high) — but per XChaCha20 spec
  // the 12-byte nonce is 4 zero bytes + last 8 bytes of the input nonce.
  nonce12.set(nonce24.slice(16), 4);
  return { subKey, nonce12 };
}

// Exported for reuse by lib/nostr-nip44.mjs (NIP-44 v2 also uses ChaCha20).
// Reusing one implementation keeps the review surface small — both call
// paths share the exact same rotation, constant, and counter code.
export function chacha20(key, nonce12, input, output, initialCounter) {
  const state = new Uint32Array(16);
  state[0] = 0x61707865; state[1] = 0x3320646e; state[2] = 0x79622d32; state[3] = 0x6b206574;
  for (let i = 0; i < 8; i++) state[4 + i] = leU32(key, i * 4);
  state[13] = leU32(nonce12, 0);
  state[14] = leU32(nonce12, 4);
  state[15] = leU32(nonce12, 8);
  let counter = initialCounter >>> 0;

  const block = new Uint8Array(64);
  const working = new Uint32Array(16);
  for (let off = 0; off < input.length; off += 64) {
    state[12] = counter;
    working.set(state);
    chachaRounds(working);
    for (let i = 0; i < 16; i++) {
      const v = (working[i] + state[i]) >>> 0;
      writeLeU32(block, i * 4, v);
    }
    const chunk = Math.min(64, input.length - off);
    for (let i = 0; i < chunk; i++) output[off + i] = input[off + i] ^ block[i];
    counter = (counter + 1) >>> 0;
  }
}

function chachaRounds(state) {
  for (let i = 0; i < 10; i++) {
    // Column rounds
    QR(state, 0, 4,  8, 12);
    QR(state, 1, 5,  9, 13);
    QR(state, 2, 6, 10, 14);
    QR(state, 3, 7, 11, 15);
    // Diagonal rounds
    QR(state, 0, 5, 10, 15);
    QR(state, 1, 6, 11, 12);
    QR(state, 2, 7,  8, 13);
    QR(state, 3, 4,  9, 14);
  }
}

function QR(s, a, b, c, d) {
  s[a] = (s[a] + s[b]) >>> 0; s[d] = rotl(s[d] ^ s[a], 16);
  s[c] = (s[c] + s[d]) >>> 0; s[b] = rotl(s[b] ^ s[c], 12);
  s[a] = (s[a] + s[b]) >>> 0; s[d] = rotl(s[d] ^ s[a],  8);
  s[c] = (s[c] + s[d]) >>> 0; s[b] = rotl(s[b] ^ s[c],  7);
}

// --- Poly1305 (RFC 8439) --------------------------------------------------

function poly1305Compute(key, ad, ct) {
  // AEAD tag input per RFC 8439 §2.8: ad || pad16 || ct || pad16 || len(ad) || len(ct)
  const parts = [
    ad,
    pad16(ad.length),
    ct,
    pad16(ct.length),
    u64le(ad.length),
    u64le(ct.length),
  ];
  const msg = concatBytes(...parts);
  return poly1305Mac(msg, key);
}

function pad16(n) {
  const r = n % 16;
  return r === 0 ? new Uint8Array(0) : new Uint8Array(16 - r);
}

function u64le(n) {
  const b = new Uint8Array(8);
  let v = BigInt(n);
  for (let i = 0; i < 8; i++) {
    b[i] = Number(v & 0xffn);
    v >>= 8n;
  }
  return b;
}

function poly1305Mac(msg, key) {
  // r = clamped low 128 bits, s = high 128 bits.
  const r = new Uint8Array(16);
  r.set(key.slice(0, 16));
  r[3]  &= 15; r[7]  &= 15; r[11] &= 15; r[15] &= 15;
  r[4]  &= 252; r[8] &= 252; r[12] &= 252;
  const s = key.slice(16, 32);

  // Accumulator as 5 × 26-bit limbs for headroom during multiply.
  let h0 = 0, h1 = 0, h2 = 0, h3 = 0, h4 = 0;
  const r0 =  (r[0]        | (r[1]  <<  8) | (r[2]  << 16) | (r[3]  << 24)) & 0x3ffffff;
  const r1 = ((r[3]  >>> 2)| (r[4]  <<  6) | (r[5]  << 14) | (r[6]  << 22)) & 0x3ffffff;
  const r2 = ((r[6]  >>> 4)| (r[7]  <<  4) | (r[8]  << 12) | (r[9]  << 20)) & 0x3ffffff;
  const r3 = ((r[9]  >>> 6)| (r[10] <<  2) | (r[11] << 10) | (r[12] << 18)) & 0x3ffffff;
  const r4 = ((r[12] >>> 8)                | (r[13] <<  0) | (r[14] <<  8) | (r[15] << 16)) & 0x3ffffff;
  const s1 = r1 * 5, s2 = r2 * 5, s3 = r3 * 5, s4 = r4 * 5;

  let i = 0;
  while (i < msg.length) {
    const end = Math.min(i + 16, msg.length);
    const buf = new Uint8Array(17);
    buf.set(msg.subarray(i, end));
    buf[end - i] = 1;
    i = end;

    h0 += ( buf[0]        | (buf[1]  <<  8) | (buf[2]  << 16) | (buf[3]  << 24)) & 0x3ffffff;
    h1 += ((buf[3]  >>> 2)| (buf[4]  <<  6) | (buf[5]  << 14) | (buf[6]  << 22)) & 0x3ffffff;
    h2 += ((buf[6]  >>> 4)| (buf[7]  <<  4) | (buf[8]  << 12) | (buf[9]  << 20)) & 0x3ffffff;
    h3 += ((buf[9]  >>> 6)| (buf[10] <<  2) | (buf[11] << 10) | (buf[12] << 18)) & 0x3ffffff;
    h4 += ((buf[12] >>> 8)                  | (buf[13] <<  0) | (buf[14] <<  8) | (buf[15] << 16) | (buf[16] << 24)) & 0x3ffffff;

    // h *= r  (mod 2^130 - 5)
    const d0 = h0*r0 + h1*s4 + h2*s3 + h3*s2 + h4*s1;
    const d1 = h0*r1 + h1*r0 + h2*s4 + h3*s3 + h4*s2;
    const d2 = h0*r2 + h1*r1 + h2*r0 + h3*s4 + h4*s3;
    const d3 = h0*r3 + h1*r2 + h2*r1 + h3*r0 + h4*s4;
    const d4 = h0*r4 + h1*r3 + h2*r2 + h3*r1 + h4*r0;

    let c;
    h0 = d0 & 0x3ffffff; c = Math.floor(d0 / 0x4000000);
    h1 = (d1 + c) & 0x3ffffff; c = Math.floor((d1 + c) / 0x4000000);
    h2 = (d2 + c) & 0x3ffffff; c = Math.floor((d2 + c) / 0x4000000);
    h3 = (d3 + c) & 0x3ffffff; c = Math.floor((d3 + c) / 0x4000000);
    h4 = (d4 + c) & 0x3ffffff; c = Math.floor((d4 + c) / 0x4000000);
    h0 += c * 5;
    c = h0 >>> 26; h0 &= 0x3ffffff; h1 += c;
  }

  // Final carry + mod (2^130 - 5) reduction.
  let c;
  c = h1 >>> 26; h1 &= 0x3ffffff; h2 += c;
  c = h2 >>> 26; h2 &= 0x3ffffff; h3 += c;
  c = h3 >>> 26; h3 &= 0x3ffffff; h4 += c;
  c = h4 >>> 26; h4 &= 0x3ffffff; h0 += c * 5;
  c = h0 >>> 26; h0 &= 0x3ffffff; h1 += c;

  // Try h + -p (as h + (2^130 - 5 negated in the same 130-bit field)).
  let g0 = h0 + 5, g1 = h1, g2 = h2, g3 = h3, g4 = h4;
  c  = g0 >>> 26; g0 &= 0x3ffffff; g1 += c;
  c  = g1 >>> 26; g1 &= 0x3ffffff; g2 += c;
  c  = g2 >>> 26; g2 &= 0x3ffffff; g3 += c;
  c  = g3 >>> 26; g3 &= 0x3ffffff; g4 += c;
  g4 -= 0x4000000;

  const mask = (g4 >>> 31) - 1;
  const nMask = ~mask & 0x3ffffff;
  h0 = (h0 & nMask) | (g0 & mask & 0x3ffffff);
  h1 = (h1 & nMask) | (g1 & mask & 0x3ffffff);
  h2 = (h2 & nMask) | (g2 & mask & 0x3ffffff);
  h3 = (h3 & nMask) | (g3 & mask & 0x3ffffff);
  h4 = (h4 & nMask) | (g4 & mask & 0x3ffffff);

  // Pack limbs → 128-bit little-endian.
  const H0 = ( h0        | (h1 << 26)) >>> 0;
  const H1 = ((h1 >>>  6)| (h2 << 20)) >>> 0;
  const H2 = ((h2 >>> 12)| (h3 << 14)) >>> 0;
  const H3 = ((h3 >>> 18)| (h4 <<  8)) >>> 0;

  // Add s (little-endian 128-bit).
  const S0 = (s[0]  | (s[1]  << 8) | (s[2]  << 16) | (s[3]  << 24)) >>> 0;
  const S1 = (s[4]  | (s[5]  << 8) | (s[6]  << 16) | (s[7]  << 24)) >>> 0;
  const S2 = (s[8]  | (s[9]  << 8) | (s[10] << 16) | (s[11] << 24)) >>> 0;
  const S3 = (s[12] | (s[13] << 8) | (s[14] << 16) | (s[15] << 24)) >>> 0;

  const T0 = H0 + S0;
  const carry0 = T0 > 0xffffffff ? 1 : 0;
  const T1 = H1 + S1 + carry0;
  const carry1 = T1 > 0xffffffff ? 1 : 0;
  const T2 = H2 + S2 + carry1;
  const carry2 = T2 > 0xffffffff ? 1 : 0;
  const T3 = H3 + S3 + carry2;

  const tag = new Uint8Array(16);
  writeLeU32(tag, 0,  T0 >>> 0);
  writeLeU32(tag, 4,  T1 >>> 0);
  writeLeU32(tag, 8,  T2 >>> 0);
  writeLeU32(tag, 12, T3 >>> 0);
  return tag;
}

// --- Small utilities ------------------------------------------------------

function clampLogN(n) {
  const v = Math.floor(Number(n));
  if (!Number.isFinite(v) || v < 11 || v > 20) {
    throw new Error("logN must be an integer in [11, 20]");
  }
  return v;
}

function leU32(buf, off) {
  return ((buf[off] | (buf[off + 1] << 8) | (buf[off + 2] << 16) | (buf[off + 3] << 24)) >>> 0);
}

function writeLeU32(buf, off, v) {
  buf[off]     = v & 0xff;
  buf[off + 1] = (v >>> 8) & 0xff;
  buf[off + 2] = (v >>> 16) & 0xff;
  buf[off + 3] = (v >>> 24) & 0xff;
}

function concatBytes(...arrs) {
  let total = 0;
  for (const a of arrs) total += a.length;
  const out = new Uint8Array(total);
  let off = 0;
  for (const a of arrs) { out.set(a, off); off += a.length; }
  return out;
}

function bytesToHex(bytes) {
  const hex = new Array(bytes.length);
  for (let i = 0; i < bytes.length; i++) hex[i] = bytes[i].toString(16).padStart(2, "0");
  return hex.join("");
}

function constantTimeEq(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

// URL-safe base64 without padding (RFC 4648 §5).
function base64UrlEncode(bytes) {
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function base64UrlDecode(s) {
  const pad = s.length % 4 === 0 ? "" : "=".repeat(4 - (s.length % 4));
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/") + pad;
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

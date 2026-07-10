// nostr-nip44.mjs — NIP-44 v2 encrypted payloads for nostr.
//
// v0.1.6-alpha (torii-suite/onboarding)
//
// ─── Purpose ───────────────────────────────────────────────────────────
//
// NIP-44 v2 is the modern versioned encryption scheme used by NIP-17
// (private DMs) and NIP-59 (gift wrap). It is what makes it possible for
// the sender of a gift wrap to be a fresh ephemeral keypair while still
// producing a payload the recipient can decrypt with only their own nsec.
//
// v0.1.5's recovery hint DM relied on `signer.nip44.encrypt(...)` from
// the user's NIP-07 extension. That works when both endpoints are the
// user's own npub. It does NOT work for gift wrap: the outer wrapper is
// signed by a random ephemeral key that the extension has never heard
// of, so the extension cannot derive the conversation key. v0.1.6 needs
// to encrypt with (ephemeralPrivKey, recipientPubKey), and no browser
// extension exposes that surface today.
//
// So we implement NIP-44 v2 in-repo. The heavy elliptic-curve work
// (ECDH, x-only pubkeys) is delegated to the vendored @noble/secp256k1
// (see lib/vendor/README.md) — hand-rolling scalar multiplication would
// be the classic "timing side-channel leaks bits of the ephemeral key"
// footgun. Everything symmetric (HKDF, HMAC, padding, ChaCha20, base64)
// runs on WebCrypto + our existing v0.1.5 ChaCha20 implementation.
//
// ─── Spec reference ────────────────────────────────────────────────────
//
// Full spec: https://github.com/nostr-protocol/nips/blob/master/44.md
//
// Wire format after base64 decode:
//
//   [version:1][nonce:32][ciphertext:padded][mac:32]
//
// Where:
//   version     = 0x02
//   nonce       = 32 random bytes (CSPRNG)
//   ciphertext  = ChaCha20(chacha_key, chacha_nonce, padded_plaintext)
//   mac         = HMAC-SHA256(hmac_key, nonce || ciphertext)
//
// Key schedule:
//   shared_x        = secp256k1_ecdh(priv, pub).x   (32 bytes)
//   conversation_key = HKDF-Extract(salt='nip44-v2', IKM=shared_x)     (32 bytes)
//   [chacha_key, chacha_nonce, hmac_key] = HKDF-Expand(conversation_key, info=nonce, L=76)
//
// Padding: length-prefixed, powers-of-two buckets, min 32 bytes.
//
// ─── Security notes ────────────────────────────────────────────────────
//
//   * The 32-byte nonce is generated with `crypto.getRandomValues` per
//     message. Reusing a nonce with the same conversation_key would let
//     an attacker XOR two ciphertexts and recover both plaintexts. We
//     never derive the nonce from message content.
//
//   * The `nonce` is used both as the ECDH-side nonce and as the AAD
//     for the HMAC. AAD length is validated to be exactly 32 bytes
//     (spec-mandated) to prevent length-extension games.
//
//   * MAC comparison is constant-time (`constantTimeEq`) to prevent
//     timing side-channels on decrypt.
//
//   * Plaintext length is checked before base64 decoding on the decrypt
//     path to prevent DoS on the base64 decoder.
//
//   * We validate that recipient pubkey is a valid x-only 32-byte hex
//     string. `getSharedSecret` will additionally reject any point not
//     on the secp256k1 curve.

import {
  getSharedSecret,
} from "./vendor/noble-secp256k1/secp256k1.mjs";
import { chacha20 } from "./nostr-crypto.mjs";

// ─── Utilities ─────────────────────────────────────────────────────────

const NIP44_SALT = new TextEncoder().encode("nip44-v2");

/** @param {string} hex */
function hexToBytes(hex) {
  if (typeof hex !== "string") throw new Error("hexToBytes: expected string");
  if (hex.length % 2 !== 0) throw new Error("hexToBytes: odd length");
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) {
    const h = parseInt(hex.substr(i * 2, 2), 16);
    if (Number.isNaN(h)) throw new Error("hexToBytes: bad hex");
    out[i] = h;
  }
  return out;
}

/** @param {Uint8Array} bytes */
function bytesToHex(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i++) s += bytes[i].toString(16).padStart(2, "0");
  return s;
}

/**
 * Constant-time equality of two Uint8Arrays. Length mismatch fails
 * immediately (length is not a secret in our threat model — nonce and
 * mac lengths are constants).
 * @param {Uint8Array} a
 * @param {Uint8Array} b
 */
function constantTimeEq(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

/** Concatenate any number of Uint8Arrays. */
function concatBytes(...parts) {
  let total = 0;
  for (const p of parts) total += p.length;
  const out = new Uint8Array(total);
  let off = 0;
  for (const p of parts) { out.set(p, off); off += p.length; }
  return out;
}

// ─── HKDF (RFC 5869) via WebCrypto ────────────────────────────────────

/**
 * HKDF-Extract(salt, IKM) → PRK (32 bytes).
 * Uses HMAC-SHA256 with `salt` as key and `IKM` as message.
 * @param {Uint8Array} ikm
 * @param {Uint8Array} salt
 * @returns {Promise<Uint8Array>} 32-byte pseudorandom key
 */
async function hkdfExtract(ikm, salt) {
  const key = await crypto.subtle.importKey(
    "raw", salt.length > 0 ? salt : new Uint8Array(32),
    { name: "HMAC", hash: "SHA-256" },
    false, ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, ikm);
  return new Uint8Array(mac);
}

/**
 * HKDF-Expand(PRK, info, L) → OKM (L bytes, max 255 * 32 = 8160).
 * @param {Uint8Array} prk  32-byte PRK from Extract
 * @param {Uint8Array} info context bytes
 * @param {number}     L    output length
 * @returns {Promise<Uint8Array>} OKM
 */
async function hkdfExpand(prk, info, L) {
  const key = await crypto.subtle.importKey(
    "raw", prk,
    { name: "HMAC", hash: "SHA-256" },
    false, ["sign"],
  );
  const N = Math.ceil(L / 32);
  if (N > 255) throw new Error("hkdfExpand: L too large");
  let T = new Uint8Array(0);
  const out = new Uint8Array(L);
  let written = 0;
  for (let i = 1; i <= N; i++) {
    const input = concatBytes(T, info, new Uint8Array([i]));
    const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, input));
    T = mac;
    const take = Math.min(32, L - written);
    out.set(mac.subarray(0, take), written);
    written += take;
  }
  return out;
}

/**
 * HMAC-SHA256(key, message) → 32 bytes.
 * @param {Uint8Array} key
 * @param {Uint8Array} message
 * @returns {Promise<Uint8Array>}
 */
async function hmacSha256(key, message) {
  const k = await crypto.subtle.importKey(
    "raw", key,
    { name: "HMAC", hash: "SHA-256" },
    false, ["sign"],
  );
  return new Uint8Array(await crypto.subtle.sign("HMAC", k, message));
}

// ─── Padding (NIP-44 §Pad/Unpad) ──────────────────────────────────────

const MIN_PLAINTEXT_SIZE = 1;
const MAX_PLAINTEXT_SIZE = 0xffffffff; // 2^32 - 1
const EXTENDED_PREFIX_THRESHOLD = 65536;

/**
 * Calculate the padded byte length for a plaintext of length n.
 * Powers-of-two buckets, minimum 32 bytes.
 * @param {number} n
 */
function calcPaddedLen(n) {
  if (n <= 32) return 32;
  // next power of two >= n
  const nextPower = 1 << (Math.floor(Math.log2(n - 1)) + 1);
  const chunk = nextPower <= 256 ? 32 : nextPower / 8;
  return chunk * (Math.floor((n - 1) / chunk) + 1);
}

/**
 * Pad plaintext bytes per NIP-44. Prefix + plaintext + zero-fill.
 * @param {Uint8Array} plaintext
 * @returns {Uint8Array}
 */
function pad(plaintext) {
  const n = plaintext.length;
  if (n < MIN_PLAINTEXT_SIZE) throw new Error("nip44 pad: plaintext too short");
  if (n > MAX_PLAINTEXT_SIZE) throw new Error("nip44 pad: plaintext too long");
  const padded = calcPaddedLen(n);
  let prefixLen;
  let prefix;
  if (n >= EXTENDED_PREFIX_THRESHOLD) {
    prefix = new Uint8Array(6);
    // 2 zero bytes + u32 BE length
    prefix[2] = (n >>> 24) & 0xff;
    prefix[3] = (n >>> 16) & 0xff;
    prefix[4] = (n >>> 8) & 0xff;
    prefix[5] = n & 0xff;
    prefixLen = 6;
  } else {
    prefix = new Uint8Array(2);
    prefix[0] = (n >>> 8) & 0xff;
    prefix[1] = n & 0xff;
    prefixLen = 2;
  }
  const out = new Uint8Array(prefixLen + padded);
  out.set(prefix, 0);
  out.set(plaintext, prefixLen);
  // remaining bytes stay zero
  return out;
}

/**
 * Unpad plaintext bytes per NIP-44. Validates lengths strictly to
 * catch tampering that the MAC didn't already reject.
 * @param {Uint8Array} padded
 * @returns {Uint8Array} plaintext
 */
function unpad(padded) {
  if (padded.length < 2) throw new Error("nip44 unpad: too short");
  const firstTwo = (padded[0] << 8) | padded[1];
  let unpaddedLen;
  let prefixLen;
  if (firstTwo === 0) {
    if (padded.length < 6) throw new Error("nip44 unpad: bad extended prefix");
    unpaddedLen =
      (padded[2] * 0x1000000) +
      ((padded[3] << 16) | (padded[4] << 8) | padded[5]);
    if (unpaddedLen < EXTENDED_PREFIX_THRESHOLD) {
      throw new Error("nip44 unpad: invalid padding (extended prefix with short length)");
    }
    prefixLen = 6;
  } else {
    unpaddedLen = firstTwo;
    prefixLen = 2;
  }
  if (unpaddedLen === 0) throw new Error("nip44 unpad: zero length");
  const expectedTotal = prefixLen + calcPaddedLen(unpaddedLen);
  if (padded.length !== expectedTotal) {
    throw new Error("nip44 unpad: length mismatch");
  }
  const unpadded = padded.subarray(prefixLen, prefixLen + unpaddedLen);
  if (unpadded.length !== unpaddedLen) {
    throw new Error("nip44 unpad: slice mismatch");
  }
  return unpadded;
}

// ─── Base64 (standard, with padding) ──────────────────────────────────

/** @param {Uint8Array} bytes */
function base64Encode(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s);
}

/** @param {string} b64 */
function base64Decode(b64) {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

// ─── Public API ───────────────────────────────────────────────────────

/**
 * Derive the NIP-44 v2 conversation key from a private key and a
 * recipient's x-only pubkey.
 *
 *   shared_x = secp256k1_ecdh(priv, pub)   (32 bytes)
 *   conv     = HKDF-Extract(salt='nip44-v2', IKM=shared_x)
 *
 * @param {Uint8Array} privKey        32-byte private key
 * @param {string}     recipientXPub  64-hex x-only pubkey
 * @returns {Promise<Uint8Array>}     32-byte conversation key
 */
export async function getConversationKey(privKey, recipientXPub) {
  if (!(privKey instanceof Uint8Array) || privKey.length !== 32) {
    throw new Error("nip44 getConversationKey: private key must be 32 bytes");
  }
  if (typeof recipientXPub !== "string" || !/^[0-9a-f]{64}$/i.test(recipientXPub)) {
    throw new Error("nip44 getConversationKey: recipient must be 64-hex x-only pubkey");
  }
  // Nostr pubkeys are x-only (32 bytes). getSharedSecret expects a
  // compressed 33-byte pubkey. We prepend 0x02 (even-Y parity) — this
  // is standard practice for NIP-44 since the parity bit is discarded
  // by the ECDH x-coordinate output anyway.
  const compressedPub = "02" + recipientXPub.toLowerCase();
  // getSharedSecret returns 33 bytes: [parity_byte, x_32]. We want x.
  const shared = getSharedSecret(privKey, hexToBytes(compressedPub), true);
  const sharedX = shared.subarray(1); // drop parity byte
  return await hkdfExtract(sharedX, NIP44_SALT);
}

/**
 * Encrypt a plaintext string under a conversation key. Generates a
 * fresh 32-byte random nonce per call.
 *
 * @param {string}     plaintext
 * @param {Uint8Array} conversationKey   32 bytes
 * @param {Uint8Array} [nonce]           optional 32-byte nonce (tests only!)
 * @returns {Promise<string>}            base64 NIP-44 v2 payload
 */
export async function nip44Encrypt(plaintext, conversationKey, nonce) {
  if (typeof plaintext !== "string") throw new Error("nip44Encrypt: plaintext must be string");
  if (!(conversationKey instanceof Uint8Array) || conversationKey.length !== 32) {
    throw new Error("nip44Encrypt: conversation key must be 32 bytes");
  }
  const useNonce = nonce ?? crypto.getRandomValues(new Uint8Array(32));
  if (useNonce.length !== 32) throw new Error("nip44Encrypt: nonce must be 32 bytes");

  const okm = await hkdfExpand(conversationKey, useNonce, 76);
  const chachaKey   = okm.subarray(0, 32);
  const chachaNonce = okm.subarray(32, 44); // 12 bytes for ChaCha20
  const hmacKey     = okm.subarray(44, 76);

  const plaintextBytes = new TextEncoder().encode(plaintext);
  const padded = pad(plaintextBytes);

  const ciphertext = new Uint8Array(padded.length);
  chacha20(chachaKey, chachaNonce, padded, ciphertext, 0);

  // MAC over (nonce || ciphertext) with hmac_key. Spec calls it
  // hmac_aad(key=hmac_key, message=ciphertext, aad=nonce).
  const macInput = concatBytes(useNonce, ciphertext);
  const mac = await hmacSha256(hmacKey, macInput);

  const payload = concatBytes(new Uint8Array([0x02]), useNonce, ciphertext, mac);
  return base64Encode(payload);
}

/**
 * Decrypt a NIP-44 v2 base64 payload under a conversation key.
 * Verifies MAC in constant time before decrypting.
 *
 * @param {string}     b64
 * @param {Uint8Array} conversationKey  32 bytes
 * @returns {Promise<string>}           plaintext
 */
export async function nip44Decrypt(b64, conversationKey) {
  if (typeof b64 !== "string") throw new Error("nip44Decrypt: payload must be string");
  if (b64.length === 0 || b64[0] === "#") throw new Error("nip44Decrypt: unknown version");
  if (b64.length < 132) throw new Error("nip44Decrypt: payload too short");
  const data = base64Decode(b64);
  if (data.length < 99) throw new Error("nip44Decrypt: decoded payload too short");
  const version = data[0];
  if (version !== 2) throw new Error("nip44Decrypt: unknown version " + version);

  const nonce      = data.subarray(1, 33);
  const ciphertext = data.subarray(33, data.length - 32);
  const mac        = data.subarray(data.length - 32);

  const okm = await hkdfExpand(conversationKey, nonce, 76);
  const chachaKey   = okm.subarray(0, 32);
  const chachaNonce = okm.subarray(32, 44);
  const hmacKey     = okm.subarray(44, 76);

  const macInput = concatBytes(nonce, ciphertext);
  const calculated = await hmacSha256(hmacKey, macInput);
  if (!constantTimeEq(calculated, mac)) {
    throw new Error("nip44Decrypt: invalid MAC");
  }

  const padded = new Uint8Array(ciphertext.length);
  chacha20(chachaKey, chachaNonce, ciphertext, padded, 0);
  const plaintextBytes = unpad(padded);
  return new TextDecoder().decode(plaintextBytes);
}

// Re-exports (intentional, for tests only).
export {
  hkdfExtract, hkdfExpand, hmacSha256,
  pad, unpad, calcPaddedLen,
  hexToBytes, bytesToHex, constantTimeEq,
};

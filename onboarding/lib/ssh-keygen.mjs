// onboarding/lib/ssh-keygen.mjs
//
// Generate a fresh Ed25519 keypair in the browser via WebCrypto and serialize
// it into the two on-the-wire formats OpenSSH-compatible tools expect:
//
//   * public key  → single-line "ssh-ed25519 <base64> <comment>"
//                   (what SHC's POST /ordering/submit accepts as `ssh_key`,
//                   and what ~/.ssh/authorized_keys stores)
//   * private key → "OPENSSH PRIVATE KEY" PEM
//                   (unencrypted; the ssh2 npm module in bridges/webssh/
//                   consumes this directly as `privateKey`)
//
// Nothing here calls the network. Nothing is persisted. The caller is
// responsible for keeping the private key inside the tab lifetime and
// discarding it after handoff.
//
// Requires: WebCrypto Ed25519. Available in Chrome 137+, Firefox 130+,
// Safari 17+. On older browsers window.crypto.subtle.generateKey rejects
// with NotSupportedError — surface that to the user with a clear message.

const TEXT_ENCODER = new TextEncoder();

// ------------------------------- utilities --------------------------------- //

/** Concatenate several Uint8Arrays into one. */
function concat(...parts) {
  let n = 0;
  for (const p of parts) n += p.length;
  const out = new Uint8Array(n);
  let off = 0;
  for (const p of parts) { out.set(p, off); off += p.length; }
  return out;
}

/** Encode a Uint8Array as an SSH "string" (u32 length prefix + bytes). */
function sshString(bytes) {
  const len = new Uint8Array(4);
  new DataView(len.buffer).setUint32(0, bytes.length, false);
  return concat(len, bytes);
}

/** Encode a UTF-8 string as an SSH "string". */
function sshUtf8(s) {
  return sshString(TEXT_ENCODER.encode(s));
}

/** Encode a 32-bit unsigned int as SSH big-endian u32. */
function sshU32(n) {
  const b = new Uint8Array(4);
  new DataView(b.buffer).setUint32(0, n >>> 0, false);
  return b;
}

/** Standard base64 encoding of a Uint8Array. */
function b64(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s);
}

/** Break base64 into 70-char lines (OpenSSH PEM convention). */
function pemWrap(b64str) {
  const lines = [];
  for (let i = 0; i < b64str.length; i += 70) lines.push(b64str.slice(i, i + 70));
  return lines.join("\n");
}

// ------------------------------- Ed25519 raw ------------------------------- //

/**
 * Export a WebCrypto Ed25519 key as its raw 32-byte scalar/point.
 *
 * WebCrypto returns Ed25519 keys wrapped in PKCS#8 (private) or SPKI (public).
 * We need the raw 32-byte forms for OpenSSH's wire format. Rather than pull in
 * a full ASN.1 parser, we exploit the fact that both wrappers end with the
 * raw 32 bytes at a fixed offset.
 *
 *   SPKI public key:   30 2a 30 05 06 03 2b 65 70 03 21 00 <32-byte pubkey>
 *   PKCS#8 private:    30 2e 02 01 00 30 05 06 03 2b 65 70 04 22 04 20 <32-byte seed>
 *
 * The 32-byte tails are exactly what OpenSSH's ed25519 format uses (the
 * "seed" is what OpenSSH calls the private key; the pubkey is the point).
 */
async function exportRawPublic(cryptoKey) {
  const spki = new Uint8Array(await crypto.subtle.exportKey("spki", cryptoKey));
  if (spki.length !== 44) throw new Error(`unexpected SPKI length ${spki.length}`);
  return spki.slice(-32);
}

async function exportRawSeed(cryptoKey) {
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", cryptoKey));
  if (pkcs8.length !== 48) throw new Error(`unexpected PKCS#8 length ${pkcs8.length}`);
  return pkcs8.slice(-32);
}

// ------------------------------- public API -------------------------------- //

/**
 * Generate a fresh Ed25519 SSH keypair usable by OpenSSH and by the `ssh2`
 * npm module (the one bridges/webssh uses).
 *
 * @param {object} [opts]
 * @param {string} [opts.comment]  Trailing comment on the public key line.
 *                                 Defaults to "torii-onboarding".
 * @returns {Promise<{
 *   publicKey:  string,   // "ssh-ed25519 AAAA… comment"
 *   privateKey: string,   // "-----BEGIN OPENSSH PRIVATE KEY-----\n…\n-----END OPENSSH PRIVATE KEY-----\n"
 *   fingerprint: string,  // "SHA256:<base64>" of the pubkey blob
 * }>}
 */
export async function generateSshKeyPair(opts = {}) {
  const comment = String(opts.comment || "torii-onboarding");

  const kp = await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
  const rawPub  = await exportRawPublic(kp.publicKey);
  const rawSeed = await exportRawSeed(kp.privateKey);

  // ----- public key: ssh-ed25519 <base64(blob)> <comment> -----
  //
  //   blob = string("ssh-ed25519") + string(32-byte-pubkey)
  //
  const pubBlob = concat(sshUtf8("ssh-ed25519"), sshString(rawPub));
  const publicKey = `ssh-ed25519 ${b64(pubBlob)} ${comment}`;

  // ----- private key: OPENSSH PRIVATE KEY -----
  //
  // OpenSSH ed25519 v1 unencrypted layout (see PROTOCOL.key in openssh-portable):
  //
  //   magic       = "openssh-key-v1\0"
  //   cipher      = string("none")
  //   kdf         = string("none")
  //   kdfopts     = string("")
  //   nkeys       = u32(1)
  //   pubkey_blob = string( string("ssh-ed25519") + string(pubkey) )
  //   priv_blob   = string(
  //       u32(checkint) + u32(checkint)                              // same value twice
  //     + string("ssh-ed25519")
  //     + string(pubkey)
  //     + string(seed + pubkey)                                      // 64 bytes total
  //     + string(comment)
  //     + padding                                                    // 1,2,3,… up to block size 8
  //   )
  //
  // The "checkint" is a random u32 repeated so a decrypted keyfile can be
  // sanity-checked (cheap MAC). For an unencrypted key we just pick a random
  // value.

  const checkInt = crypto.getRandomValues(new Uint32Array(1))[0];
  const checkBytes = concat(sshU32(checkInt), sshU32(checkInt));

  const privInner = concat(
    checkBytes,
    sshUtf8("ssh-ed25519"),
    sshString(rawPub),
    sshString(concat(rawSeed, rawPub)),
    sshUtf8(comment),
  );

  // Pad to a multiple of 8 with 1,2,3,… (OpenSSH's convention).
  const padLen = (8 - (privInner.length % 8)) % 8;
  const pad = new Uint8Array(padLen);
  for (let i = 0; i < padLen; i++) pad[i] = i + 1;
  const privBlock = concat(privInner, pad);

  const inner = concat(
    TEXT_ENCODER.encode("openssh-key-v1\0"),
    sshUtf8("none"),         // cipher
    sshUtf8("none"),         // kdf
    sshString(new Uint8Array(0)), // kdfopts
    sshU32(1),               // nkeys
    sshString(pubBlob),
    sshString(privBlock),
  );

  const privateKey =
    "-----BEGIN OPENSSH PRIVATE KEY-----\n" +
    pemWrap(b64(inner)) +
    "\n-----END OPENSSH PRIVATE KEY-----\n";

  // ----- fingerprint: SHA256(pubBlob), base64, sans-padding, prefixed -----
  const hash = new Uint8Array(await crypto.subtle.digest("SHA-256", pubBlob));
  const fingerprint = "SHA256:" + b64(hash).replace(/=+$/, "");

  return { publicKey, privateKey, fingerprint };
}

/**
 * Best-effort check that Ed25519 is actually available. Returns a small
 * probe result you can render in the UI without throwing.
 */
export async function probeEd25519() {
  try {
    if (!globalThis.crypto?.subtle) return { supported: false, reason: "no WebCrypto" };
    await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
    return { supported: true };
  } catch (err) {
    return { supported: false, reason: err?.message || String(err) };
  }
}

// nostr-giftwrap.mjs — NIP-59 gift wrap for nostr events.
//
// v0.1.6-alpha (torii-suite/onboarding)
//
// ─── Purpose ───────────────────────────────────────────────────────────
//
// Wraps a signed nostr event (typically a NIP-17 kind:13 seal) inside a
// kind:1059 gift wrap. The outer wrapper is signed by a fresh, single-
// use ephemeral secp256k1 keypair generated in-browser, so relays and
// passive observers cannot link the outer event to the sender's real
// npub.
//
// This closes the sender-pubkey correlation leak that v0.1.5 left open.
// In v0.1.5 the seal was published bare, which meant relays could see:
//
//   "npub X sent a NIP-17 sealed event addressed to npub X"
//
// Even though the payload was NIP-44 encrypted, the sender pubkey was
// visible on the wire, correlating the recovery hint to the user's
// long-term identity. With gift-wrap:
//
//   "some random one-time pubkey sent a kind-1059 event addressed to npub X"
//
// The random ephemeral pubkey has never been used before and will never
// be used again. It reveals nothing about the sender.
//
// ─── Ephemeral key lifecycle ───────────────────────────────────────────
//
// The ephemeral private key exists only inside `buildGiftWrap` and is
// dropped when that function returns. It never leaves the browser, is
// never persisted to storage, is never logged, and is never passed to
// the user's NIP-07 signer.
//
// We do best-effort key wiping via `zeroize()` after signing — the JS
// engine may still hold copies in intermediate buffers (there is no
// portable way to force zero memory in JS), but wiping the reference
// we control shortens the window in which a memory dump could recover
// the key.
//
// ─── Timestamp jitter ──────────────────────────────────────────────────
//
// NIP-59 recommends randomising `created_at` for both the seal and the
// wrap up to 2 days in the past, so relays cannot correlate events by
// send time. This module handles the wrap timestamp. The caller is
// responsible for the seal timestamp (already handled by nostr-dm.mjs's
// buildNip17Seal).
//
// ─── Spec reference ────────────────────────────────────────────────────
//
// Full spec: https://github.com/nostr-protocol/nips/blob/master/59.md
//
// Wire format of a kind:1059 gift wrap:
//
// {
//   id:         sha256 of canonical [0, pubkey, created_at, 1059, tags, content]
//   pubkey:     ephemeral xonly hex (32 bytes)
//   kind:       1059
//   created_at: real_time - random(0, 2 days)
//   tags:       [["p", recipient_pubkey_hex]]
//   content:    base64 NIP-44 v2 encrypted seal JSON
//   sig:        BIP-340 Schnorr signature of `id` under the ephemeral key
// }

import {
  schnorr,
  utils as secp256k1Utils,
} from "./vendor/noble-secp256k1/secp256k1.mjs";
import { getConversationKey, nip44Encrypt } from "./nostr-nip44.mjs";
import { computeEventId, assertSignedEvent } from "./nostr-event.mjs";

const TWO_DAYS_SECONDS = 2 * 24 * 60 * 60;

/**
 * Return a `created_at` value randomly between (now - 2 days) and now.
 * Per NIP-59 §Other Considerations. Never in the future.
 */
function randomPastTimestamp() {
  const now = Math.floor(Date.now() / 1000);
  return now - Math.floor(Math.random() * TWO_DAYS_SECONDS);
}

/**
 * Best-effort key wipe. Overwrites the byte array in place. JS may still
 * hold copies elsewhere; this only clears the reference we own.
 * @param {Uint8Array} bytes
 */
function zeroize(bytes) {
  if (bytes && typeof bytes.fill === "function") bytes.fill(0);
}

/**
 * Convert bytes → lowercase hex.
 * @param {Uint8Array} bytes
 */
function bytesToHex(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i++) s += bytes[i].toString(16).padStart(2, "0");
  return s;
}

/**
 * Convert lowercase hex → bytes.
 * @param {string} hex
 */
function hexToBytes(hex) {
  if (hex.length % 2 !== 0) throw new Error("hexToBytes: odd length");
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.substr(i * 2, 2), 16);
  return out;
}

/**
 * Wrap a signed nostr event in a NIP-59 kind:1059 gift wrap.
 *
 * @param {object}  opts
 * @param {object}  opts.seal              a signed nostr event (usually kind:13)
 * @param {string}  opts.recipientPubkey   64-hex x-only recipient pubkey
 * @returns {Promise<object>}              signed kind:1059 gift wrap event
 */
export async function buildGiftWrap({ seal, recipientPubkey }) {
  if (!seal || typeof seal !== "object") {
    throw new Error("buildGiftWrap: seal must be a signed event");
  }
  if (typeof recipientPubkey !== "string" || !/^[0-9a-f]{64}$/i.test(recipientPubkey)) {
    throw new Error("buildGiftWrap: recipientPubkey must be 64-hex x-only");
  }
  // Sanity-check the seal — a malformed seal here would produce a
  // gift-wrap the recipient could not decrypt, so fail loudly.
  assertSignedEvent(seal);

  // 1. Generate a fresh ephemeral keypair.
  const ephemeralSk = secp256k1Utils.randomSecretKey();
  let ephemeralXPub;
  let signedWrap;
  try {
    ephemeralXPub = bytesToHex(await schnorr.getPublicKey(ephemeralSk));

    // 2. Derive the conversation key from (ephemeralSk, recipientPubkey)
    //    and NIP-44 v2 encrypt the JSON of the seal.
    const convKey = await getConversationKey(ephemeralSk, recipientPubkey);
    const sealJson = JSON.stringify(seal);
    const encryptedContent = await nip44Encrypt(sealJson, convKey);
    // Wipe the derived conversation key. The seal JSON itself is
    // plaintext until the GC collects it; we can't force-clear a JS
    // string.
    zeroize(convKey);

    // 3. Build the kind:1059 event.
    const wrap = {
      pubkey: ephemeralXPub,
      created_at: randomPastTimestamp(),
      kind: 1059,
      tags: [["p", recipientPubkey.toLowerCase()]],
      content: encryptedContent,
    };
    wrap.id = await computeEventId(wrap);

    // 4. BIP-340 Schnorr sign under the ephemeral key.
    const sig = await schnorr.signAsync(hexToBytes(wrap.id), ephemeralSk);
    wrap.sig = bytesToHex(sig);

    signedWrap = wrap;
  } finally {
    // 5. Ephemeral key MUST NOT survive this function. Wipe first,
    //    then drop the reference. Do this in `finally` so a throw
    //    inside the try does not leave the key on the heap.
    zeroize(ephemeralSk);
  }

  assertSignedEvent(signedWrap);
  return signedWrap;
}

// Re-exports for tests only.
export { randomPastTimestamp, bytesToHex, hexToBytes };

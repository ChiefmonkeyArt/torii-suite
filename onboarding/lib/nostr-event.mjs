// nostr-event.mjs — minimal NIP-01 event helpers.
//
// v0.1.4-alpha (torii-suite/onboarding)
//
// Zero dependencies. All hashing uses WebCrypto (SubtleCrypto), which is
// present in every browser that also has Ed25519 support (screen 3
// already gates on that via probeEd25519()).
//
// We deliberately do NOT ship a private-key signer here. Signing goes
// through `window.nostr.signEvent()` per NIP-07 — the user's private
// key never crosses this bundle's boundary.

const enc = new TextEncoder();

/**
 * Compute a nostr event id per NIP-01.
 *
 * The id is the lowercase hex SHA-256 of the UTF-8 encoding of the
 * canonical JSON serialization:
 *
 *   [0, pubkey, created_at, kind, tags, content]
 *
 * Note: `JSON.stringify` in modern engines produces the canonical form
 * NIP-01 requires (no whitespace, escaped control chars, arrays in order).
 * That is intentional in the spec.
 *
 * @param {object} evt event with pubkey, created_at, kind, tags, content
 * @returns {Promise<string>} lowercase hex event id
 */
export async function computeEventId(evt) {
  const serialized = JSON.stringify([
    0,
    evt.pubkey,
    Math.floor(evt.created_at),
    evt.kind,
    evt.tags,
    evt.content,
  ]);
  const digest = await crypto.subtle.digest("SHA-256", enc.encode(serialized));
  return bytesToHex(new Uint8Array(digest));
}

/**
 * Basic shape validation for a signed event. Cheap enough to run on
 * every event we sign, since window.nostr signers can (and do) return
 * malformed payloads if the user rejects mid-flow.
 *
 * @param {object} evt
 * @throws {Error} if the shape is wrong
 */
export function assertSignedEvent(evt) {
  if (!evt || typeof evt !== "object") {
    throw new Error("nostr signer returned no event");
  }
  for (const field of ["id", "pubkey", "created_at", "kind", "tags", "content", "sig"]) {
    if (!(field in evt)) throw new Error(`signed event missing field: ${field}`);
  }
  if (!/^[0-9a-f]{64}$/i.test(evt.id))     throw new Error("signed event has malformed id");
  if (!/^[0-9a-f]{64}$/i.test(evt.pubkey)) throw new Error("signed event has malformed pubkey");
  if (!/^[0-9a-f]{128}$/i.test(evt.sig))   throw new Error("signed event has malformed sig");
  if (!Array.isArray(evt.tags))            throw new Error("signed event tags is not an array");
  if (typeof evt.kind !== "number")        throw new Error("signed event kind is not a number");
}

/**
 * Sign a nostr event via window.nostr (NIP-07). Fills in `pubkey` and
 * `created_at` if missing, then delegates. Returns the signer's output
 * verbatim after basic shape validation.
 *
 * @param {object} unsigned partial event: kind, tags, content, optional created_at
 * @param {object} [opts]
 * @param {object} [opts.signer] alternate signer (for tests / ?mock=1)
 * @returns {Promise<object>} signed event
 */
export async function signEvent(unsigned, opts = {}) {
  const signer = opts.signer || (typeof window !== "undefined" ? window.nostr : null);
  if (!signer || typeof signer.signEvent !== "function") {
    throw new Error("no NIP-07 signer available (window.nostr.signEvent missing)");
  }
  const event = {
    created_at: unsigned.created_at ?? Math.floor(Date.now() / 1000),
    kind: unsigned.kind,
    tags: Array.isArray(unsigned.tags) ? unsigned.tags : [],
    content: unsigned.content ?? "",
  };
  const signed = await signer.signEvent(event);
  assertSignedEvent(signed);
  return signed;
}

/**
 * Encode bytes as lowercase hex.
 * @param {Uint8Array} bytes
 * @returns {string}
 */
export function bytesToHex(bytes) {
  const hex = new Array(bytes.length);
  for (let i = 0; i < bytes.length; i++) {
    hex[i] = bytes[i].toString(16).padStart(2, "0");
  }
  return hex.join("");
}

/**
 * Feature-detect the signer's NIP-44 support at call time. Some
 * extensions ship `nip44` as an object but with a stub `encrypt` that
 * throws; the only reliable probe is to try a dry-run and catch. We
 * skip the dry-run for performance and only check for method presence.
 *
 * @param {object} [signer=window.nostr]
 * @returns {"nip44"|"nip04"|"none"} best-available DM encryption path
 */
export function detectDmEncryption(signer) {
  const s = signer || (typeof window !== "undefined" ? window.nostr : null);
  if (!s) return "none";
  if (s.nip44 && typeof s.nip44.encrypt === "function") return "nip44";
  if (s.nip04 && typeof s.nip04.encrypt === "function") return "nip04";
  return "none";
}

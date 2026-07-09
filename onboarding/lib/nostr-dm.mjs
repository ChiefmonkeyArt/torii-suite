// nostr-dm.mjs — encrypted DM to the operator's own npub.
//
// v0.1.4-alpha (torii-suite/onboarding)
//
// After the VPS is bootstrapped, we DM the user their own recovery
// bundle (SHC login, API key, SSH private key). The DM is encrypted
// to their own pubkey so it lands in their inbox on any nostr client
// that reads DMs — Amethyst, Damus, Coracle, Primal, etc.
//
// The DM is sent to *self*: sender == recipient == user's npub. This
// keeps the encryption trivial (no ephemeral wrapper keys required)
// and means the user can retrieve it from any signer that owns the
// key, without depending on torii-suite being online.
//
// Two paths, selected at runtime:
//
//   1. NIP-17 sealed DM (kind 13) — preferred when the signer exposes
//      window.nostr.nip44.encrypt. Content is a NIP-44-encrypted
//      kind-14 rumor. We omit the outer kind-1059 gift-wrap because
//      for a self-DM the wrap layer doesn't hide any metadata that
//      the seal itself doesn't already hide (sender == recipient).
//
//   2. NIP-04 legacy DM (kind 4) — fallback when only nip04 is
//      available. Universally supported by every signer that has
//      shipped in the last five years. Deprecated but works.
//
// If neither is available, we throw a labeled error so the UI can
// tell the user to copy the secrets manually before closing the tab.

import { signEvent, detectDmEncryption } from "./nostr-event.mjs";
import { publishToRelays, DEFAULT_RELAYS } from "./nostr-relay.mjs";

/**
 * The plaintext payload we DM to the user. Kept as a plain object so
 * the receiving client shows it as parseable JSON if their DM view
 * lets them see the raw content, but the human-readable header at the
 * top of `content` also renders well in a chat bubble.
 *
 * @typedef {object} DmPayload
 * @property {string} title         short human-facing title
 * @property {string} hostname      e.g. "alice.torii.host"
 * @property {string} vpsIp         public IP of the VPS
 * @property {string} osUser        SSH login user (usually "debian" or "root")
 * @property {string} sshPrivateKey OpenSSH-format Ed25519 private key
 * @property {string} sshFingerprint SHA256 fingerprint
 * @property {string} shcApiKey     shc_live_... string
 * @property {string} shcApiKeyExpires ISO date
 * @property {string} shcEmail      the anon email we registered
 * @property {string} shcPassword   the derived password
 */

/**
 * Format the plaintext DM body. We put a human-readable header first,
 * then a JSON block so machine-readable clients can pull it back out.
 * Line-wrapped at ~72 columns because most DM clients don't soft-wrap.
 *
 * @param {DmPayload} p
 * @returns {string}
 */
function formatDmBody(p) {
  const header = [
    `torii · your recovery bundle`,
    ``,
    `Keep this DM. It is the only long-term copy of the secrets your`,
    `browser generated during onboarding. Anyone with these values can`,
    `take over your VPS \u2014 do not paste them into any chat, form, or`,
    `screen-shared window.`,
    ``,
    `hostname:   ${p.hostname}`,
    `vps ip:     ${p.vpsIp}`,
    `ssh user:   ${p.osUser}`,
    `ssh fp:     ${p.sshFingerprint}`,
    `shc key:    scoped=operate, expires ${p.shcApiKeyExpires}`,
    ``,
    `\u2500\u2500\u2500 machine-readable payload below \u2500\u2500\u2500`,
    ``,
  ].join("\n");

  // Pretty-printed JSON so the user's client shows it cleanly if it
  // renders whitespace at all. Newlines inside a JSON string are
  // preserved in NIP-17 rumor content and NIP-04 kind-4 content alike.
  const body = JSON.stringify(
    {
      version: 1,
      kind: "torii-recovery-bundle",
      hostname: p.hostname,
      vps: { ip: p.vpsIp, os_user: p.osUser },
      ssh: {
        fingerprint: p.sshFingerprint,
        private_key_openssh: p.sshPrivateKey,
      },
      shc: {
        email: p.shcEmail,
        password: p.shcPassword,
        api_key: p.shcApiKey,
        api_key_expires: p.shcApiKeyExpires,
      },
    },
    null,
    2,
  );

  return header + body;
}

/**
 * Build and sign an NIP-17 sealed self-DM (kind 13).
 *
 * The inner rumor is unsigned, encrypted with NIP-44 using the
 * conversation key derived from (senderPrivateKey, recipientPubkey).
 * Because sender == recipient in a self-DM, that's the same key on
 * both sides — the signer handles this transparently via
 * `nip44.encrypt(recipientPubkey, plaintext)`.
 *
 * @param {string} recipientPubkey hex pubkey (== sender for self-DM)
 * @param {string} bodyText        plaintext to encrypt
 * @param {object} [signer=window.nostr]
 * @returns {Promise<object>} signed kind-13 seal event
 */
async function buildNip17Seal(recipientPubkey, bodyText, signer) {
  const s = signer || window.nostr;
  const now = Math.floor(Date.now() / 1000);

  // NIP-17 recommends randomizing created_at up to 2 days in the past
  // to blur metadata across relays. For a self-DM this is cosmetic
  // (the recipient tag is us), but we do it anyway for consistency.
  const jitter = Math.floor(Math.random() * 172800); // 0..2 days
  const rumorCreatedAt = now - jitter;
  const sealCreatedAt  = now - Math.floor(Math.random() * 172800);

  // Step 1: build the unsigned kind-14 rumor. Rumor is *not* signed;
  // NIP-17 explicitly requires it stay unsigned. It only gets an id
  // for verification later.
  const { computeEventId } = await import("./nostr-event.mjs");
  const rumor = {
    pubkey: recipientPubkey, // sender == recipient for self-DM
    created_at: rumorCreatedAt,
    kind: 14,
    tags: [["p", recipientPubkey]],
    content: bodyText,
  };
  rumor.id = await computeEventId(rumor);

  // Step 2: encrypt the rumor JSON using the signer's NIP-44 impl.
  const rumorJson = JSON.stringify(rumor);
  const sealedContent = await s.nip44.encrypt(recipientPubkey, rumorJson);

  // Step 3: sign the kind-13 seal with the sender's key. Tags must be
  // empty per the spec, so a network observer can't distinguish seals
  // sent to different recipients.
  const seal = await signEvent(
    { kind: 13, tags: [], content: sealedContent, created_at: sealCreatedAt },
    { signer: s },
  );
  return seal;
}

/**
 * Build and sign a legacy NIP-04 self-DM (kind 4). Simpler than
 * NIP-17 but leaks that a DM to self was sent (the ["p", pubkey] tag
 * is public). For a recovery bundle that's an acceptable trade — the
 * secrets themselves stay encrypted.
 *
 * @param {string} recipientPubkey
 * @param {string} bodyText
 * @param {object} [signer=window.nostr]
 * @returns {Promise<object>} signed kind-4 event
 */
async function buildNip04Dm(recipientPubkey, bodyText, signer) {
  const s = signer || window.nostr;
  const cipherText = await s.nip04.encrypt(recipientPubkey, bodyText);
  return signEvent(
    { kind: 4, tags: [["p", recipientPubkey]], content: cipherText },
    { signer: s },
  );
}

/**
 * Send the recovery bundle to the user's own npub. Picks NIP-17 when
 * available, falls back to NIP-04, and throws a labeled error if
 * neither is possible.
 *
 * @param {DmPayload} payload
 * @param {object}    opts
 * @param {string}    opts.recipientPubkey        hex pubkey (== user's npub)
 * @param {string[]}  [opts.relays=DEFAULT_RELAYS]
 * @param {number}    [opts.timeoutMs=8000]       per-relay publish timeout
 * @param {(r:object)=>void} [opts.onRelayResult] fires per relay as they ACK
 * @param {object}    [opts.signer=window.nostr] override for tests / mock
 * @returns {Promise<{scheme: "nip17"|"nip04", eventId: string, okCount: number, results: Array}>}
 */
export async function sendRecoveryDm(payload, opts) {
  if (!opts?.recipientPubkey || !/^[0-9a-f]{64}$/i.test(opts.recipientPubkey)) {
    throw new Error("sendRecoveryDm: recipientPubkey must be a 64-hex string");
  }
  const signer = opts.signer || (typeof window !== "undefined" ? window.nostr : null);
  const scheme = detectDmEncryption(signer);
  if (scheme === "none") {
    throw new Error(
      "nostr signer exposes neither nip44.encrypt nor nip04.encrypt — " +
      "cannot send the recovery DM. Copy the secrets from this screen manually.",
    );
  }

  const bodyText = formatDmBody(payload);

  const signedEvent = scheme === "nip44"
    ? await buildNip17Seal(opts.recipientPubkey, bodyText, signer)
    : await buildNip04Dm(opts.recipientPubkey, bodyText, signer);

  const publishResult = await publishToRelays(signedEvent, {
    relays: opts.relays || DEFAULT_RELAYS,
    timeoutMs: opts.timeoutMs,
    onResult: opts.onRelayResult,
  });

  return {
    scheme,
    eventId: publishResult.eventId,
    okCount: publishResult.okCount,
    results: publishResult.results,
  };
}

export { formatDmBody, buildNip17Seal, buildNip04Dm };

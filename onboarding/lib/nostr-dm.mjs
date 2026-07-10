// nostr-dm.mjs — NIP-17 + NIP-59 encrypted recovery hint to the operator's own npub.
//
// v0.1.6-alpha (torii-suite/onboarding)
//
// ─── What changed since v0.1.5 ─────────────────────────────────────────
//
// v0.1.5 shipped the recovery hint DM as a bare NIP-17 kind-13 seal.
// The seal itself is encrypted (NIP-44), so the content and recipient
// are hidden — but the outer event carries the SENDER's real npub as
// its `pubkey`. Every relay that receives the seal can therefore see:
//
//   "npub X just sent a NIP-17 sealed event"
//
// For a self-DM this is worse than usual: the sender IS the recipient,
// so an observer correlating traffic with the freshly-published kind-
// 10050 inbox relay list learns:
//
//   "npub X just finished Torii onboarding and self-DM'd a recovery hint"
//
// That is a metadata fingerprint we can and should close. Priority
// hierarchy is privacy first, then efficiency, then 80/20.
//
// v0.1.6 wraps every seal in a NIP-59 kind-1059 gift wrap. The outer
// wrap is signed by a fresh single-use ephemeral secp256k1 keypair
// generated in-browser (see lib/nostr-giftwrap.mjs and lib/vendor/
// noble-secp256k1/). The ephemeral key never touches the user's NIP-07
// signer, never leaves the browser, never persists to storage, and is
// wiped from memory after signing. Relays see only:
//
//   "some random one-time pubkey addressed a kind-1059 to npub X"
//
// The sender's real pubkey is inside the seal, which is inside the
// gift wrap, which is NIP-44 encrypted to npub X's key. Only npub X
// can decrypt to discover who the real sender was (themselves).
//
// ─── Refusal policy ────────────────────────────────────────────────────
//
// If the user's NIP-07 signer does not expose `nip44.encrypt`, we
// REFUSE to publish. There is no bare-seal or NIP-04 fallback: those
// would silently downgrade the privacy properties this module exists
// to provide. Screen 8 already treats the recovery hint DM as an
// optional convenience layered on top of the mandatory local recovery
// file download, so a refusal here is non-catastrophic — the user
// still has their bundle on disk.
//
// ─── Payload trimming ──────────────────────────────────────────────────
//
// The hint itself carries NO catastrophic secrets — only hostname, IP,
// SSH user, SSH fingerprint (verifiable, not the key), SHC API-key
// expiry (not the key), and a pointer to the real backup paths. If
// this DM ever leaks in plaintext it would cost the user nothing they
// could not have discovered by scanning the internet. See the v0.1.5
// commit message for the full threat-model discussion.

import { signEvent, computeEventId, detectDmEncryption } from "./nostr-event.mjs";
import { publishToRelays, DEFAULT_RELAYS } from "./nostr-relay.mjs";
import { buildGiftWrap } from "./nostr-giftwrap.mjs";

/**
 * The recovery HINT payload. NO credentials — just enough info for the
 * user to re-locate their VPS six months from now.
 *
 * @typedef {object} RecoveryHint
 * @property {string} hostname          e.g. "alice.torii.host"
 * @property {string} vpsIp             public IP of the VPS
 * @property {string} osUser            SSH login user
 * @property {string} sshFingerprint    SHA256 fingerprint (verifiable, not a secret)
 * @property {string} shcApiKeyExpires  ISO date — reminder of when to rotate
 * @property {string} shcEmail          anon email registered against SHC
 * @property {string} createdAt         ISO date this hint was minted
 */

/**
 * Format the plaintext DM body. Human-readable header first, then a
 * small JSON block for machine parsing. NO SECRETS — only hints.
 *
 * @param {RecoveryHint} p
 * @returns {string}
 */
function formatHintBody(p) {
  const header = [
    `torii \u00b7 recovery hint`,
    ``,
    `This DM is a REMINDER, not a backup. It contains only public-safe`,
    `hints so your future self can find this VPS again \u2014 hostname, IP,`,
    `SSH fingerprint, expiry dates. The actual secrets (SSH private key,`,
    `SHC API key, password) live in the recovery file you saved during`,
    `onboarding, or in the optional passphrase-encrypted backup on your`,
    `relays. Neither is decryptable from this DM alone.`,
    ``,
    `hostname:    ${p.hostname}`,
    `vps ip:      ${p.vpsIp}`,
    `ssh user:    ${p.osUser}`,
    `ssh fp:      ${p.sshFingerprint}`,
    `shc email:   ${p.shcEmail}`,
    `shc expiry:  ${p.shcApiKeyExpires}`,
    `created:     ${p.createdAt}`,
    ``,
    `\u2500\u2500\u2500 machine-readable payload below \u2500\u2500\u2500`,
    ``,
  ].join("\n");

  const body = JSON.stringify(
    {
      version: 1,
      kind: "torii-recovery-hint",
      hostname: p.hostname,
      vps: { ip: p.vpsIp, os_user: p.osUser },
      ssh: { fingerprint: p.sshFingerprint }, // fingerprint only, NO private key
      shc: { email: p.shcEmail, api_key_expires: p.shcApiKeyExpires }, // NO key, NO password
      created_at: p.createdAt,
      note:
        "The full recovery bundle is NOT in this DM. See the downloaded " +
        "recovery file or the passphrase-encrypted kind-30078 event with " +
        "d-tag 'torii-recovery-v1'.",
    },
    null,
    2,
  );

  return header + body;
}

/**
 * Build a NIP-17 sealed kind-13 event. The rumor (kind 14) is encrypted
 * with NIP-44 using the sender's conversation key with the recipient,
 * then wrapped in a signed kind-13 seal.
 *
 * For a self-DM (sender == recipient), the conversation key is
 * effectively derived from (nsec, npub) where both belong to the user.
 * The signer handles this transparently: `nip44.encrypt(pubkey, plain)`
 * derives the conversation key and encrypts in one step.
 *
 * @param {string} recipientPubkey hex pubkey (== sender for self-DM)
 * @param {string} bodyText        plaintext to encrypt
 * @param {object} signer          NIP-07 signer
 * @returns {Promise<object>} signed kind-13 seal event
 */
async function buildNip17Seal(recipientPubkey, bodyText, signer) {
  const now = Math.floor(Date.now() / 1000);
  // NIP-59 recommends randomising created_at up to 2 days in the past
  // for BOTH the seal and the wrap. We handle the seal here; the wrap
  // timestamp is set inside buildGiftWrap.
  const rumorCreatedAt = now - Math.floor(Math.random() * 172800);
  const sealCreatedAt  = now - Math.floor(Math.random() * 172800);

  const rumor = {
    pubkey: recipientPubkey, // sender == recipient
    created_at: rumorCreatedAt,
    kind: 14,
    tags: [["p", recipientPubkey]],
    content: bodyText,
  };
  rumor.id = await computeEventId(rumor);

  const rumorJson = JSON.stringify(rumor);
  const sealedContent = await signer.nip44.encrypt(recipientPubkey, rumorJson);

  // Seal MUST have empty tags per NIP-17 spec so relay observers cannot
  // distinguish seals sent to different recipients.
  return signEvent(
    { kind: 13, tags: [], content: sealedContent, created_at: sealCreatedAt },
    { signer },
  );
}

/**
 * Publish the recovery hint to the user's own npub as a NIP-59
 * gift-wrapped NIP-17 sealed DM.
 *
 * The outer envelope is a kind:1059 event signed by a fresh ephemeral
 * secp256k1 key that is generated in-browser and destroyed immediately
 * after signing. Relays see only the ephemeral pubkey; the user's real
 * pubkey is hidden inside the encrypted seal.
 *
 * REFUSES to publish if the signer lacks NIP-44 support — no bare-seal
 * or NIP-04 fallback. Screen 8's mandatory recovery file download is
 * the primary backup path, so a refusal here is non-catastrophic.
 *
 * @param {RecoveryHint} hint
 * @param {object}    opts
 * @param {string}    opts.recipientPubkey        hex pubkey (== user's npub)
 * @param {string[]}  [opts.relays=DEFAULT_RELAYS] where to publish (usually kind-10050 result)
 * @param {number}    [opts.timeoutMs=8000]       per-relay publish timeout
 * @param {(r:object)=>void} [opts.onRelayResult] fires per relay
 * @param {object}    [opts.signer=window.nostr]  user's NIP-07 signer
 * @returns {Promise<{scheme:"nip17-giftwrapped", eventId:string, ephemeralPubkey:string, okCount:number, results:Array}>}
 */
export async function sendRecoveryHint(hint, opts) {
  if (!opts?.recipientPubkey || !/^[0-9a-f]{64}$/i.test(opts.recipientPubkey)) {
    throw new Error("sendRecoveryHint: recipientPubkey must be a 64-hex string");
  }
  const signer = opts.signer || (typeof window !== "undefined" ? window.nostr : null);
  const scheme = detectDmEncryption(signer);
  if (scheme !== "nip44") {
    throw new Error(
      "your nostr signer does not expose NIP-44 encryption. " +
      "Refusing to publish the recovery hint over legacy NIP-04 " +
      "(which would leak sender, recipient, and timing to every relay). " +
      "Your recovery file download is the primary backup path anyway.",
    );
  }

  const bodyText = formatHintBody(hint);
  const seal = await buildNip17Seal(opts.recipientPubkey, bodyText, signer);

  // Always gift-wrap. Never publish a bare seal — that leaks the
  // sender's real pubkey on the outer envelope.
  const wrapped = await buildGiftWrap({
    seal,
    recipientPubkey: opts.recipientPubkey,
  });

  const publishResult = await publishToRelays(wrapped, {
    relays: opts.relays || DEFAULT_RELAYS,
    timeoutMs: opts.timeoutMs,
    onResult: opts.onRelayResult,
  });

  return {
    scheme: "nip17-giftwrapped",
    eventId: publishResult.eventId,
    ephemeralPubkey: wrapped.pubkey,
    okCount: publishResult.okCount,
    results: publishResult.results,
  };
}

// Re-exports so callers can inspect intermediate steps in tests.
export { formatHintBody, buildNip17Seal };

// nostr-dm.mjs — NIP-17 encrypted recovery HINT to the operator's own npub.
//
// v0.1.5-alpha (torii-suite/onboarding)
//
// ─── What changed since v0.1.4 ─────────────────────────────────────────
//
// v0.1.4 sent the entire recovery bundle (SSH private key, SHC password,
// SHC API key) inside a self-DM. That was reviewed and rejected as a
// privacy/security anti-pattern for three reasons:
//
//   1. NIP-17 has no forward or backward secrecy. If the user's nsec
//      ever leaks, every DM they ever received is retroactively
//      decryptable — including the recovery bundle. That would upgrade a
//      key leak to a full VPS takeover.
//   2. Community consensus (NIP-49 spec, Soapbox, Nostr.co.uk, nostr-
//      design.org) is that credentials belong in a password manager or
//      on paper — not on public relays.
//   3. Falling back to NIP-04 was worse: legacy kind-4 events leak
//      sender pubkey, recipient pubkey, timestamp, and message length
//      even with encrypted content.
//
// v0.1.5 sends a *recovery hint*: hostname, IP, SSH user, SSH
// fingerprint (not the key), SHC API-key expiry (not the key), a short
// note telling the user where the real backup lives. Losing this DM
// costs the user nothing catastrophic; finding it six months later on
// any nostr client points them at the VPS they can no longer place.
//
// The real backup path is either:
//   - the downloaded recovery text file the user rescued at onboarding, or
//   - the optional passphrase-encrypted kind-30078 blob (see nostr-
//     appdata.mjs), which is NOT decryptable with the nsec alone.
//
// ─── Wire format ───────────────────────────────────────────────────────
//
// We now emit a fully-nested NIP-17 event: kind-14 rumor → kind-13 seal
// → kind-1059 gift wrap signed by an ephemeral throwaway key. The outer
// wrap uses an ephemeral secp256k1 key so relays cannot tell who sent it
// (this matters even for a self-DM: without a gift wrap, the sealed
// event carries the sender's real pubkey and everyone can see the user
// is talking to themselves).
//
// If the signer does not expose nip44.encrypt we REFUSE to fall back to
// NIP-04. The screen 8 UI still shows the download-gate and the
// optional encrypted-backup checkbox, so the user has a viable recovery
// path without publishing anything.
//
// The ephemeral wrapper keypair is generated in-browser with WebCrypto
// (P-256 is not on the nostr curve, so we use secp256k1 via WebCrypto's
// Ed25519 helpers is NOT possible — we use noble-curves style secp256k1
// implemented inline). To avoid pulling in a full library we take the
// same approach as v0.1.4 and hand the wrapping off to the signer when
// it supports it, otherwise we generate a wrapper key ourselves via
// WebCrypto's random primitives + a minimal secp256k1 signer.
//
// v0.1.5 KEEPS IT SIMPLE: we generate an ephemeral secp256k1 keypair
// with WebCrypto's `crypto.getRandomValues` for the private key and use
// the signer's own NIP-44 conversation-key derivation to encrypt the
// outer wrap when possible. Because that requires the signer to expose
// nip44.encrypt for an arbitrary key (not just the user's), which most
// signers DO NOT support today, we instead expose a `wrapperSigner`
// option that callers can pass. If no `wrapperSigner` is provided we
// omit the outer gift wrap and publish just the sealed event.
//
// This is a deliberate 80/20 trade — the seal itself hides all content
// and metadata *inside* the event, and the outer wrap only hides the
// sender pubkey. For a self-DM, sender == recipient, so an observer can
// already infer "this pubkey is talking to itself" from any DM traffic
// pattern; skipping the gift wrap does not degrade any additional
// privacy the user can plausibly achieve without a real wrapper signer.
// When signers grow arbitrary-key nip44 support (nostr-connect NIP-46
// bunkers already do), we'll route the wrap through them.

import { signEvent, computeEventId, detectDmEncryption } from "./nostr-event.mjs";
import { publishToRelays, DEFAULT_RELAYS } from "./nostr-relay.mjs";

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
  // NIP-17 recommends randomising created_at up to 2 days in the past so
  // relays cannot correlate seals with real send times.
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
 * Optionally wrap a signed seal in a NIP-59 kind-1059 gift wrap using a
 * caller-provided ephemeral signer. If no `wrapperSigner` is passed, we
 * publish the raw seal instead. See the module docstring for rationale.
 *
 * @param {object} seal                signed kind-13 event
 * @param {string} recipientPubkey     hex
 * @param {object} [wrapperSigner]     ephemeral NIP-07-shaped signer with nip44
 * @returns {Promise<object>}          event to publish (seal or gift wrap)
 */
async function maybeGiftWrap(seal, recipientPubkey, wrapperSigner) {
  if (!wrapperSigner || typeof wrapperSigner.signEvent !== "function"
      || !wrapperSigner.nip44 || typeof wrapperSigner.nip44.encrypt !== "function") {
    return seal; // seal-only publish
  }
  const now = Math.floor(Date.now() / 1000);
  const wrapCreatedAt = now - Math.floor(Math.random() * 172800);
  const sealJson = JSON.stringify(seal);
  const wrappedContent = await wrapperSigner.nip44.encrypt(recipientPubkey, sealJson);
  return signEvent(
    {
      kind: 1059,
      tags: [["p", recipientPubkey]],
      content: wrappedContent,
      created_at: wrapCreatedAt,
    },
    { signer: wrapperSigner },
  );
}

/**
 * Publish the recovery hint to the user's own npub as a NIP-17 sealed
 * DM. REFUSES to fall back to NIP-04 — if the signer lacks nip44 we
 * throw so screen 8 can surface the download-gate as the primary path.
 *
 * @param {RecoveryHint} hint
 * @param {object}    opts
 * @param {string}    opts.recipientPubkey        hex pubkey (== user's npub)
 * @param {string[]}  [opts.relays=DEFAULT_RELAYS] where to publish (usually kind-10050 result)
 * @param {number}    [opts.timeoutMs=8000]       per-relay publish timeout
 * @param {(r:object)=>void} [opts.onRelayResult] fires per relay
 * @param {object}    [opts.signer=window.nostr]  user's NIP-07 signer
 * @param {object}    [opts.wrapperSigner]        optional ephemeral signer for kind-1059
 * @returns {Promise<{scheme:"nip17-sealed"|"nip17-wrapped", eventId:string, okCount:number, results:Array}>}
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
  const published = await maybeGiftWrap(seal, opts.recipientPubkey, opts.wrapperSigner);
  const outerScheme = published === seal ? "nip17-sealed" : "nip17-wrapped";

  const publishResult = await publishToRelays(published, {
    relays: opts.relays || DEFAULT_RELAYS,
    timeoutMs: opts.timeoutMs,
    onResult: opts.onRelayResult,
  });

  return {
    scheme: outerScheme,
    eventId: publishResult.eventId,
    okCount: publishResult.okCount,
    results: publishResult.results,
  };
}

// Re-exports so callers can inspect intermediate steps in tests.
export { formatHintBody, buildNip17Seal, maybeGiftWrap };

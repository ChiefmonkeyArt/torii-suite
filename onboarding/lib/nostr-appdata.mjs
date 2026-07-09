// nostr-appdata.mjs — publish a NIP-33 parameterized replaceable event
// (kind 30078) carrying an application-defined payload.
//
// v0.1.5-alpha (torii-suite/onboarding)
//
// Kind 30078 is the community-agreed catch-all for arbitrary app data on
// nostr, addressed by (kind, pubkey, d-tag). Because it is *replaceable*,
// re-publishing with the same d-tag supersedes the previous copy across
// well-behaved relays — no accumulation of stale ciphertexts.
//
// We use it here for the optional passphrase-encrypted recovery bundle
// (the "torii-recovery-v1" d-tag). The event content is the
// `torii-ncrypt1…` envelope produced by lib/nostr-crypto.mjs. Because
// the ciphertext is opaque bytes to the relay, only the passphrase holder
// can extract anything — even the relay operator cannot tell whether it's
// a recovery bundle, a config blob, or noise.
//
// No signer key material leaves this bundle. Signing goes through
// window.nostr per NIP-07, same as every other lib module in this repo.

import { signEvent } from "./nostr-event.mjs";
import { publishToRelays, DEFAULT_RELAYS } from "./nostr-relay.mjs";

/**
 * Publish a NIP-33 replaceable event carrying an opaque encrypted blob.
 *
 * The `dTag` uniquely addresses this event within the user's key. For
 * the recovery bundle we use `torii-recovery-v1`; re-running onboarding
 * or rotating credentials on the same npub replaces the old copy.
 *
 * The `topic` tag is a human-readable label. Nostr clients that browse
 * kind:30078 by topic (rare, but they exist) can filter on it.
 *
 * @param {object}   opts
 * @param {string}   opts.dTag           NIP-33 identifier
 * @param {string}   opts.topic          human-readable label
 * @param {string}   opts.content        opaque payload (e.g. torii-ncrypt1… envelope)
 * @param {string[]} [opts.relays]       target relays; defaults to DEFAULT_RELAYS
 * @param {number}   [opts.timeoutMs]    per-relay publish timeout
 * @param {(r:object)=>void} [opts.onRelayResult]
 * @param {object}   [opts.signer]       override for tests / mock
 * @returns {Promise<{eventId: string, okCount: number, results: Array}>}
 */
export async function publishAppData(opts) {
  if (!opts || typeof opts.dTag !== "string" || !opts.dTag) {
    throw new Error("publishAppData: dTag is required");
  }
  if (typeof opts.content !== "string") {
    throw new Error("publishAppData: content must be a string");
  }

  const tags = [["d", opts.dTag]];
  if (opts.topic) tags.push(["topic", String(opts.topic)]);

  const signed = await signEvent(
    { kind: 30078, tags, content: opts.content },
    { signer: opts.signer },
  );

  const publishResult = await publishToRelays(signed, {
    relays: opts.relays || DEFAULT_RELAYS,
    timeoutMs: opts.timeoutMs,
    onResult: opts.onRelayResult,
  });

  return {
    eventId: publishResult.eventId,
    okCount: publishResult.okCount,
    results: publishResult.results,
  };
}

/**
 * The stable d-tag used by torii for the optional encrypted recovery
 * bundle. Exported as a constant so screen code, tests, and any future
 * "restore from relays" flow all agree on the addressing scheme.
 */
export const TORII_RECOVERY_D_TAG = "torii-recovery-v1";

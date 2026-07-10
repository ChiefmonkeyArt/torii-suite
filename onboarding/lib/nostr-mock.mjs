// nostr-mock.mjs — fake nostr signer + relay for ?mock=1 dev.
//
// v0.1.6-alpha (torii-suite/onboarding)
//
// ─── Changes from v0.1.5 ───────────────────────────────────────────────
//
// The default mock pubkey is now a VALID secp256k1 x-only point (the
// well-known secp256k1 generator G, x = 79be667e...). v0.1.5's default
// was `1234...cdef`, which is fine as an opaque identifier but is not
// a valid on-curve x-coordinate. v0.1.6's gift-wrap flow performs real
// ECDH against the recipient pubkey (see lib/nostr-giftwrap.mjs), which
// requires the pubkey to be a lift-able point on the curve. Using G
// keeps the mock trivially deterministic while allowing the real crypto
// pipeline to run end-to-end in ?mock=1.
//
// Two independent shims that share the same activation flag:
//
//   1. window.nostr    — a NIP-07 signer that returns deterministic
//      pubkey/sig data and pretends to know NIP-44 encryption. It does
//      NOT perform real encryption — it just wraps the plaintext with
//      a marker prefix so a mock relay round-trip stays readable in
//      the browser devtools.
//
//   2. window.__nostrRelayMock — a matching hook for nostr-relay.mjs
//      and nostr-relaylist.mjs. Simulates:
//        - publishToRelays()      → per-relay ACKs (one deliberately fails)
//        - fetchInboxRelayList()  → returns null so callers fall back to defaults
//
// Activation: any of ?mock=1, ?mock=nostr, or window.__forceNostrMock.

/**
 * Deterministic fake signer. Note we do NOT pre-install a fake
 * window.nostr if the browser already has a real one — the click-
 * through tests inject their own via addInitScript before load,
 * which we should preserve.
 *
 * @param {object} [opts]
 * @param {string} [opts.pubkey] override the returned pubkey
 */
export function installNostrSignerMock(opts = {}) {
  if (typeof window === "undefined") return;
  // Respect any signer already installed by tests or by a real extension.
  // Only patch in the missing methods (nip44 / nip04) if they're absent.
  const existing = window.nostr || {};
  // Default to a deterministic 64-hex pubkey so the mock is usable without
  // any config — the ?mock=1 dev path needs `getPublicKey()` to succeed.
  // secp256k1 generator G, x-only. Deterministic, valid on-curve point,
  // safe as a mock recipient for the real ECDH inside gift-wrap.
  const DEFAULT_MOCK_PUBKEY = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";
  const pubkey = opts.pubkey || existing.__mockPubkey || DEFAULT_MOCK_PUBKEY;

  const withDefaults = {
    ...existing,
    async getPublicKey() {
      if (typeof existing.getPublicKey === "function") return existing.getPublicKey();
      if (!pubkey) throw new Error("nostr-mock: no pubkey configured");
      return pubkey;
    },
    async signEvent(evt) {
      if (typeof existing.signEvent === "function") return existing.signEvent(evt);
      const pk = pubkey || (await this.getPublicKey());
      // Deterministic all-hex id and sig so assertSignedEvent() accepts
      // them. The full 64-hex id is derived from the event body + pubkey;
      // the 128-hex sig is two chained fakeHash calls concatenated.
      const id  = fakeHash(JSON.stringify(evt) + pk);
      const sig = fakeHash("sig:" + id) + fakeHash("sig2:" + id);
      return { ...evt, pubkey: pk, id, sig };
    },
  };

  if (!withDefaults.nip44) {
    withDefaults.nip44 = {
      async encrypt(_recipientPubkey, plaintext) {
        // The marker prefix makes it easy to spot in devtools that this
        // is NOT a real ciphertext. If a real relay ever saw this it
        // would reject as malformed — but the mock relay accepts it.
        return "mock-nip44:" + btoa(unescape(encodeURIComponent(plaintext)));
      },
      async decrypt(_recipientPubkey, ciphertext) {
        if (!ciphertext.startsWith("mock-nip44:")) {
          throw new Error("mock-nip44: not a mock ciphertext");
        }
        return decodeURIComponent(escape(atob(ciphertext.slice("mock-nip44:".length))));
      },
    };
  }

  window.nostr = withDefaults;
}

/**
 * Install the relay mock. Provides fakes for both publishToRelays() and
 * fetchInboxRelayList() so v0.1.5's kind-10050 discovery step works in
 * ?mock=1 without opening any real WebSockets.
 */
export function installRelayMock() {
  if (typeof window === "undefined") return;
  window.__nostrRelayMock = {
    async publishToRelays(event, opts = {}) {
      const relays = opts.relays || [];
      // Simulate one flaky relay for realistic UX — always the same
      // index so tests are deterministic.
      const flakyIndex = relays.length > 2 ? 2 : -1;
      const results = [];
      for (let i = 0; i < relays.length; i++) {
        // Stagger onResult callbacks so the UI can render "connecting…"
        // then per-relay results as they arrive.
        await new Promise((r) => setTimeout(r, 80 + i * 40));
        const ok = i !== flakyIndex;
        const res = {
          relay: relays[i],
          ok,
          message: ok ? "accepted" : "closed_without_ok (code=1006)",
          latencyMs: 120 + i * 55,
        };
        results.push(res);
        try { opts.onResult?.(res); } catch { /* swallow */ }
      }
      return {
        eventId: event.id,
        results,
        okCount: results.reduce((n, r) => n + (r.ok ? 1 : 0), 0),
      };
    },
    // Onboarding is a brand-new npub in mock mode, so it hasn't declared
    // a DM inbox yet. Returning null makes the caller (screen 8 flow)
    // fall back to DEFAULT_RELAYS — which is what a fresh real user
    // would experience on their first run anyway.
    async fetchInboxRelayList(_opts) {
      await new Promise((r) => setTimeout(r, 200));
      return null;
    },
  };
}

/**
 * True when the app should run against fake signer + relays.
 * Kept separate from the SHC/WebSSH mock flag on purpose — a caller
 * could plausibly want real relays with mock SHC (or vice versa).
 */
export function isNostrMockMode() {
  if (typeof window === "undefined") return false;
  if (window.__forceNostrMock) return true;
  const q = new URLSearchParams(window.location.search);
  const v = q.get("mock");
  return v === "1" || v === "nostr" || v === "all";
}

/**
 * Fast non-cryptographic hash. Just for producing readable-but-unique
 * fake event ids. Do NOT use for anything security-adjacent.
 * @param {string} s
 * @returns {string} 64-char hex
 */
function fakeHash(s) {
  // xmur3 seeded from string — deterministic PRNG-friendly.
  let h = 2166136261 >>> 0;
  for (let i = 0; i < s.length; i++) {
    h = Math.imul(h ^ s.charCodeAt(i), 16777619) >>> 0;
  }
  // Expand to 64 hex chars by iterating a second hash on the state.
  let out = "";
  let x = h;
  for (let i = 0; i < 16; i++) {
    x = Math.imul(x ^ (x >>> 16), 2246822507) >>> 0;
    x = Math.imul(x ^ (x >>> 13), 3266489909) >>> 0;
    x = (x ^ (x >>> 16)) >>> 0;
    out += x.toString(16).padStart(8, "0");
  }
  return out.slice(0, 64);
}

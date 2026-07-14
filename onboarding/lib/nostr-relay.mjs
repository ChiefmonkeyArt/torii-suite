// nostr-relay.mjs — minimal NIP-01 relay client for one-shot publishing.
//
// v0.1.4-alpha (torii-suite/onboarding)
//
// This is deliberately not a general-purpose relay pool. Onboarding only
// needs to publish one event to N relays and report per-relay success —
// no subscriptions, no reconnect, no auth (NIP-42).
//
// We fan out publishes in parallel with a per-relay timeout so a single
// slow or dead relay can't block the "your torii is live" transition.
// Delivery is "best effort, best of N": as long as any relay ACKs, the
// DM has landed somewhere the user's signer can retrieve it from.

const enc = new TextEncoder();

/**
 * Default relay list. Chosen for:
 *   - broad NIP-17 gift-wrap support
 *   - free-to-write (no paid-only rejection at accept time)
 *   - geographic + operator diversity so torii doesn't concentrate
 *     onboarding traffic on any one operator
 *
 * The user's own DM relays (kind 10050) would be more correct per NIP-17,
 * but we can't read those without a subscribe cycle. Instead we accept
 * an override in publishToRelays() so a caller who has read 10050 out
 * of band can pass it in. (Not for v0.1.4 — deferred.)
 */
export const DEFAULT_RELAYS = Object.freeze([
  "wss://relay.damus.io",
  "wss://relay.primal.net",
  "wss://nos.lol",
  "wss://relay.nostr.band",
  "wss://nostr.wine",
]);

/**
 * Publish a signed event to one relay. Returns a per-relay result.
 *
 * @param {string} url   ws:// or wss:// relay URL
 * @param {object} event signed nostr event
 * @param {object} [opts]
 * @param {number} [opts.timeoutMs=8000] hard cap per relay
 * @returns {Promise<{relay: string, ok: boolean, message: string, latencyMs: number}>}
 */
export function publishToRelay(url, event, opts = {}) {
  const timeoutMs = opts.timeoutMs ?? 8000;
  const started = performance.now();

  return new Promise((resolve) => {
    let settled = false;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      try { ws.close(); } catch { /* already closed */ }
      clearTimeout(timer);
      resolve({ ...result, relay: url, latencyMs: Math.round(performance.now() - started) });
    };

    let ws;
    try {
      ws = new WebSocket(url);
    } catch (err) {
      resolve({ relay: url, ok: false, message: `open_failed: ${err.message}`, latencyMs: 0 });
      return;
    }

    const timer = setTimeout(() => {
      finish({ ok: false, message: "timeout" });
    }, timeoutMs);

    ws.addEventListener("open", () => {
      try {
        ws.send(JSON.stringify(["EVENT", event]));
      } catch (err) {
        finish({ ok: false, message: `send_failed: ${err.message}` });
      }
    });

    ws.addEventListener("message", (msg) => {
      let payload;
      try {
        payload = JSON.parse(typeof msg.data === "string" ? msg.data : "");
      } catch {
        return; // ignore non-JSON frames
      }
      if (!Array.isArray(payload)) return;
      // Relays send ["OK", <id>, <ok>, <message>] per NIP-20.
      if (payload[0] === "OK" && payload[1] === event.id) {
        const ok = payload[2] === true;
        const message = String(payload[3] ?? "");
        finish({ ok, message: ok ? (message || "accepted") : (message || "rejected") });
      }
      // Some relays send ["NOTICE", <msg>] before/instead of OK — treat as info only.
    });

    ws.addEventListener("error", () => {
      finish({ ok: false, message: "socket_error" });
    });

    ws.addEventListener("close", (ev) => {
      // If the socket closed without an OK, treat it as failure. Some
      // relays close silently on rate-limit or auth requirements.
      finish({ ok: false, message: `closed_without_ok (code=${ev.code || 0})` });
    });
  });
}

/**
 * Publish an event to many relays in parallel. Waits for every relay
 * to settle (each capped by its own timeout, so this call cannot hang
 * longer than `timeoutMs`).
 *
 * `onResult` fires as each relay settles so the caller can update UI
 * in real time; the returned object contains the complete result set
 * for the final render.
 *
 * @param {object} event    signed nostr event
 * @param {object} [opts]
 * @param {string[]} [opts.relays=DEFAULT_RELAYS]
 * @param {number}   [opts.timeoutMs=8000] per-relay timeout
 * @param {(r: object) => void} [opts.onResult] called for each relay as it settles
 * @returns {Promise<{eventId: string, results: Array, okCount: number}>}
 */
export async function publishToRelays(event, opts = {}) {
  const relays = opts.relays && opts.relays.length ? opts.relays : DEFAULT_RELAYS;

  // Mock hook — matches the transparent pattern used by shc-client and
  // webssh-client. When installed, screen code doesn't branch.
  if (typeof window !== "undefined" && window.__nostrRelayMock?.publishToRelays) {
    return window.__nostrRelayMock.publishToRelays(event, { ...opts, relays });
  }

  const settled = await Promise.all(
    relays.map((url) =>
      publishToRelay(url, event, { timeoutMs: opts.timeoutMs }).then((res) => {
        try { opts.onResult?.(res); } catch { /* caller bug shouldn't kill publish */ }
        return res;
      })
    )
  );

  const okCount = settled.reduce((n, r) => n + (r.ok ? 1 : 0), 0);
  return { eventId: event.id, results: settled, okCount };
}

// enc is reserved for future NIP-42 auth support; keep the import warm so
// removing it later shows up in code review.
void enc;

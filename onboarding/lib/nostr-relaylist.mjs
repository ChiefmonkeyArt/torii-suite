// nostr-relaylist.mjs — NIP-17 DM inbox relay list (kind 10050).
//
// v0.1.5-alpha (torii-suite/onboarding)
//
// NIP-17 §Publishing says clients SHOULD only publish gift-wrapped DMs
// to the relays listed in the recipient's kind-10050 event. Ignoring
// that turns a "targeted DM" into a broadcast to every relay the sender
// picked, which is bad both for metadata privacy and for the recipient's
// ability to actually find their DMs later.
//
// This module does two things:
//
//   1. publishInboxRelayList — publishes a kind-10050 event on behalf of
//      the user, declaring which relays their nostr clients should look
//      at for gift-wrapped DMs. We call this at the end of onboarding so
//      the user has a working DM inbox declared before the recovery hint
//      is sent.
//
//   2. fetchInboxRelayList — reads the current kind-10050 for a given
//      pubkey by opening a REQ subscription against a set of discovery
//      relays. Returns the parsed relay list, or null if none exists.
//
// Fetching is best-effort. If no discovery relay coughs up a 10050 in a
// couple of seconds, we assume the user has none published and fall back
// to the default relays. This is safe because kind-10050 is public info —
// the worst case is we route the recovery hint to well-known relays that
// the user might not read.
//
// Zero third-party deps. Uses raw WebSocket, matching nostr-relay.mjs.

import { signEvent } from "./nostr-event.mjs";
import { publishToRelays, DEFAULT_RELAYS } from "./nostr-relay.mjs";

/**
 * Publish a kind-10050 DM inbox relay list. The event content is empty;
 * the relay URLs live in `relay` tags per NIP-17.
 *
 * @param {object}   opts
 * @param {string[]} opts.relaysForInbox    URLs the user reads DMs from
 * @param {string[]} [opts.publishTo=DEFAULT_RELAYS] where to broadcast the 10050 itself
 * @param {number}   [opts.timeoutMs]
 * @param {(r:object)=>void} [opts.onRelayResult]
 * @param {object}   [opts.signer]
 * @returns {Promise<{eventId: string, okCount: number, results: Array}>}
 */
export async function publishInboxRelayList(opts) {
  const inbox = Array.isArray(opts?.relaysForInbox) ? opts.relaysForInbox : [];
  if (inbox.length === 0) {
    throw new Error("publishInboxRelayList: at least one relay URL required");
  }
  for (const url of inbox) {
    if (!/^wss?:\/\/.+/.test(url)) {
      throw new Error(`publishInboxRelayList: bad relay URL ${url}`);
    }
  }

  const tags = inbox.map((url) => ["relay", url]);
  const signed = await signEvent(
    { kind: 10050, tags, content: "" },
    { signer: opts.signer },
  );

  return publishToRelays(signed, {
    relays: opts.publishTo || DEFAULT_RELAYS,
    timeoutMs: opts.timeoutMs,
    onResult: opts.onRelayResult,
  });
}

/**
 * Fetch the latest kind-10050 event for `pubkey` from a set of discovery
 * relays. Returns the list of relay URLs the user has declared, or null
 * if no event was found within `timeoutMs`.
 *
 * @param {object}   opts
 * @param {string}   opts.pubkey                hex pubkey (64-hex)
 * @param {string[]} [opts.discoveryRelays=DEFAULT_RELAYS]
 * @param {number}   [opts.timeoutMs=3500]      total wall-clock budget
 * @returns {Promise<string[]|null>}
 */
export async function fetchInboxRelayList(opts) {
  if (!opts?.pubkey || !/^[0-9a-f]{64}$/i.test(opts.pubkey)) {
    throw new Error("fetchInboxRelayList: pubkey must be a 64-hex string");
  }

  // Mock hook — same pattern as publishToRelays.
  if (typeof window !== "undefined" && window.__nostrRelayMock?.fetchInboxRelayList) {
    return window.__nostrRelayMock.fetchInboxRelayList(opts);
  }

  const discoveryRelays = opts.discoveryRelays && opts.discoveryRelays.length
    ? opts.discoveryRelays
    : DEFAULT_RELAYS;
  const timeoutMs = opts.timeoutMs ?? 3500;

  // Fan out a REQ to each discovery relay in parallel; take the newest
  // (highest created_at) kind-10050 event we see across all of them.
  // First responder does not win — we want the most recent, not the fastest.
  const perRelay = discoveryRelays.map((url) => fetchOneRelay10050(url, opts.pubkey, timeoutMs));
  const settled = await Promise.all(perRelay);

  let best = null;
  for (const evt of settled) {
    if (!evt) continue;
    if (!best || evt.created_at > best.created_at) best = evt;
  }
  if (!best) return null;

  const relays = [];
  for (const tag of Array.isArray(best.tags) ? best.tags : []) {
    if (Array.isArray(tag) && tag[0] === "relay" && typeof tag[1] === "string") {
      relays.push(tag[1]);
    }
  }
  return relays.length > 0 ? relays : null;
}

/**
 * Open a WS to `url`, REQ the latest kind-10050 for `pubkey`, and return
 * that event (or null on timeout / no result). Closes the socket cleanly
 * on any outcome.
 *
 * @param {string} url
 * @param {string} pubkeyHex
 * @param {number} timeoutMs
 * @returns {Promise<object|null>}
 */
function fetchOneRelay10050(url, pubkeyHex, timeoutMs) {
  return new Promise((resolve) => {
    let settled = false;
    let ws;
    let latestEvent = null;
    const subId = "rl-" + Math.random().toString(36).slice(2, 10);

    const finish = (result) => {
      if (settled) return;
      settled = true;
      try { ws?.send(JSON.stringify(["CLOSE", subId])); } catch { /* already closed */ }
      try { ws?.close(); } catch { /* already closed */ }
      clearTimeout(timer);
      resolve(result);
    };

    try {
      ws = new WebSocket(url);
    } catch {
      resolve(null);
      return;
    }

    const timer = setTimeout(() => finish(latestEvent), timeoutMs);

    ws.addEventListener("open", () => {
      try {
        ws.send(JSON.stringify([
          "REQ",
          subId,
          { authors: [pubkeyHex], kinds: [10050], limit: 1 },
        ]));
      } catch {
        finish(null);
      }
    });

    ws.addEventListener("message", (msg) => {
      let frame;
      try {
        frame = JSON.parse(typeof msg.data === "string" ? msg.data : "");
      } catch { return; }
      if (!Array.isArray(frame)) return;
      // ["EVENT", subId, event] — record the newest we've seen so far.
      if (frame[0] === "EVENT" && frame[1] === subId && frame[2]) {
        const evt = frame[2];
        if (evt.kind === 10050 && evt.pubkey === pubkeyHex) {
          if (!latestEvent || evt.created_at > latestEvent.created_at) {
            latestEvent = evt;
          }
        }
      }
      // ["EOSE", subId] — end of stored events. Whatever we have is final.
      if (frame[0] === "EOSE" && frame[1] === subId) {
        finish(latestEvent);
      }
      // ["CLOSED", subId, reason] — relay refused the sub.
      if (frame[0] === "CLOSED" && frame[1] === subId) {
        finish(latestEvent);
      }
    });

    ws.addEventListener("error", () => finish(latestEvent));
    ws.addEventListener("close", () => finish(latestEvent));
  });
}

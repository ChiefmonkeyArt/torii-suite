// onboarding/lib/webssh-client.mjs
// Browser-side counterpart to bridges/webssh/index.mjs.
//
// The bridge accepts a WebSocket on /webssh and speaks the JSON protocol
// documented in the bridge header. This module wraps that protocol behind a
// small event-emitting object so screen 7 (building) can just:
//
//   const ssh = openWebSsh({
//     url: "wss://<vps-host>/webssh",
//     host: vmIp,
//     username: osUser,
//     privateKey: keys.privateKey,
//     command: `bash <(curl -fsSL ${bootstrapUrl})`,
//     onOutput: (kind, textChunk) => appendLog(kind, textChunk),
//     onReady:  () => setStatus("bootstrapping"),
//     onExit:   (code) => setStatus(code === 0 ? "done" : "failed"),
//     onError:  (msg) => setStatus("failed", msg),
//   });
//
//   // Later: ssh.close()  or  ssh.write("q\n")
//
// Design notes:
//   • Output chunks arrive as base64 (protocol-level). We decode to a UTF-8
//     string and pass to onOutput. Consumers that want raw bytes can call
//     openWebSsh({ decodeUtf8: false, onOutput: (kind, bytes) => ... }).
//   • stdin is symmetrically base64-encoded, so `ssh.write("q\n")` just
//     works — the module encodes for you.
//   • Reconnect logic: none. WebSSH sessions are single-shot, deliberately
//     ephemeral, and tied to a fresh keypair we throw away when the tab
//     closes. If the WS drops mid-bootstrap the UI should treat it as a
//     failure and offer to retry from a new keypair.
//   • Mock mode: `window.__websshMock` (installed by shc-mock.mjs when
//     `?mock=1` is on the URL) is used instead of a real WebSocket. It
//     receives the same handshake and calls the same callbacks — the caller
//     never sees the difference.

const ENCODER = new TextEncoder();
const DECODER = new TextDecoder("utf-8", { fatal: false });

function b64encode(bytesOrString) {
  const bytes = typeof bytesOrString === "string"
    ? ENCODER.encode(bytesOrString)
    : bytesOrString;
  // btoa cannot handle >255 code points, so feed it a binary-safe string.
  let bin = "";
  for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
  return btoa(bin);
}

function b64decode(str) {
  const bin = atob(str);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

/**
 * Open a WebSSH session.
 *
 * @param {object} opts
 * @param {string} opts.url          wss:// or ws:// endpoint
 * @param {string} opts.host         target VPS host/IP (goes into `connect`)
 * @param {number} [opts.port=22]
 * @param {string} opts.username
 * @param {string} opts.privateKey   OpenSSH PEM
 * @param {string} opts.command      allowlisted bootstrap command
 * @param {function} [opts.onOutput] (kind: "stdout"|"stderr", data: string|Uint8Array)
 * @param {function} [opts.onReady]  () — SSH channel open, before first byte
 * @param {function} [opts.onExit]   (code: number)
 * @param {function} [opts.onError]  (message: string)
 * @param {function} [opts.onClose]  (event) — WS closed, always fires last
 * @param {boolean}  [opts.decodeUtf8=true]
 * @returns {{ write:(data:string|Uint8Array)=>void, resize:(cols:number,rows:number)=>void, close:()=>void, readyState:()=>string }}
 */
export function openWebSsh(opts) {
  // Mock shim.
  if (typeof window !== "undefined" && window.__websshMock) {
    return window.__websshMock.open(opts);
  }

  const {
    url,
    host,
    port,
    username,
    privateKey,
    command,
    onOutput,
    onReady,
    onExit,
    onError,
    onClose,
    decodeUtf8 = true,
  } = opts;

  if (!url || !host || !username || !privateKey || !command) {
    throw new Error("openWebSsh: url, host, username, privateKey, command are all required");
  }

  const ws = new WebSocket(url);
  let handshakeSent = false;
  let closed = false;

  function emitError(msg) {
    try { onError?.(msg); } catch { /* UI callback errors must not break the socket */ }
  }

  ws.addEventListener("open", () => {
    if (closed) return;
    try {
      ws.send(JSON.stringify({
        type: "connect",
        host,
        ...(port ? { port } : {}),
        username,
        privateKey,
        command,
      }));
      handshakeSent = true;
    } catch (e) {
      emitError(`failed to send connect handshake: ${e.message}`);
      try { ws.close(); } catch { /* ignore */ }
    }
  });

  ws.addEventListener("message", (ev) => {
    if (closed) return;
    let msg;
    try {
      msg = JSON.parse(typeof ev.data === "string" ? ev.data : String(ev.data));
    } catch {
      emitError("bridge sent non-JSON message");
      return;
    }

    switch (msg.type) {
      case "ready":
        try { onReady?.(); } catch { /* ignore UI errors */ }
        break;

      case "stdout":
      case "stderr": {
        if (typeof msg.data !== "string") return;
        const bytes = b64decode(msg.data);
        const payload = decodeUtf8 ? DECODER.decode(bytes) : bytes;
        try { onOutput?.(msg.type, payload); } catch { /* ignore */ }
        break;
      }

      case "exit":
        try { onExit?.(typeof msg.code === "number" ? msg.code : 0); } catch { /* ignore */ }
        // Bridge will close the WS after `exit`; let onclose fire naturally.
        break;

      case "error":
        emitError(typeof msg.message === "string" ? msg.message : "bridge error");
        break;

      default:
        // Unknown message type — ignore forward-compatibly.
        break;
    }
  });

  ws.addEventListener("error", () => {
    if (closed) return;
    // The WebSocket error event carries no useful detail in browsers. The
    // subsequent close event (with code/reason) is what matters.
    emitError("websocket error");
  });

  ws.addEventListener("close", (ev) => {
    if (closed) return;
    closed = true;
    if (!handshakeSent) {
      emitError(`websocket closed before handshake (code=${ev.code})`);
    }
    try { onClose?.(ev); } catch { /* ignore */ }
  });

  return {
    /** Send stdin. Accepts a string (encoded UTF-8) or a Uint8Array. */
    write(data) {
      if (closed || ws.readyState !== WebSocket.OPEN) return;
      try {
        ws.send(JSON.stringify({ type: "stdin", data: b64encode(data) }));
      } catch { /* swallow — caller sees no send happen */ }
    },

    /** Resize the remote PTY. */
    resize(cols, rows) {
      if (closed || ws.readyState !== WebSocket.OPEN) return;
      if (!Number.isInteger(cols) || !Number.isInteger(rows)) return;
      if (cols <= 0 || rows <= 0) return;
      try {
        ws.send(JSON.stringify({ type: "resize", cols, rows }));
      } catch { /* ignore */ }
    },

    /** Politely close the session. */
    close() {
      if (closed) return;
      try {
        if (ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify({ type: "close" }));
        }
      } catch { /* ignore */ }
      try { ws.close(1000, "client-close"); } catch { /* ignore */ }
    },

    /** Introspection helper for the UI. */
    readyState() {
      const map = { 0: "connecting", 1: "open", 2: "closing", 3: "closed" };
      return map[ws.readyState] ?? "unknown";
    },
  };
}

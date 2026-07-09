// torii-suite/bridges/webssh/index.mjs
//
// SSH-over-WebSocket bridge. The browser opens a WebSocket, sends a small
// JSON handshake carrying an ephemeral SSH keypair and the target VPS
// address, and the bridge opens an SSH session to that target using the
// keypair. The browser then receives stdout/stderr in real time and can
// send stdin. When the WebSocket closes (tab shut, session over) the SSH
// connection dies with it.
//
// This is the tool that lets the onboarding SPA run `bootstrap.sh` on a
// freshly-provisioned VPS without the user ever touching a terminal.
//
// The bridge holds no long-lived state, writes nothing to disk, and logs
// no session content.
//
// Configuration is env-only:
//   WEBSSH_PORT             listen port (default 8802)
//   WEBSSH_ORIGIN_ALLOW     comma-separated browser Origin allowlist
//                           (default: empty — refuses to start)
//   WEBSSH_MAX_SESSION_MS   hard session timeout (default 900000 = 15 min)
//   WEBSSH_MAX_PER_IP       concurrent sessions per client IP (default 3)
//   WEBSSH_CMD_ALLOW_REGEX  regex the requested command must match
//                           (default: only bootstrap-shaped commands)
//   WEBSSH_LOG_LEVEL        silent|info (default silent)
//
// Wire protocol (both directions are JSON messages on the WebSocket):
//
//   client -> bridge (first message, exactly once):
//     {
//       "type": "connect",
//       "host": "1.2.3.4",       // target VPS
//       "port": 22,              // optional, default 22
//       "username": "root",      // typically root during provisioning
//       "privateKey": "-----BEGIN OPENSSH PRIVATE KEY-----\n…",
//       "command": "bash <(curl -fsSL https://example.com/bootstrap.sh)"
//     }
//
//   bridge -> client:
//     { "type": "ready" }                       // SSH channel open
//     { "type": "stdout", "data": "..." }       // base64-encoded
//     { "type": "stderr", "data": "..." }       // base64-encoded
//     { "type": "exit",   "code": 0 }
//     { "type": "error",  "message": "..." }
//
//   client -> bridge (after connect, optional):
//     { "type": "stdin", "data": "..." }        // base64-encoded
//     { "type": "resize", "cols": 80, "rows": 24 }
//     { "type": "close" }

import http from "node:http";
import { WebSocketServer } from "ws";
import { Client as SSHClient } from "ssh2";

// --------------------------------------------------------------------------- //
// Config                                                                      //
// --------------------------------------------------------------------------- //

const PORT = Number.parseInt(process.env.WEBSSH_PORT ?? "8802", 10);
const ORIGIN_ALLOW = new Set(
  (process.env.WEBSSH_ORIGIN_ALLOW ?? "")
    .split(",")
    .map((o) => o.trim())
    .filter(Boolean),
);
const MAX_SESSION_MS = Number.parseInt(
  process.env.WEBSSH_MAX_SESSION_MS ?? "900000",
  10,
);
const MAX_PER_IP = Number.parseInt(process.env.WEBSSH_MAX_PER_IP ?? "3", 10);
const CMD_ALLOW_REGEX = new RegExp(
  // Default: allow only bootstrap-shaped commands. The onboarding SPA
  // exclusively fires a curl-to-bash of the torii-suite bootstrap. Anything
  // else — including "run any bash command" — needs an operator opt-in.
  //
  //   bash <(curl -fsSL https://…/bootstrap.sh) [env=val ...]
  //   sudo -E bash …/bootstrap.sh
  //   curl -fsSL https://…/bootstrap.sh | sudo -E bash
  //
  // Any semicolons, backticks, or piped-to-anything-but-bash are rejected.
  process.env.WEBSSH_CMD_ALLOW_REGEX ??
    "^(?:sudo -E )?(?:bash <\\(curl -fsSL https://[A-Za-z0-9._~:/?#\\[\\]@!$&'()*+,;=%-]+\\)|curl -fsSL https://[A-Za-z0-9._~:/?#\\[\\]@!$&'()*+,;=%-]+ \\| (?:sudo -E )?bash)(?: [A-Za-z_][A-Za-z0-9_]*=[A-Za-z0-9._@:/+-]+)*$",
);
const LOG_LEVEL = process.env.WEBSSH_LOG_LEVEL ?? "silent";

const log = (msg) => {
  if (LOG_LEVEL === "info") process.stdout.write(`${msg}\n`);
};

if (ORIGIN_ALLOW.size === 0) {
  process.stderr.write("webssh: WEBSSH_ORIGIN_ALLOW is empty; refusing to start\n");
  process.exit(2);
}

// --------------------------------------------------------------------------- //
// Per-IP concurrency limiter                                                  //
// --------------------------------------------------------------------------- //

const activePerIp = new Map(); // ip -> count

function acquireSlot(ip) {
  const n = activePerIp.get(ip) ?? 0;
  if (n >= MAX_PER_IP) return false;
  activePerIp.set(ip, n + 1);
  return true;
}
function releaseSlot(ip) {
  const n = activePerIp.get(ip) ?? 0;
  if (n <= 1) activePerIp.delete(ip);
  else activePerIp.set(ip, n - 1);
}

// --------------------------------------------------------------------------- //
// HTTP: health + websocket upgrade                                            //
// --------------------------------------------------------------------------- //

const httpServer = http.createServer((req, res) => {
  if (req.method === "GET" && req.url === "/_health") {
    res.setHeader("Content-Type", "application/json; charset=utf-8");
    res.statusCode = 200;
    res.end(JSON.stringify({ ok: true, service: "torii-webssh" }));
    return;
  }
  res.statusCode = 404;
  res.end("not found\n");
});

const wss = new WebSocketServer({ noServer: true });

httpServer.on("upgrade", (req, socket, head) => {
  if (req.url !== "/webssh") {
    socket.write("HTTP/1.1 404 Not Found\r\n\r\n");
    socket.destroy();
    return;
  }
  const origin = req.headers.origin;
  if (!origin || !ORIGIN_ALLOW.has(origin)) {
    socket.write("HTTP/1.1 403 Forbidden\r\n\r\n");
    socket.destroy();
    return;
  }
  wss.handleUpgrade(req, socket, head, (ws) => {
    wss.emit("connection", ws, req);
  });
});

// --------------------------------------------------------------------------- //
// Per-connection state machine                                                //
// --------------------------------------------------------------------------- //

wss.on("connection", (ws, req) => {
  const clientIp =
    req.socket.remoteAddress ??
    (req.headers["x-forwarded-for"]?.toString().split(",")[0].trim() || "unknown");

  if (!acquireSlot(clientIp)) {
    sendJson(ws, { type: "error", message: "too many concurrent sessions from your IP" });
    ws.close(1013, "rate-limited");
    return;
  }

  let sshClient = null;
  let sshStream = null;
  let handshakeDone = false;
  let cleanupCalled = false;

  const sessionTimer = setTimeout(() => {
    sendJson(ws, { type: "error", message: "session exceeded max duration" });
    cleanup(4000, "session-timeout");
  }, MAX_SESSION_MS);

  function cleanup(closeCode, closeReason) {
    if (cleanupCalled) return;
    cleanupCalled = true;
    clearTimeout(sessionTimer);
    releaseSlot(clientIp);
    try { sshStream?.destroy(); } catch { /* ignore */ }
    try { sshClient?.end(); } catch { /* ignore */ }
    try {
      if (ws.readyState === ws.OPEN || ws.readyState === ws.CONNECTING) {
        ws.close(closeCode, closeReason);
      }
    } catch { /* ignore */ }
  }

  ws.on("close", () => cleanup(1000, "ws-closed"));
  ws.on("error", () => cleanup(1011, "ws-error"));

  ws.on("message", (raw) => {
    let msg;
    try {
      msg = JSON.parse(raw.toString("utf8"));
    } catch {
      sendJson(ws, { type: "error", message: "invalid JSON message" });
      return cleanup(1003, "bad-json");
    }

    if (!handshakeDone) {
      if (msg.type !== "connect") {
        sendJson(ws, { type: "error", message: "first message must be 'connect'" });
        return cleanup(1002, "bad-handshake");
      }
      const err = validateConnect(msg);
      if (err) {
        sendJson(ws, { type: "error", message: err });
        return cleanup(1002, "bad-handshake");
      }
      handshakeDone = true;
      openSsh(msg);
      return;
    }

    // Post-handshake messages.
    switch (msg.type) {
      case "stdin":
        if (typeof msg.data !== "string") return;
        try { sshStream?.write(Buffer.from(msg.data, "base64")); } catch { /* ignore */ }
        break;
      case "resize":
        if (
          Number.isInteger(msg.cols) &&
          Number.isInteger(msg.rows) &&
          msg.cols > 0 &&
          msg.rows > 0
        ) {
          try { sshStream?.setWindow(msg.rows, msg.cols, 0, 0); } catch { /* ignore */ }
        }
        break;
      case "close":
        cleanup(1000, "client-close");
        break;
      default:
        // Unknown types are silently ignored — no need to hang up on a
        // future-forward client.
        break;
    }
  });

  // ------------------------------------------------------------------------- //
  // Open the SSH connection                                                   //
  // ------------------------------------------------------------------------- //

  function openSsh(handshake) {
    log(`webssh: opening session ${clientIp} -> ${handshake.host}`);
    sshClient = new SSHClient();

    sshClient.on("ready", () => {
      sendJson(ws, { type: "ready" });
      sshClient.exec(
        handshake.command,
        { pty: { cols: 80, rows: 24, term: "xterm-256color" } },
        (err, stream) => {
          if (err) {
            sendJson(ws, { type: "error", message: `exec failed: ${err.message}` });
            return cleanup(1011, "exec-failed");
          }
          sshStream = stream;

          stream.on("data", (chunk) => {
            sendJson(ws, { type: "stdout", data: chunk.toString("base64") });
          });
          stream.stderr.on("data", (chunk) => {
            sendJson(ws, { type: "stderr", data: chunk.toString("base64") });
          });
          stream.on("close", (code) => {
            sendJson(ws, { type: "exit", code: code ?? 0 });
            cleanup(1000, "cmd-exit");
          });
        },
      );
    });

    sshClient.on("error", (err) => {
      sendJson(ws, { type: "error", message: `ssh error: ${err.message}` });
      cleanup(1011, "ssh-error");
    });

    // Do NOT log the private key content or the SSH banner — they're
    // sensitive by construction. Wrap connect() in try/catch because
    // ssh2 throws synchronously on a malformed private key.
    try {
      sshClient.connect({
        host: handshake.host,
        port: handshake.port ?? 22,
        username: handshake.username,
        privateKey: handshake.privateKey,
        readyTimeout: 20_000,
        // Reject weak algorithms.
        algorithms: {
          kex: ["curve25519-sha256", "curve25519-sha256@libssh.org"],
          cipher: ["aes256-gcm@openssh.com", "chacha20-poly1305@openssh.com"],
          serverHostKey: ["ssh-ed25519", "rsa-sha2-512", "rsa-sha2-256"],
          hmac: ["hmac-sha2-256", "hmac-sha2-512"],
        },
      });
    } catch (err) {
      sendJson(ws, { type: "error", message: `ssh error: ${err.message}` });
      cleanup(1011, "ssh-connect-throw");
    }
  }
});

// --------------------------------------------------------------------------- //
// Helpers                                                                     //
// --------------------------------------------------------------------------- //

function sendJson(ws, obj) {
  try {
    if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(obj));
  } catch { /* ignore */ }
}

function validateConnect(msg) {
  if (typeof msg.host !== "string" || msg.host.length === 0 || msg.host.length > 253) {
    return "host required (string, <=253 chars)";
  }
  // Loose sanity check — nginx and the OS resolver do the real work.
  if (!/^[A-Za-z0-9.\-:]+$/.test(msg.host)) {
    return "host contains disallowed characters";
  }
  if (msg.port !== undefined && (!Number.isInteger(msg.port) || msg.port < 1 || msg.port > 65535)) {
    return "port must be an integer 1-65535";
  }
  if (typeof msg.username !== "string" || !/^[A-Za-z_][A-Za-z0-9_-]{0,31}$/.test(msg.username)) {
    return "username required (POSIX shape)";
  }
  if (typeof msg.privateKey !== "string" || !msg.privateKey.includes("BEGIN") || !msg.privateKey.includes("PRIVATE KEY")) {
    return "privateKey required (OpenSSH PEM)";
  }
  if (msg.privateKey.length > 16 * 1024) {
    return "privateKey too large";
  }
  if (typeof msg.command !== "string" || msg.command.length === 0 || msg.command.length > 4096) {
    return "command required (<=4096 chars)";
  }
  if (!CMD_ALLOW_REGEX.test(msg.command)) {
    return "command does not match allowlist regex";
  }
  return null;
}

// --------------------------------------------------------------------------- //
// Boot                                                                        //
// --------------------------------------------------------------------------- //

httpServer.listen(PORT, "127.0.0.1", () => {
  log(
    `webssh: listening on 127.0.0.1:${PORT}, origins=[${[...ORIGIN_ALLOW].join(", ")}], max-per-ip=${MAX_PER_IP}, max-session-ms=${MAX_SESSION_MS}`,
  );
});

for (const sig of ["SIGINT", "SIGTERM"]) {
  process.on(sig, () => {
    httpServer.close(() => process.exit(0));
    setTimeout(() => process.exit(1), 5000).unref();
  });
}

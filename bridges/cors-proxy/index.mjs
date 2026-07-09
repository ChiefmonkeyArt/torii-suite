// torii-suite/bridges/cors-proxy/index.mjs
//
// Stateless CORS-adding HTTP forwarder. Zero dependencies (only Node's
// built-in http/https). Runs on plain Linux, listens on 127.0.0.1:$PORT,
// terminates TLS at nginx.
//
// Configuration is env-only:
//   CORS_PROXY_PORT           listen port (default 8801)
//   CORS_PROXY_UPSTREAM_ALLOW comma-separated upstream host allowlist
//                             (default: blesta.sovereignhybridcompute.com)
//   CORS_PROXY_ORIGIN_ALLOW   comma-separated browser Origin allowlist
//                             (default: no origins — refuse everything)
//   CORS_PROXY_MAX_BODY_BYTES response size hard cap (default 10 MiB)
//   CORS_PROXY_LOG_LEVEL      silent|info (default silent)
//
// The proxy is intentionally minimal. It does NOT:
//   - persist state
//   - log request bodies or response bodies
//   - forward Cookie or Set-Cookie headers (SHC API is token-based)
//   - accept a wildcard origin or a wildcard upstream
//
// Client contract:
//   Every browser request goes to:
//     https://<bridge-host>/cors-proxy/<upstream-host>/<path>
//   Example:
//     GET https://bridge.torii.host/cors-proxy/blesta.sovereignhybridcompute.com/api/vps
//   The <upstream-host> segment must appear in CORS_PROXY_UPSTREAM_ALLOW
//   or the proxy returns 403 without forwarding.

import http from "node:http";
import https from "node:https";
import { URL } from "node:url";

// --------------------------------------------------------------------------- //
// Config                                                                      //
// --------------------------------------------------------------------------- //

const PORT = Number.parseInt(process.env.CORS_PROXY_PORT ?? "8801", 10);
const UPSTREAM_ALLOW = new Set(
  (process.env.CORS_PROXY_UPSTREAM_ALLOW ?? "blesta.sovereignhybridcompute.com")
    .split(",")
    .map((h) => h.trim().toLowerCase())
    .filter(Boolean),
);
const ORIGIN_ALLOW = new Set(
  (process.env.CORS_PROXY_ORIGIN_ALLOW ?? "")
    .split(",")
    .map((o) => o.trim())
    .filter(Boolean),
);
const MAX_BODY_BYTES = Number.parseInt(
  process.env.CORS_PROXY_MAX_BODY_BYTES ?? String(10 * 1024 * 1024),
  10,
);
const LOG_LEVEL = process.env.CORS_PROXY_LOG_LEVEL ?? "silent";

const log = (msg) => {
  if (LOG_LEVEL === "info") process.stdout.write(`${msg}\n`);
};

// --------------------------------------------------------------------------- //
// Allowlists — refuse to start if we have nothing to forward to               //
// --------------------------------------------------------------------------- //

if (UPSTREAM_ALLOW.size === 0) {
  process.stderr.write("cors-proxy: CORS_PROXY_UPSTREAM_ALLOW is empty; refusing to start\n");
  process.exit(2);
}
if (ORIGIN_ALLOW.size === 0) {
  process.stderr.write("cors-proxy: CORS_PROXY_ORIGIN_ALLOW is empty; refusing to start\n");
  process.exit(2);
}

// --------------------------------------------------------------------------- //
// Header allowlists                                                           //
// --------------------------------------------------------------------------- //

// Headers we pass through from client -> upstream.
const REQ_HEADER_ALLOW = new Set([
  "accept",
  "accept-language",
  "authorization",
  "content-type",
  "content-length",
  "user-agent",
  "x-nostr-event",  // SHC uses this for npub-delegated auth
  "x-request-id",
]);

// Headers we pass through from upstream -> client.
const RES_HEADER_ALLOW = new Set([
  "content-type",
  "content-length",
  "content-encoding",
  "content-language",
  "cache-control",
  "etag",
  "last-modified",
  "location",
  "x-request-id",
]);

const METHOD_ALLOW = new Set(["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD"]);

// --------------------------------------------------------------------------- //
// Helpers                                                                     //
// --------------------------------------------------------------------------- //

function writeCorsHeaders(res, origin) {
  // Never send * — we've already verified `origin` is in ORIGIN_ALLOW.
  res.setHeader("Access-Control-Allow-Origin", origin);
  res.setHeader("Access-Control-Allow-Methods", [...METHOD_ALLOW].join(", "));
  res.setHeader("Access-Control-Allow-Headers", [...REQ_HEADER_ALLOW].join(", "));
  res.setHeader("Access-Control-Expose-Headers", [...RES_HEADER_ALLOW].join(", "));
  res.setHeader("Access-Control-Max-Age", "600");
  res.setHeader("Vary", "Origin");
}

function fail(res, status, msg, origin) {
  if (origin) writeCorsHeaders(res, origin);
  res.setHeader("Content-Type", "text/plain; charset=utf-8");
  res.statusCode = status;
  res.end(`${msg}\n`);
}

function filterHeaders(headers, allow) {
  const out = {};
  for (const [k, v] of Object.entries(headers)) {
    if (allow.has(k.toLowerCase())) out[k] = v;
  }
  return out;
}

// --------------------------------------------------------------------------- //
// Server                                                                      //
// --------------------------------------------------------------------------- //

const server = http.createServer((req, res) => {
  const originHeader = req.headers.origin;

  // Health endpoint — always OK, no allowlist check.
  if (req.method === "GET" && req.url === "/_health") {
    res.setHeader("Content-Type", "application/json; charset=utf-8");
    res.statusCode = 200;
    res.end(JSON.stringify({ ok: true, service: "torii-cors-proxy" }));
    return;
  }

  // --- Method allowlist ---
  if (!METHOD_ALLOW.has(req.method)) {
    return fail(res, 405, `method ${req.method} not allowed`, originHeader);
  }

  // --- Origin allowlist ---
  //
  // Requests without an Origin header (curl, server-to-server) are refused —
  // the proxy exists to serve browser flows only.
  if (!originHeader) {
    return fail(res, 403, "missing Origin header", null);
  }
  if (!ORIGIN_ALLOW.has(originHeader)) {
    return fail(res, 403, "origin not allowed", null);
  }

  // --- Parse target from path ---
  //
  // Expected: /cors-proxy/<upstream-host>/<path...>
  if (!req.url.startsWith("/cors-proxy/")) {
    return fail(res, 404, "unknown route", originHeader);
  }
  const afterPrefix = req.url.slice("/cors-proxy/".length);
  const firstSlash = afterPrefix.indexOf("/");
  if (firstSlash < 1) {
    return fail(res, 400, "missing upstream host in path", originHeader);
  }
  const upstreamHost = afterPrefix.slice(0, firstSlash).toLowerCase();
  const upstreamPath = afterPrefix.slice(firstSlash);

  if (!UPSTREAM_ALLOW.has(upstreamHost)) {
    return fail(res, 403, "upstream not allowed", originHeader);
  }

  // --- Preflight ---
  if (req.method === "OPTIONS") {
    writeCorsHeaders(res, originHeader);
    res.statusCode = 204;
    res.end();
    return;
  }

  // --- Content-Length cap (reject early if declared oversize) ---
  const declaredLen = Number.parseInt(req.headers["content-length"] ?? "0", 10);
  if (Number.isFinite(declaredLen) && declaredLen > MAX_BODY_BYTES) {
    return fail(res, 413, "request body too large", originHeader);
  }

  // --- Forward ---
  const forwardHeaders = filterHeaders(req.headers, REQ_HEADER_ALLOW);
  // Rewrite Host to the upstream — nginx would otherwise leave the proxy host.
  forwardHeaders["Host"] = upstreamHost;

  const upstreamReq = https.request(
    {
      host: upstreamHost,
      port: 443,
      method: req.method,
      path: upstreamPath,
      headers: forwardHeaders,
      // Modest per-request timeouts. Long polls should use SSE/WebSocket, not
      // this proxy.
      timeout: 30_000,
    },
    (upstreamRes) => {
      // Response size cap — refuse if upstream declares it over budget.
      const upstreamLen = Number.parseInt(
        upstreamRes.headers["content-length"] ?? "0",
        10,
      );
      if (Number.isFinite(upstreamLen) && upstreamLen > MAX_BODY_BYTES) {
        upstreamRes.resume();
        return fail(res, 502, "upstream response too large", originHeader);
      }

      writeCorsHeaders(res, originHeader);
      for (const [k, v] of Object.entries(
        filterHeaders(upstreamRes.headers, RES_HEADER_ALLOW),
      )) {
        res.setHeader(k, v);
      }
      res.statusCode = upstreamRes.statusCode ?? 502;

      // Enforce cap on streamed bodies without declared length.
      let bytesSeen = 0;
      upstreamRes.on("data", (chunk) => {
        bytesSeen += chunk.length;
        if (bytesSeen > MAX_BODY_BYTES) {
          upstreamRes.destroy(new Error("upstream body exceeded MAX_BODY_BYTES"));
          res.destroy();
        }
      });
      upstreamRes.pipe(res);
    },
  );

  upstreamReq.on("timeout", () => {
    upstreamReq.destroy(new Error("upstream timeout"));
  });
  upstreamReq.on("error", (err) => {
    log(`cors-proxy: upstream error: ${err.message}`);
    if (!res.headersSent) fail(res, 502, "upstream error", originHeader);
    else res.destroy();
  });

  // Enforce cap on the incoming body too.
  let inBytes = 0;
  req.on("data", (chunk) => {
    inBytes += chunk.length;
    if (inBytes > MAX_BODY_BYTES) {
      req.destroy();
      upstreamReq.destroy(new Error("request body exceeded MAX_BODY_BYTES"));
    }
  });
  req.pipe(upstreamReq);
});

server.on("clientError", (_err, socket) => {
  socket.destroy();
});

server.listen(PORT, "127.0.0.1", () => {
  log(
    `cors-proxy: listening on 127.0.0.1:${PORT}, upstreams=[${[...UPSTREAM_ALLOW].join(", ")}], origins=[${[...ORIGIN_ALLOW].join(", ")}]`,
  );
});

// Graceful shutdown so systemd stop works cleanly.
for (const sig of ["SIGINT", "SIGTERM"]) {
  process.on(sig, () => {
    server.close(() => process.exit(0));
    // Force-exit after 5s if connections are hanging.
    setTimeout(() => process.exit(1), 5000).unref();
  });
}

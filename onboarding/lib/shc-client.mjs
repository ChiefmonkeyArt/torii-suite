// onboarding/lib/shc-client.mjs
// SHC User API v2 client for the Torii onboarding wireframe.
//
// This module is a thin fetch wrapper around the endpoints the onboarding
// flow hits, in the order it hits them:
//
//   register            → POST /register             (public)
//   getCatalog          → GET  /ordering/catalog     (Basic auth from register)
//   previewOrder        → POST /ordering/preview
//   submitOrder         → POST /ordering/submit
//   getVmSummary        → GET  /vm/{serviceId}/summary
//   checkoutPayment     → POST /payment/{invoiceId}/checkout
//
// Design notes:
//   • All calls go through the SHC User API base URL. In the browser they are
//     proxied via `/cors-proxy/<host>/…` so the deployed Torii page (running
//     on a plain Linux VPS, no third-party CDN) can reach the SHC control
//     plane without hitting a CORS wall. That prefix is handled by
//     bridges/cors-proxy/index.mjs — this file just points at it.
//   • Auth is HTTP Basic. On register, SHC returns an operate-scoped API key
//     in `data.api_key`; the client stores it and swaps to
//     `Authorization: Basic base64(email:apiKey)` for subsequent calls.
//   • Every response is normalized: success unwraps `data`, error throws an
//     `ShcError` carrying `code`, `message`, `requestId`, `details`, `status`.
//     Screen-level code branches on `err.code`, never on HTTP status.
//   • Mock mode: if `window.__shcMock` is present, every method delegates to
//     `window.__shcMock.<method>(...)`. shc-mock.mjs installs the shim when
//     `?mock=1` is on the URL. Live code paths are unchanged.
//
// No secrets are logged. Nothing leaves the browser tab except the fetch
// bodies that SHC itself defines.

const DEFAULT_BASE = "https://blesta.sovereignhybridcompute.com/user-api/v2";
const DEFAULT_PROXY_PREFIX = "/cors-proxy/";

function b64(s) {
  // btoa is fine here — inputs are ASCII (email + hex API key).
  return typeof btoa === "function" ? btoa(s) : Buffer.from(s, "utf8").toString("base64");
}

/**
 * Build a proxied URL from a base and a path.
 *   base   = "https://blesta.sovereignhybridcompute.com/user-api/v2"
 *   path   = "/ordering/catalog"
 *   proxy  = "/cors-proxy/"
 *   result = "/cors-proxy/blesta.sovereignhybridcompute.com/user-api/v2/ordering/catalog"
 */
function proxied(base, path, proxyPrefix) {
  const u = new URL(base);
  const suffix = (u.pathname.replace(/\/+$/, "")) + path;
  return proxyPrefix.replace(/\/+$/, "/") + u.host + suffix;
}

/**
 * RFC 4122 v4-ish idempotency key. Uses crypto.randomUUID when available.
 * Length is 36 chars — well inside SHC's 16..128 range.
 */
function newIdempotencyKey() {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return crypto.randomUUID();
  }
  // Fallback: 16 random bytes, hex.
  const bytes = new Uint8Array(16);
  (crypto?.getRandomValues || (a => a.forEach((_, i, arr) => { arr[i] = Math.floor(Math.random() * 256); })))(bytes);
  return Array.from(bytes, b => b.toString(16).padStart(2, "0")).join("");
}

export class ShcError extends Error {
  constructor({ code, message, requestId, details, status }) {
    super(message || code || "shc_error");
    this.name = "ShcError";
    this.code = code || "unknown";
    this.requestId = requestId || null;
    this.details = details || null;
    this.status = status ?? null;
  }
}

/**
 * Create a client. Options:
 *   base          - SHC User API base URL (default: production).
 *   proxyPrefix   - CORS proxy prefix served by our bridge (default: /cors-proxy/).
 *   fetchImpl     - override for testing (default: global fetch).
 *   credentials   - { email, apiKey } to seed if you already have one.
 */
export function createShcClient(opts = {}) {
  // Mock shim: if window.__shcMock exists, hand every call to it verbatim.
  if (typeof window !== "undefined" && window.__shcMock) {
    return window.__shcMock;
  }

  const base = opts.base || DEFAULT_BASE;
  const proxyPrefix = opts.proxyPrefix || DEFAULT_PROXY_PREFIX;
  const fetchImpl = opts.fetchImpl || fetch;

  let creds = opts.credentials ? { ...opts.credentials } : null;

  function authHeader() {
    if (!creds || !creds.email || !creds.apiKey) return null;
    return "Basic " + b64(`${creds.email}:${creds.apiKey}`);
  }

  async function request(method, path, { body, headers, idempotencyKey, requiresAuth = true } = {}) {
    const url = proxied(base, path, proxyPrefix);

    const h = {
      "Accept": "application/json",
      ...(headers || {}),
    };
    if (body !== undefined) h["Content-Type"] = "application/json";

    if (requiresAuth) {
      const auth = authHeader();
      if (!auth) {
        throw new ShcError({
          code: "unauthorized",
          message: "SHC client has no credentials yet — call register() first.",
        });
      }
      h["Authorization"] = auth;
    }

    if ((method === "POST" || method === "PATCH" || method === "PUT" || method === "DELETE") && idempotencyKey !== false) {
      h["Idempotency-Key"] = idempotencyKey || newIdempotencyKey();
    }

    let res;
    try {
      res = await fetchImpl(url, {
        method,
        headers: h,
        body: body !== undefined ? JSON.stringify(body) : undefined,
        // Deliberately no `credentials: "include"` — we authenticate with an
        // explicit Basic header, not cookies. The proxy strips cookies anyway.
        credentials: "omit",
      });
    } catch (e) {
      throw new ShcError({
        code: "network_error",
        message: `network error contacting SHC: ${e.message}`,
        status: null,
      });
    }

    const requestId = res.headers.get("X-Request-Id") || null;
    const text = await res.text();
    let json = null;
    if (text) {
      try { json = JSON.parse(text); } catch { /* leave null */ }
    }

    if (!res.ok) {
      const err = (json && json.error) || {};
      throw new ShcError({
        code: err.code || `http_${res.status}`,
        message: err.message || res.statusText || `HTTP ${res.status}`,
        requestId: err.request_id || requestId,
        details: err.details || null,
        status: res.status,
      });
    }

    // Success shapes: {data: …} for singletons, {items, pagination} for lists.
    if (json && "data" in json) return json.data;
    return json;
  }

  return {
    // ---- session state ---------------------------------------------------

    /** Return current credentials without leaking the key into logs. */
    getSession() {
      if (!creds) return null;
      return { email: creds.email, hasKey: !!creds.apiKey };
    },

    /** Manually seed credentials (useful if resuming after refresh). */
    setCredentials({ email, apiKey }) {
      creds = { email, apiKey };
    },

    clearCredentials() { creds = null; },

    // ---- endpoints -------------------------------------------------------

    /**
     * POST /register — create a new SHC account and mint an operate-scoped
     * API key in one call. Public endpoint.
     *
     * The returned key is stored on the client so subsequent calls
     * authenticate automatically.
     *
     * @param {object} p
     * @param {string} p.email
     * @param {string} p.password
     * @param {string} p.firstName
     * @param {string} p.lastName
     * @param {string} [p.country]           ISO 3166-1 alpha-2
     * @param {string} [p.recoveryEmail]
     * @returns {Promise<{client_id:number, email:string, api_key:{key:string, expires_at:string}, ...}>}
     */
    async register({ email, password, firstName, lastName, country, recoveryEmail }) {
      const body = {
        email,
        password,
        first_name: firstName,
        last_name: lastName,
        tos_accepted: true,
        scope: "operate",
      };
      if (country) body.country = country;
      if (recoveryEmail) body.recovery_email = recoveryEmail;

      const data = await request("POST", "/register", { body, requiresAuth: false });

      // Store credentials for subsequent calls.
      const apiKey = data?.api_key?.key || data?.api_key;
      if (apiKey && typeof apiKey === "string") {
        creds = { email, apiKey };
      }
      return data;
    },

    /**
     * GET /ordering/catalog — the storefront the wireframe picks a plot from.
     * `view=lean` keeps the payload small; the wireframe only needs
     * package_id, pricing_id, name, specs, price.
     */
    async getCatalog({ view = "lean" } = {}) {
      const qs = view ? `?view=${encodeURIComponent(view)}` : "";
      return request("GET", `/ordering/catalog${qs}`, { idempotencyKey: false });
    },

    /**
     * POST /ordering/preview — dry-run an order to get the exact billed price
     * and confirm the hostname/ssh_key/module_group_id are valid before we
     * spend the invoice-scoped idempotency key on submit.
     */
    async previewOrder({ packageId, pricingId, hostname, sshKey, moduleGroupId, configOptions }) {
      const body = {
        package_id: packageId,
        pricing_id: pricingId,
        hostname,
        ssh_key: sshKey,
      };
      if (moduleGroupId != null) body.module_group_id = moduleGroupId;
      if (configOptions) body.config_options = configOptions;
      // Preview is stateless — no idempotency key needed.
      return request("POST", "/ordering/preview", { body, idempotencyKey: false });
    },

    /**
     * POST /ordering/submit — create the order + invoice.
     *
     * Returns `{ service_ids, invoice, virtual_machines, order, ... }`. The
     * onboarding flow reads `service_ids[0]` (poll target) and
     * `invoice.invoice_id` (checkout target).
     */
    async submitOrder({ packageId, pricingId, hostname, sshKey, moduleGroupId, configOptions, idempotencyKey }) {
      const body = {
        package_id: packageId,
        pricing_id: pricingId,
        hostname,
        ssh_key: sshKey,
      };
      if (moduleGroupId != null) body.module_group_id = moduleGroupId;
      if (configOptions) body.config_options = configOptions;
      return request("POST", "/ordering/submit", { body, idempotencyKey });
    },

    /**
     * GET /vm/{serviceId}/summary — one-call VM overview. The onboarding flow
     * polls this every 3–5s during screen 7 until
     * `provisioning_state === "ready"`. `service_status === "active"` alone
     * is NOT enough (per SHC docs).
     */
    async getVmSummary(serviceId) {
      return request("GET", `/vm/${encodeURIComponent(serviceId)}/summary`, { idempotencyKey: false });
    },

    /**
     * POST /payment/{invoiceId}/checkout — request a BTCPay checkout URL.
     *
     * Returns either:
     *   { status: "checkout_required", checkout_url, btcpay_invoice_id, expires_at, ... }
     * or:
     *   { status: "paid", invoice_id, transaction_id, paid_at, applied_credit }
     *
     * The wireframe renders `checkout_url` as a QR on screen 6.
     */
    async checkoutPayment({ invoiceId, gateway = "btcpay_server", returnUrl, cancelUrl, idempotencyKey }) {
      const body = {
        gateway,
        idempotency_key: idempotencyKey || newIdempotencyKey(),
      };
      if (returnUrl) body.return_url = returnUrl;
      if (cancelUrl) body.cancel_url = cancelUrl;
      return request("POST", `/payment/${encodeURIComponent(invoiceId)}/checkout`, {
        body,
        // The invoice-scoped idempotency key lives inside the body per SHC's
        // /payment contract; we still pass the header so retries dedupe.
        idempotencyKey: body.idempotency_key,
      });
    },

    // ---- small helpers ---------------------------------------------------

    /**
     * Poll getVmSummary until `provisioning_state === "ready"` or a deadline
     * expires. Yields each summary via onUpdate so the UI can show progress.
     */
    async waitForReady(serviceId, { intervalMs = 4000, timeoutMs = 10 * 60 * 1000, onUpdate, signal } = {}) {
      const deadline = Date.now() + timeoutMs;
      // eslint-disable-next-line no-constant-condition
      while (true) {
        if (signal?.aborted) throw new ShcError({ code: "aborted", message: "polling aborted" });
        const summary = await this.getVmSummary(serviceId);
        if (typeof onUpdate === "function") {
          try { onUpdate(summary); } catch { /* UI errors must not stop polling */ }
        }
        if (summary?.provisioning_state === "ready") return summary;
        if (summary?.provisioning_state === "failed") {
          throw new ShcError({
            code: "provisioning_failed",
            message: "VM provisioning failed on the SHC side.",
            details: summary,
          });
        }
        if (Date.now() > deadline) {
          throw new ShcError({
            code: "provisioning_timeout",
            message: `VM ${serviceId} not ready after ${Math.round(timeoutMs/1000)}s`,
          });
        }
        await new Promise(r => setTimeout(r, intervalMs));
      }
    },
  };
}

// Convenience re-exports so callers don't have to import both symbols.
export { newIdempotencyKey };

// onboarding/lib/shc-mock.mjs
// ?mock=1 fake-but-schema-shaped responses for SHC + WebSSH.
//
// Purpose: let a developer click through the full onboarding flow (screens
// 1–8) with zero network I/O, zero real spend, and zero real VPS — but with
// data shapes that match SHC's OpenAPI v2 spec byte-for-byte so screen code
// tested against the mock will work against the real API.
//
// Activation: call `installShcMock()` (idempotent) when the page loads if
// `?mock=1` is on the URL. That installs `window.__shcMock` and
// `window.__websshMock`; shc-client.mjs and webssh-client.mjs will pick them
// up automatically and skip the real fetch/WebSocket layer.
//
// Every mock response is derived from the OpenAPI examples snapshotted at
// onboarding/reference/shc-openapi-v2.4.1.json. Keep them in sync if the
// spec is bumped.

// ------------------------------------------------------------------------- //
// URL flag                                                                  //
// ------------------------------------------------------------------------- //

export function isMockMode() {
  if (typeof window === "undefined") return false;
  try {
    return new URLSearchParams(window.location.search).get("mock") === "1";
  } catch {
    return false;
  }
}

// ------------------------------------------------------------------------- //
// Helpers                                                                   //
// ------------------------------------------------------------------------- //

function delay(ms) { return new Promise(r => setTimeout(r, ms)); }
function pad(n, w = 2) { return String(n).padStart(w, "0"); }
function isoPlus(seconds) {
  const d = new Date(Date.now() + seconds * 1000);
  return d.toISOString().replace(/\.\d{3}Z$/, "+00:00");
}
function fakeId(prefix = "") {
  // Deterministic-ish 4-digit id, prefixed for readability.
  return prefix + Math.floor(1000 + Math.random() * 9000);
}
function fakeShcKey() {
  // Shape: shc_live_ + 32 hex chars. Real keys are longer; this is only ever
  // shown in dev tools.
  let hex = "";
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  for (const b of bytes) hex += b.toString(16).padStart(2, "0");
  return "shc_live_" + hex;
}

// ------------------------------------------------------------------------- //
// State — a tiny in-memory shadow of the SHC account                        //
// ------------------------------------------------------------------------- //

const state = {
  session: null,       // { email, apiKey }
  serviceId: null,     // set on submitOrder
  invoiceId: null,
  submittedAt: 0,
};

// ------------------------------------------------------------------------- //
// SHC mock                                                                  //
// ------------------------------------------------------------------------- //

const shcMock = {
  getSession() {
    return state.session ? { email: state.session.email, hasKey: true } : null;
  },
  setCredentials({ email, apiKey }) { state.session = { email, apiKey }; },
  clearCredentials() { state.session = null; },

  async register({ email, firstName, lastName }) {
    await delay(200);
    const apiKey = fakeShcKey();
    state.session = { email, apiKey };
    return {
      client_id: Number(fakeId()),
      email,
      first_name: firstName,
      last_name: lastName,
      country: "GB",
      created_at: isoPlus(0),
      api_key: {
        key: apiKey,
        scope: "operate",
        expires_at: isoPlus(90 * 24 * 3600),
      },
      next: { catalog_url: "/user-api/v2/ordering/catalog" },
    };
  },

  async getCatalog(/* { view } */) {
    await delay(150);
    // Trimmed lean-view catalog. The wireframe only reads name + specs +
    // pricing[0].price, so this is enough. Two "plots" so screen 5 has a
    // choice.
    return {
      items: [
        {
          package_id: 23,
          name: "NVMe VPS — Starter",
          template: "debian13-cloud",
          image: {
            name: "debian13-cloud",
            display_name: "Debian 13 Cloud",
            default_user: "debian",
            cloudinit: true,
          },
          specs: { cpu: 1, memory_mb: 2048, disk_gb: 40, bandwidth_gb: 4000, ipv4: 1, ipv6: 1 },
          pricing: [{ pricing_id: 12, term: 1, period: "month", price: "11.99", renew: "11.99", setup_fee: "0.00", currency: "USD" }],
          module_groups: [{ id: 4, name: "Katy, Texas" }],
          default_module_group_id: 4,
        },
        {
          package_id: 24,
          name: "NVMe VPS — Standard",
          template: "debian13-cloud",
          image: {
            name: "debian13-cloud",
            display_name: "Debian 13 Cloud",
            default_user: "debian",
            cloudinit: true,
          },
          specs: { cpu: 2, memory_mb: 4096, disk_gb: 80, bandwidth_gb: 8000, ipv4: 1, ipv6: 1 },
          pricing: [{ pricing_id: 13, term: 1, period: "month", price: "23.99", renew: "23.99", setup_fee: "0.00", currency: "USD" }],
          module_groups: [{ id: 4, name: "Katy, Texas" }],
          default_module_group_id: 4,
        },
      ],
      pagination: { total: 2, limit: 25, offset: 0, has_more: false },
    };
  },

  async previewOrder({ packageId, pricingId, hostname }) {
    await delay(200);
    const price = packageId === 24 ? "23.99" : "11.99";
    return {
      lnvps_compatible: true,
      order_submission_supported: true,
      submit_path: "/user-api/v2/ordering/submit",
      normalized_request: {
        package_id: packageId,
        pricing_id: pricingId,
        hostname,
        user: "debian",
        ssh_key_present: true,
        module_group_id: 4,
        coupon_present: false,
      },
      package: {
        package_id: packageId,
        name: packageId === 24 ? "NVMe VPS — Standard" : "NVMe VPS — Starter",
        template: "debian13-cloud",
        image: { name: "debian13-cloud", display_name: "Debian 13 Cloud", default_user: "debian", cloudinit: true },
      },
      billing: {
        pricing_id: pricingId,
        term: 1,
        period: "month",
        price,
        renew: price,
        setup_fee: "0.00",
        currency: "USD",
        initial_due: price,
        renewal_amount: price,
      },
      provisioning: { hostname, user: "debian" },
    };
  },

  async submitOrder({ packageId, pricingId, hostname, sshKey }) {
    await delay(300);
    state.serviceId = Number(fakeId());
    state.invoiceId = Number(fakeId());
    state.submittedAt = Date.now();
    const price = packageId === 24 ? "23.99" : "11.99";
    return {
      lnvps_compatible: true,
      submitted: true,
      order: {
        order_id: Number(fakeId()),
        order_number: "1000" + state.serviceId,
        status: "accepted",
        order_form_id: 1,
        order_form_label: "NVME",
        package_group_id: 3,
      },
      invoice: {
        invoice_id: state.invoiceId,
        invoice_status: "open",
        currency: "USD",
        total: price,
        paid: "0.00",
        balance_due: price,
        date_due: isoPlus(30 * 24 * 3600),
      },
      service_ids: [state.serviceId],
      virtual_machines: [{
        id: state.serviceId,
        hostname,
        os_user: "debian",
        os_template: "debian13-cloud",
        service_status: "pending",
        provisioning_state: "pending",
        bootstrap_completed_at: null,
        package: packageId === 24 ? "NVMe VPS — Standard" : "NVMe VPS — Starter",
        specs: packageId === 24
          ? { cpu: 2, memory_mb: 4096, disk_gb: 80, bandwidth_gb: 8000, ipv4: 1, ipv6: 1 }
          : { cpu: 1, memory_mb: 2048, disk_gb: 40, bandwidth_gb: 4000, ipv4: 1, ipv6: 1 },
        ips: [],
        ssh_key: sshKey,
        pricing: { term: 1, period: "month", price, renew: price, currency: "USD" },
        date_created: isoPlus(0),
        date_renews: null,
        date_suspended: null,
        date_canceled: null,
      }],
      normalized_request: {
        package_id: packageId,
        pricing_id: pricingId,
        hostname,
        user: "debian",
        ssh_key_present: true,
      },
    };
  },

  async getVmSummary(serviceId) {
    await delay(100);
    // Timeline: pending 0-3s → provisioning 3-10s → ready thereafter. Keeps
    // the wireframe's poll loop honest without making dev testing painful.
    const elapsed = Date.now() - state.submittedAt;
    let provisioning_state = "pending";
    if (elapsed > 10_000) provisioning_state = "ready";
    else if (elapsed > 3_000) provisioning_state = "provisioning";

    const ready = provisioning_state === "ready";
    return {
      id: Number(serviceId),
      hostname: "torii-plot-" + serviceId,
      os_user: "debian",
      package: "NVMe VPS — Starter",
      service_status: ready ? "active" : "pending",
      provisioning_state,
      ips: ready ? [{ ip: "203.0.113.42", cidr: "203.0.113.42/24", gateway: "203.0.113.1", type: "v4" }] : [],
      date_created: isoPlus(-Math.floor(elapsed / 1000)),
      date_renews: ready ? isoPlus(30 * 24 * 3600) : null,
      has_active_job: !ready,
      recent_jobs: [{
        job_id: 4821,
        type: "provision",
        status: ready ? "completed" : "running",
        progress: ready ? 100 : Math.min(95, Math.floor(elapsed / 100)),
        created_at: isoPlus(-Math.floor(elapsed / 1000)),
        completed_at: ready ? isoPlus(-1) : null,
      }],
      runtime: ready ? { power_state: "running", cpu_percent: 4, memory_used_mb: 180 } : null,
    };
  },

  async checkoutPayment({ invoiceId }) {
    await delay(200);
    return {
      status: "checkout_required",
      // A deliberately fake URL — the QR is still renderable, but nobody
      // should navigate to it. Documented as such in the fake host.
      checkout_url: `https://mock.invalid/i/${invoiceId}`,
      btcpay_invoice_id: "MOCK_" + invoiceId,
      invoice_id: Number(invoiceId),
      gateway: "btcpay_server",
      expires_at: isoPlus(15 * 60),
    };
  },

  // The client's waitForReady helper polls getVmSummary — no separate mock
  // implementation needed. But provide one anyway so callers importing the
  // shim directly still work.
  async waitForReady(serviceId, { intervalMs = 500, timeoutMs = 30_000, onUpdate } = {}) {
    const deadline = Date.now() + timeoutMs;
    // eslint-disable-next-line no-constant-condition
    while (true) {
      const s = await this.getVmSummary(serviceId);
      onUpdate?.(s);
      if (s.provisioning_state === "ready") return s;
      if (Date.now() > deadline) throw new Error("mock: provisioning_timeout");
      await delay(intervalMs);
    }
  },
};

// ------------------------------------------------------------------------- //
// WebSSH mock                                                               //
// ------------------------------------------------------------------------- //

// A canned bootstrap transcript — one line at a time — for screen 7 to
// stream. Kept short so dev testing takes seconds, not minutes.
const MOCK_BOOTSTRAP_LINES = [
  "[torii-bootstrap] starting on your fresh plot",
  "[torii-bootstrap] updating package index...",
  "[torii-bootstrap] installing base tools (curl, git, jq)...",
  "[torii-bootstrap] locking down SSH: password auth disabled",
  "[torii-bootstrap] installing docker + docker compose",
  "[torii-bootstrap] pulling torii container images",
  "[torii-bootstrap] writing torii systemd unit",
  "[torii-bootstrap] starting torii service",
  "[torii-bootstrap] all systems green",
  "[torii-bootstrap] your plot is live",
];

const websshMock = {
  open(opts) {
    const { onOutput, onReady, onExit, onClose } = opts;
    let closed = false;

    // Fire "ready" one tick later so callers can await the return value first.
    queueMicrotask(() => {
      if (closed) return;
      try { onReady?.(); } catch { /* ignore */ }
      streamLines();
    });

    async function streamLines() {
      for (const line of MOCK_BOOTSTRAP_LINES) {
        if (closed) return;
        await delay(400 + Math.floor(Math.random() * 300));
        if (closed) return;
        try { onOutput?.("stdout", line + "\n"); } catch { /* ignore */ }
      }
      if (closed) return;
      try { onExit?.(0); } catch { /* ignore */ }
      try { onClose?.({ code: 1000, reason: "cmd-exit" }); } catch { /* ignore */ }
      closed = true;
    }

    return {
      write() { /* noop in mock — no interactive shell */ },
      resize() { /* noop */ },
      close() {
        if (closed) return;
        closed = true;
        try { onClose?.({ code: 1000, reason: "client-close" }); } catch { /* ignore */ }
      },
      readyState() { return closed ? "closed" : "open"; },
    };
  },
};

// ------------------------------------------------------------------------- //
// Installer                                                                 //
// ------------------------------------------------------------------------- //

/**
 * Install the mocks on window. Idempotent — safe to call from any script tag
 * as long as it runs before shc-client.mjs and webssh-client.mjs are first
 * used.
 *
 * Only installs when isMockMode() returns true. Otherwise a noop.
 */
export function installShcMock() {
  if (typeof window === "undefined") return false;
  if (!isMockMode()) return false;
  if (window.__shcMock) return true;   // idempotent

  window.__shcMock = shcMock;
  window.__websshMock = websshMock;

  // A visible breadcrumb so it's obvious the dev is in mock mode.
  try {
    // eslint-disable-next-line no-console
    console.info("%c[torii] SHC mock installed — ?mock=1", "color:#f80;font-weight:bold");
  } catch { /* ignore */ }
  return true;
}

// Export the mock modules too, so a test harness can drive them directly
// without hitting window.
export { shcMock, websshMock };

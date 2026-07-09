# Hosting a Torii

You have three paths from "I want a Torii" to a working VPS. Pick the one that
matches how you like to pay and how much you want to touch a terminal.

At the technical layer they are indistinguishable — the same `bootstrap.sh`
runs on all three. The choice is really about **billing** and **sovereignty**.

| Option                         | Payment      | Trust                            | Best for                                                    |
| ------------------------------ | ------------ | -------------------------------- | ----------------------------------------------------------- |
| [BYO VPS](#byo-vps)            | Fiat card    | Your provider                    | You already have a Hetzner/DO/Namecheap account            |
| [SHC](#sovereign-hybrid-compute) | Bitcoin      | SHC + npub delegation           | You want to buy compute in sats and never hand over a card |
| [Any other Ubuntu 22/24 VPS](#any-other-provider) | Whatever they take | Whoever you pick | Existing relationship, region, or ideological pick |

The rest of this document walks through each in enough detail to get from
"empty VPS" to `sudo -E ./bootstrap.sh` succeeding.

---

## Baseline requirements

Every path needs the same three things:

1. **A VPS** running Ubuntu 22.04 LTS or 24.04 LTS with at least
   **1 vCPU / 2 GB RAM / 20 GB disk** (Continuum + Quest builds are the
   memory bump — the running services idle at ~200 MB).
2. **A domain** with a single `A` record pointing at the VPS's public IP.
   Cheap TLDs work fine; you'll want to control DNS from your registrar.
3. **A NIP-07 signer** in your browser (Plebeian Signer, nos2x, Alby)
   holding the `npub` you plan to hand the installer.

If any of those three are missing, none of the paths below work.

---

## BYO VPS

If you already have a hosting account, use it. The installer doesn't care who
bills you — it just needs root and a domain.

### Providers that work out of the box

Any of these will host a Torii comfortably on their smallest paid tier:

- **[Hetzner Cloud](https://www.hetzner.com/cloud)** — CX22 (2 vCPU / 4 GB / 40 GB) ≈ €4.51/mo. Best price/performance in EU.
- **[DigitalOcean](https://www.digitalocean.com/pricing/droplets)** — Basic 2 GB droplet ≈ $12/mo.
- **[Vultr](https://www.vultr.com/pricing/)** — Cloud Compute 2 GB ≈ $12/mo.
- **[Linode](https://www.linode.com/pricing/)** — Shared 2 GB ≈ $12/mo.
- **[Namecheap VPS](https://www.namecheap.com/hosting/vps/)** — entry tier if you're already registered there.

### Steps

```bash
# 1. Provision a fresh Ubuntu 22.04 or 24.04 server (2 GB RAM minimum).
# 2. Point your domain's A record at the server's public IP. Wait for DNS
#    to resolve (usually a few minutes; check with `dig +short A yourdomain`).
# 3. SSH in as root and:

git clone https://github.com/ChiefmonkeyArt/torii-suite.git
cd torii-suite
cp .env.example .env
nano .env    # fill in TORII_DOMAIN, LETSENCRYPT_EMAIL, CONTINUUM_ADMIN_NPUB
sudo -E ./bootstrap.sh
```

**Yearly cost estimate:** ~$50–150 depending on provider and region.

---

## Sovereign Hybrid Compute

[Sovereign Hybrid Compute](https://sovereignhybridcompute.com) (SHC) sells VPS
capacity billed in Bitcoin. Two things make it a natural fit for Torii:

1. **You pay in sats via Lightning.** No cards, no KYC hoop-jumping.
2. **npub-based agent delegation.** SHC's API lets you delegate specific
   provisioning actions to another key. Instead of pasting a long-lived API
   token into a webform, you sign a scoped delegation event from your NIP-07
   signer — the same key you use for everything else Nostr.

The full API is documented at
[blesta.sovereignhybridcompute.com/user-api/docs](https://blesta.sovereignhybridcompute.com/user-api/docs).
Highlights relevant to Torii:

- **Scoped API keys** — read-only, provision-only, or full-control, each with
  independent expiry.
- **MCP server** at `mcp.sovereignhybridcompute.com` for agent-driven
  provisioning workflows.
- **Lightning invoice per action** — top up, spin up, resize.

### Steps (manual)

The steps are identical to BYO once the VPS exists. The differences are
upstream — how you buy compute and how you get its IP.

```bash
# 1. Create an SHC account, top up a small Lightning balance.
# 2. Provision an Ubuntu 22.04 VPS via the SHC dashboard.
# 3. Note the assigned IPv4 address. Point your domain's A record at it.
# 4. SSH in as root and run the standard bootstrap flow above.
```

### Steps (browser-side onboarding)

If you'd rather not touch a terminal, `torii-suite`'s
[non-coder onboarding flow](../onboarding/prototype.html) drives the SHC API
directly from your browser. Your browser:

1. Buys the VPS (SHC Lightning invoice paid in the same window).
2. Generates an SSH keypair, holds the private half in tab memory.
3. Pushes the public half to the fresh VPS.
4. Runs `bootstrap.sh` over an ephemeral SSH-over-WebSocket connection.
5. Shows you the finished domain when it's done.

**Torii never sees your SHC API key, SSH private key, or backup passphrase.**
Everything with a lifespan longer than the browser tab lives on your device
or in your NIP-07 signer.

The full trust boundary is documented in
[ONBOARDING_ARCHITECTURE.md](ONBOARDING_ARCHITECTURE.md).

**Yearly cost estimate:** ~$60–120 for the SHC VPS tier + ~$15–25 for the
domain + a small Cashu top-up for Continuum's Routstr calls.

---

## Any other provider

If you have a favorite VPS provider not listed above, use it. The installer's
only requirements are:

- Ubuntu 22.04 LTS or 24.04 LTS
- Root or passwordless sudo
- A public IPv4 with an A record you control
- Open outbound HTTPS (for npm, apt, certbot)
- Ports 80 and 443 reachable from the public internet

If a provider ships their own firewall, open 80 + 443 before running the
bootstrap — otherwise certbot's HTTP-01 challenge fails.

---

## Quest sub-path caveat

Torii Quest was originally built to serve from the domain root. `torii-suite`
mounts it at `/quest/` on the shared torii-base nginx server block, which
means the installer has to patch `vite.config.js` at build time to inject a
`base: '/quest/'` and rewrite the two hardcoded `/assets/torii-entry.js`
literals in the inline bootstrap.

This is applied automatically by
[`installers/install-quest.sh`](../installers/install-quest.sh). The patch is
idempotent — re-running the installer detects it's already been applied and
skips it. The upstream fix (accepting a build-time env var for the base path)
is tracked as a Quest issue and will retire this patch once landed.

If you'd rather serve Quest from a dedicated subdomain, set
`INSTALL_QUEST=0` in `.env`, run `bootstrap.sh` to install everything else,
then follow `torii-quest/deploy/DEPLOY.md` on a second VPS or subdomain.
The launcher tile can be re-pointed with `sudo torii unregister quest &&
sudo torii register quest --display 'Torii Quest' --version 0.2.362-alpha`
followed by an nginx fragment of your own.

---

## Cost summary

Ballpark yearly cost for a self-hosted Torii, USD:

| Line item                                | Low   | High  |
| ---------------------------------------- | ----- | ----- |
| VPS (small tier, either fiat or SHC)     | $50   | $150  |
| Domain registration                      | $10   | $30   |
| Cashu top-up (Continuum → Routstr)       | $5    | $20   |
| Optional Torii support subscription      | $0    | $121  |
| **Total year one**                       | **$65** | **$321** |
| **Renewal (subsequent years)**           | **$65** | **$200** |

Set expectations before you buy — Continuum's AI calls (Routstr, DeepSeek) are
sat-metered per request. A steady week of building will chew through more
Cashu than a light week of chatting. There is no monthly ceiling from Torii;
you're paying the model provider directly, one request at a time.

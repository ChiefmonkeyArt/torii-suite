# Onboarding reference — SHC User API

Snapshot of the upstream contract the onboarding wireframe wires against.
Kept in-repo so a reviewer can audit exactly which endpoints and shapes the
wireframe assumes without having to re-fetch a moving target.

| File | Source | Snapshot taken |
|---|---|---|
| `shc-openapi-v2.4.1.json` | `https://blesta.sovereignhybridcompute.com/user-api/openapi.json` | 2026-07-09 |
| `shc-llms.txt` | `https://blesta.sovereignhybridcompute.com/user-api/llms.txt` | 2026-07-09 |

Both are v2.4.x. Re-snapshot with:

```bash
curl -sS https://blesta.sovereignhybridcompute.com/user-api/openapi.json \
  -o onboarding/reference/shc-openapi-v2.4.1.json
curl -sS https://blesta.sovereignhybridcompute.com/user-api/llms.txt \
  -o onboarding/reference/shc-llms.txt
```

Rename the JSON file if you bump to a newer minor. The wireframe pins to
the operation IDs and field names documented here, not to any specific
schema version.

## Endpoints the onboarding flow uses

All requests go through the CORS proxy:
`https://<host>/cors-proxy/blesta.sovereignhybridcompute.com/user-api/v2/<path>`.

| Step | Method + path | Auth |
|---|---|---|
| Register | `POST /register` | public |
| Fetch plans | `GET /ordering/catalog` | Basic (email + password from register) |
| Preview order | `POST /ordering/preview` | Basic |
| Submit order | `POST /ordering/submit` | Basic |
| Get invoice checkout | `POST /payment/{invoiceId}/checkout` | Basic |
| Poll VM readiness | `GET /vm/{serviceId}/summary` | Basic |
| Live-inject SSH key | `POST /vm/{serviceId}/ssh-keys/apply-live` | Basic |

The SSH key generated in-browser is passed as `ssh_key` on the initial
`/ordering/submit`, so `apply-live` is only used for post-provision key
rotation and is not on the critical path for v0.1.3.

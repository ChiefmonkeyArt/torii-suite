# Vendored dependencies

Runtime crypto libraries copied verbatim from npm and served from this
same VPS. NEVER loaded from a third-party CDN.

## noble-secp256k1

- Upstream: https://github.com/paulmillr/noble-secp256k1
- Registry: https://registry.npmjs.org/@noble/secp256k1
- Version: 3.1.0
- License: MIT (see `noble-secp256k1/LICENSE`)
- File: `noble-secp256k1/secp256k1.mjs` (copy of `index.js` from the
  npm tarball, unmodified)
- Purpose: ephemeral secp256k1 keypair generation, ECDH shared-secret
  derivation, BIP-340 Schnorr signing — all required by v0.1.6-alpha's
  NIP-59 gift-wrap of the recovery hint DM.
- Chosen because: audited, zero-dependency, single-file, MIT.
- Async variants (`schnorr.signAsync`, `schnorr.verifyAsync`) use
  WebCrypto's `subtle.digest` for SHA-256 directly, so no hash-injection
  vendoring of `@noble/hashes` is needed. Sync variants would require it;
  we deliberately do not use them.
- Update policy: bump the VERSION file, refresh this note, verify the
  file matches the upstream tarball via `sha256sum`, and commit as a
  distinct step from feature work.

## sha256 of vendored files (for future integrity checks)

Generate with:
```
sha256sum lib/vendor/noble-secp256k1/secp256k1.mjs
```

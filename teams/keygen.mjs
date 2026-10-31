// Installer-only: generates the Cordn coordinator's service key on the node.
// This is a service identity, never a person's nsec. Prints "<hex sk> <hex pk>".
import { createECDH } from 'node:crypto';

const ecdh = createECDH('secp256k1');
ecdh.generateKeys();
const sk = ecdh.getPrivateKey('hex').padStart(64, '0');
const pk = ecdh.getPublicKey('hex', 'compressed').slice(2); // BIP-340 x-only
if (!/^[0-9a-f]{64}$/.test(sk) || !/^[0-9a-f]{64}$/.test(pk)) process.exit(1);
process.stdout.write(`${sk} ${pk}\n`);

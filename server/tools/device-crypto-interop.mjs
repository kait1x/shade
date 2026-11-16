// Test-only bridge. Synthetic browser keys stay in this process. Only public
// keys, ciphertext, test plaintext and signatures cross stdin/stdout.
import readline from 'node:readline';
import { createVault, unlockVault, descriptor, encryptLegacy, decryptLegacy } from '../../client/web/device_crypto.mjs';
import { sign, verifyManifest } from '../../client/web/protocol/device-v2.mjs';
import { legacyRoot } from '../multidevice/registry.mjs';

const vault = await createVault('interop_test', 'synthetic test vault password only');
const session = await unlockVault(vault, 'synthetic test vault password only');
console.log(JSON.stringify({ descriptor: descriptor(vault) }));
for await (const line of readline.createInterface({ input: process.stdin })) {
  try {
    const request = JSON.parse(line);
    let result;
    if (request.action === 'encrypt') result = await encryptLegacy(request.text, legacyRoot(request.publicKey));
    else if (request.action === 'decrypt') result = await decryptLegacy(request.payload, session.encryption);
    else if (request.action === 'sign') result = await sign(request.text, session.signing);
    else if (request.action === 'manifest') result = await verifyManifest(request.manifest, legacyRoot(request.publicKey));
    else throw new Error('Unknown test action');
    console.log(JSON.stringify({ ok: true, result }));
  } catch {
    console.log(JSON.stringify({ ok: false, error: 'Test operation rejected' }));
  }
}

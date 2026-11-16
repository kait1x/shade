// Generates canonical-text cross-vectors for the Dart device-v2 protocol port.
// Synthetic deterministic base64 blobs only — no real keys or user data.
// Run from the repo root: node client/tools/generate_v2_vectors.mjs
import { writeFileSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { genesisText, manifestText, messageText, requestText, pairingText,
  hash, fingerprint, deviceId } from '../web/protocol/device-v2.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
// Deterministic synthetic bytes; text builders only validate shape/base64.
const blob = (n, fill) => Buffer.alloc(n, fill).toString('base64');
const rootA = blob(294, 0x11), encB = blob(294, 0x22), sigB = blob(294, 0x33);
const recovery = blob(294, 0x44), k = blob(512, 0x55), d = blob(48, 0x66);
const nonce = 'ab'.repeat(32), op = 'cd'.repeat(32), idHex = 'ef'.repeat(32);
const now = 1763000000000;

async function main() {
  const devB = { id: await deviceId(encB, sigB), encryptionKey: encB, signingKey: sigB };
  const primary = { id: 'primary', encryptionKey: rootA, signingKey: rootA };
  const rootFingerprint = await fingerprint(rootA);

  const genesisLegacy = { version: 2, account: 'alice_android', nonce, createdAt: now,
    legacy: true, firstDevice: primary, recoveryKey: recovery, signature: '' };
  const genesisNew = { version: 2, account: 'bob_web', nonce, createdAt: now,
    legacy: false, firstDevice: devB, recoveryKey: recovery, signature: '' };

  const manifest1 = { account: 'alice_android', rootFingerprint, revision: 1, previous: '',
    issuedAt: now, expiresAt: now + 86400000, devices: [primary], signer: 'primary', signature: '' };
  const manifest2 = { account: 'alice_android', rootFingerprint, revision: 2,
    previous: await hash(manifestText(manifest1)), issuedAt: now + 1000, expiresAt: now + 86401000,
    devices: [devB, primary], signer: devB.id, signature: '' };

  const message = { version: 2, id: idHex, from: 'alice_android', deviceId: 'primary',
    to: 'bob_web', fromRevision: 2, toRevision: 1,
    fromDigest: await hash(manifestText(manifest2)), toDigest: await hash(manifestText(manifest1)),
    createdAt: now + 2000, envelopes: [
      { account: 'alice_android', deviceId: 'primary', payload: { k, d } },
      { account: 'bob_web', deviceId: devB.id, payload: { k, d } }], signature: '' };

  const ref = `${message.from}:${message.deviceId}:${message.id}`;
  const vectors = {
    note: 'Synthetic cross-vectors; canonical texts must match byte-for-byte in Dart.',
    fingerprint: [{ spki: rootA, hash: await fingerprint(rootA) }],
    deviceId: [{ encryptionKey: encB, signingKey: sigB, id: devB.id }],
    genesis: [], manifest: [], message: [], request: [], pairing: [], operation: [],
  };
  for (const g of [genesisLegacy, genesisNew]) {
    vectors.genesis.push({ input: g, text: genesisText(g), hash: await hash(genesisText(g)) });
  }
  for (const m of [manifest1, manifest2]) {
    vectors.manifest.push({ input: m, text: manifestText(m), hash: await hash(manifestText(m)) });
  }
  vectors.message.push({ input: message, text: messageText(message), hash: await hash(messageText(message)) });
  for (const id of ['primary', devB.id]) {
    const text = requestText('alice_android', id, nonce, op);
    vectors.request.push({ account: 'alice_android', id, nonce, operation: op, text, hash: await hash(text) });
  }
  const pairing = pairingText('alice_android', devB, nonce, now + 60000);
  vectors.pairing.push({ account: 'alice_android', device: devB, nonce, expiresAt: now + 60000,
    text: pairing, hash: await hash(pairing) });
  const ops = [['fetch', null], ['send', await hash(messageText(message))], ['ack', [ref]],
    ['status', [ref]], ['socket', null], ['directory', 'bob_web'], ['users', null],
    ['install', { manifest: manifest2, proofs: [], genesis: genesisLegacy }]];
  for (const [name, body] of ops) {
    const digest = await hash(JSON.stringify([name, body]));
    vectors.operation.push({ op: name, body, digest });
  }
  const out = path.join(here, '../test/assets/device_v2_vectors.json');
  mkdirSync(path.dirname(out), { recursive: true });
  writeFileSync(out, JSON.stringify(vectors, null, 2) + '\n');
  console.log(`Wrote ${out}`);
}
await main();
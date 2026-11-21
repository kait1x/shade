// Генерирует golden-векторы pairing-контракта для Dart-порта
// (client/lib/core/services/device_v2/pairing.dart).
// Векторы строятся ИЗ САМОГО client/web/pairing.mjs: канонические тексты,
// offer/confirmation-коды и подписи RSA-PSS SHA-256 (salt 32).
// Только синтетические тестовые ключи; приватные части в фикстуры не попадают.
// Запуск из корня репозитория: node client/tools/generate_pairing_vectors.mjs
import { writeFileSync, mkdirSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { generateKeyPairSync, webcrypto } from 'node:crypto';
import { genesisText, manifestText, pairingText, pairingTextV2,
  hash, fingerprint, deviceId, sign } from '../web/protocol/device-v2.mjs';
import { createPairingChallenge, buildPairingOffer, encodeOffer,
  buildPairingConfirmation, encodeConfirmation, OFFER_TTL_MS,
  CHALLENGE_TTL_MS } from '../web/pairing.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const now = 1763000000000;
const account = 'pair_golden';

function spkiOf(pair) {
  return pair.publicKey.export({ type: 'spki', format: 'der' }).toString('base64');
}
async function signingKeyOf(pair) {
  const der = pair.privateKey.export({ type: 'pkcs8', format: 'der' });
  return webcrypto.subtle.importKey('pkcs8', der,
    { name: 'RSA-PSS', hash: 'SHA-256' }, false, ['sign']);
}

async function main() {
  const rootPair = generateKeyPairSync('rsa', { modulusLength: 4096 });
  const devicePair = generateKeyPairSync('rsa', { modulusLength: 4096 });
  const recoveryPair = generateKeyPairSync('rsa', { modulusLength: 4096 });
  const root = spkiOf(rootPair);
  const encryptionKey = spkiOf(devicePair);
  // Независимый signing-ключ устройства: пара ключей не совпадает.
  const signingPair = generateKeyPairSync('rsa', { modulusLength: 4096 });
  const signingKey = spkiOf(signingPair);
  const device = { id: await deviceId(encryptionKey, signingKey), encryptionKey, signingKey };
  const primary = { id: 'primary', encryptionKey: root, signingKey: root };
  const rootSigning = await signingKeyOf(rootPair);
  const deviceSigning = await signingKeyOf(signingPair);

  // Одноразовый challenge доверенного устройства (фиксированное время).
  const challenge = createPairingChallenge(now);

  // Канонические тексты pairing-proof: v1 (legacy) и v2 (challenge-bound).
  const offerNonce = 'ab'.repeat(32);
  const offerExpiresAt = now + OFFER_TTL_MS;
  const textV1 = pairingText(account, device, offerNonce, offerExpiresAt);
  const textV2 = pairingTextV2(account, device, offerNonce, offerExpiresAt, challenge.nonce);

  // Подписанные offer обоих версий: подпись делает сам JS-контракт.
  const offerV2 = await buildPairingOffer({ account, device, signing: deviceSigning,
    challenge: challenge.nonce, now });
  const offerV1 = await buildPairingOffer({ account, device, signing: deviceSigning,
    challenge: challenge.nonce, now, version: 1 });

  // Genesis legacy-аккаунта и цепочка каталогов, подписанные корневым ключом.
  const genesis = { version: 2, account, nonce: 'cd'.repeat(32), createdAt: now - 1000,
    legacy: true, firstDevice: primary, recoveryKey: spkiOf(recoveryPair), signature: '' };
  genesis.signature = await sign(genesisText(genesis), rootSigning);
  const rootFingerprint = await fingerprint(root);
  const manifest1 = { account, rootFingerprint, revision: 1, previous: '',
    issuedAt: now, expiresAt: now + 86400000, devices: [primary], signer: 'primary', signature: '' };
  manifest1.signature = await sign(manifestText(manifest1), rootSigning);
  const sort = devices => [...devices].sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
  const tip = { account, rootFingerprint, revision: 2,
    previous: await hash(manifestText(manifest1)), issuedAt: now, expiresAt: now + 86400000,
    devices: sort([primary, device]), signer: 'primary', signature: '' };
  tip.signature = await sign(manifestText(tip), rootSigning);

  const confirmation = buildPairingConfirmation({ account, genesis, tip });

  const vectors = {
    note: 'Synthetic golden vectors generated from client/web/pairing.mjs; ' +
      'Dart must match canonical texts, codes and signatures byte-for-byte.',
    now, account,
    offerTtlMs: OFFER_TTL_MS, challengeTtlMs: CHALLENGE_TTL_MS,
    challenge: {
      code: challenge.code, nonce: challenge.nonce, expiresAt: challenge.expiresAt,
      mangledLowerSpaced: challenge.code.toLowerCase().split('').join(' '),
      mangledILO: challenge.code.replace(/1/g, 'I').replace(/0/g, 'O')
    },
    pairingTextV1: { account, device, nonce: offerNonce, expiresAt: offerExpiresAt,
      text: textV1, hash: await hash(textV1) },
    pairingTextV2: { account, device, nonce: offerNonce, expiresAt: offerExpiresAt,
      challenge: challenge.nonce, text: textV2, hash: await hash(textV2) },
    offerV2: { offer: offerV2, text: encodeOffer(offerV2), verifyNow: now + 1000 },
    offerV1: { offer: offerV1, text: encodeOffer(offerV1), verifyNow: now + 1000 },
    root, rootFingerprint,
    genesis, genesisDigest: await hash(genesisText(genesis)),
    manifest1, tip,
    deviceId: device.id,
    confirmation: { value: confirmation, text: encodeConfirmation(confirmation),
      verifyNow: now + 1000 }
  };
  const out = path.join(here, '../test/fixtures/pairing_vectors.json');
  mkdirSync(path.dirname(out), { recursive: true });
  writeFileSync(out, JSON.stringify(vectors, null, 2) + '\n');
  console.log(`Wrote ${out}`);
}
await main();
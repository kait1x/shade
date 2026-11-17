import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, sign as nodeSign, constants, randomBytes, createPublicKey } from 'node:crypto';
import { createDeviceRegistry, operationDigest, legacyRoot } from '../multidevice/registry.mjs';
import { createVault, unlockVault, descriptor, approveDevices, sealMessage, openMessage } from '../../client/web/device_crypto.mjs';
import { fingerprint, manifestText, messageText, sign, hash, requestText, pairingText,
  genesisText, verifyHistory, deviceId } from '../../client/web/protocol/device-v2.mjs';
import { createPairingChallenge, decodeChallenge, buildPairingOffer, encodeOffer, decodeOffer,
  verifyPairingOffer, buildPairingConfirmation, encodeConfirmation, decodeConfirmation,
  verifyPairingConfirmation, OFFER_TTL_MS } from '../../client/web/pairing.mjs';

// Second-device pairing: clipboard payloads (challenge/offer/confirmation)
// against the REAL registry model. Covers the full user flow — the trusted
// device approves, the newcomer bootstraps a device session, verifies the
// server directory and decrypts messages encrypted after the roster grew —
// plus the negative space (foreign/expired/tampered payloads).
const phrase = 'test-only high entropy vault passphrase 2026';
const newPhrase = 'test-only second device passphrase 2026abc';
let bob, vault, browser, gb, tip, registry, checkpoint;
const sort = devices => [...devices].sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
const copy = structuredClone;
const digestOf = async m => hash(manifestText(m));
function nativeSign(text, identity) {
  return nodeSign('sha256', Buffer.from(Buffer.from(text).toString('base64')),
    { key: identity.privateKey, padding: constants.RSA_PKCS1_PSS_PADDING, saltLength: 32 }).toString('base64');
}
async function webProof(v, keys, ttl = 60000) {
  const d = descriptor(v), nonce = randomBytes(32).toString('hex'), expiresAt = Date.now() + ttl;
  return { id: d.id, nonce, expiresAt, signature: await sign(pairingText('bob', d, nonce, expiresAt), keys.signing) };
}
async function auth(id, keys, operation) {
  const nonce = registry.challenge('bob', id, operation);
  return { account: 'bob', id, nonce, proof: await sign(requestText('bob', id, nonce, operation), keys.signing) };
}
async function makeSecondDevice(suffix) {
  const fresh = await createVault('bob', newPhrase + suffix);
  const session = await unlockVault(fresh, newPhrase + suffix);
  const challenge = createPairingChallenge();
  const offer = await buildPairingOffer({ account: 'bob', device: descriptor(fresh),
    signing: session.signing, challenge: challenge.nonce });
  return { fresh, session, challenge, offer };
}
before(async () => {
  const pair = generateKeyPairSync('rsa', { modulusLength: 4096 });
  const pem = pair.publicKey.export({ type: 'spki', format: 'pem' }).toString();
  bob = { ...pair, pem, root: legacyRoot(pem) };
  const recovery = legacyRoot(generateKeyPairSync('rsa', { modulusLength: 4096 })
    .publicKey.export({ type: 'spki', format: 'pem' }).toString());
  const g = { version: 2, account: 'bob', nonce: randomBytes(32).toString('hex'), createdAt: Date.now() - 1000,
    legacy: true, firstDevice: { id: 'primary', encryptionKey: bob.root, signingKey: bob.root },
    recoveryKey: recovery, signature: '' };
  g.signature = nativeSign(genesisText(g), bob);
  gb = g;
  vault = await createVault('bob', phrase);
  browser = await unlockVault(vault, phrase);
  registry = await createDeviceRegistry({ users: new Map([['bob', { publicKey: pem }]]), persist: async () => true });
  const m = { account: 'bob', rootFingerprint: await fingerprint(bob.root), revision: 1, previous: '',
    issuedAt: Date.now(), expiresAt: Date.now() + 86400000, signer: 'primary',
    devices: sort([{ id: 'primary', encryptionKey: bob.root, signingKey: bob.root }, descriptor(vault)]), signature: '' };
  m.signature = nativeSign(manifestText(m), bob);
  await registry.install(m, [await webProof(vault, browser)], g);
  tip = m;
  checkpoint = await verifyHistory([tip], bob.root, null, tip.issuedAt, gb);
});
test('challenge code survives clipboard mangling: case, spaces, dashes, I/L/O', () => {
  const challenge = createPairingChallenge();
  assert.equal(challenge.code, challenge.code.replace(/-/g, '').match(/.{6}/g).join('-'));
  assert.equal(decodeChallenge(challenge.code), challenge.nonce);
  assert.equal(decodeChallenge(challenge.code.toLowerCase().split('').join(' ')), challenge.nonce);
  assert.equal(decodeChallenge(challenge.code.replace(/1/g, 'I').replace(/0/g, 'O')), challenge.nonce);
  assert.throws(() => decodeChallenge('ABCD-EFGH'), /24 символов/);
  assert.throws(() => decodeChallenge('!'.repeat(24)), /символ|состоят|Некорректный/);
});
test('offer round-trips and verifies; foreign, stale, mistyped and oversized are rejected', async () => {
  const { offer } = await makeSecondDevice('a');
  const text = encodeOffer(offer);
  assert.deepEqual(decodeOffer(text), offer);
  assert.ok(OFFER_TTL_MS <= 300000);
  assert.equal((await verifyPairingOffer(offer, { account: 'bob', challenge: offer.challenge })).id,
    offer.device.id);
  await assert.rejects(verifyPairingOffer(offer, { account: 'alice', challenge: offer.challenge }),
    /другому аккаунту/);
  await assert.rejects(verifyPairingOffer(offer, { account: 'bob', challenge: 'f'.repeat(30) }),
    /Код подключения не совпадает/);
  await assert.rejects(verifyPairingOffer(offer, { account: 'bob', challenge: null }), /не совпадает|Input must be/);
  const stale = copy(offer); stale.expiresAt = Date.now() - 1;
  await assert.rejects(verifyPairingOffer(stale, { account: 'bob', challenge: offer.challenge }), /истёк/);
  const greedy = copy(offer); greedy.expiresAt = Date.now() + 600000;
  await assert.rejects(verifyPairingOffer(greedy, { account: 'bob', challenge: offer.challenge }), /допустимый/);
  const fake = copy(offer);
  fake.signature = await sign(pairingText('bob', offer.device, offer.nonce, offer.expiresAt), browser.signing);
  await assert.rejects(verifyPairingOffer(fake, { account: 'bob', challenge: offer.challenge }),
    /Подпись устройства недействительна/);
  const swapped = copy(offer);
  swapped.device = { ...offer.device, encryptionKey: descriptor(vault).encryptionKey };
  await assert.rejects(verifyPairingOffer(swapped, { account: 'bob', challenge: offer.challenge }),
    /Идентификатор устройства не совпадает/);
});
test('weak RSA keys cannot enter the roster through an offer', async () => {
  const weak = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const spki = weak.publicKey.export({ type: 'spki', format: 'der' }).toString('base64');
  const offer = { v: 1, account: 'bob', device: { id: await deviceId(spki, spki),
    encryptionKey: spki, signingKey: spki }, challenge: 'a'.repeat(30),
    nonce: randomBytes(32).toString('hex'), expiresAt: Date.now() + 60000, signature: 'AAAA' };
  await assert.rejects(verifyPairingOffer(offer, { account: 'bob', challenge: 'a'.repeat(30) }),
    /Unsupported RSA key/);
});
test('full pairing flow: approval installs the newcomer, replay is stale, session opens', async () => {
  const { fresh, session, offer } = await makeSecondDevice('b');
  await verifyPairingOffer(offer, { account: 'bob', challenge: offer.challenge });
  const manifest = await approveDevices(gb, [tip], [...tip.devices, offer.device], browser, checkpoint);
  assert.equal(manifest.revision, 2);
  assert.equal(manifest.signer, descriptor(vault).id);
  const proofs = [{ id: offer.device.id, nonce: offer.nonce, expiresAt: offer.expiresAt, signature: offer.signature }];
  assert.equal((await registry.install(manifest, proofs)).revision, 2);
  // Replay of the same revision must never resurrect or double-install.
  await assert.rejects(registry.install(manifest, proofs), /Stale/);
  // Confirmation round-trip and verification on the newcomer.
  const confirmText = encodeConfirmation(buildPairingConfirmation({ account: 'bob', genesis: gb, tip: manifest }));
  const confirmation = decodeConfirmation(confirmText);
  const verified = await verifyPairingConfirmation(confirmation, { account: 'bob', deviceId: descriptor(fresh).id });
  assert.equal(verified.root, bob.root);
  // Device-session bootstrap (the /api/v2/session/device contract).
  await registry.authorize(await auth(descriptor(fresh).id, session, await operationDigest('device-session')),
    await operationDigest('device-session'));
  // The newcomer verifies the FULL server directory against the pinned genesis.
  const dir = registry.directory('bob');
  assert.ok(dir.history.at(-1).devices.some(d => d.id === descriptor(fresh).id));
  await verifyHistory(dir.history, dir.root, null, Date.now(), dir.genesis);
});
test('confirmation rejects a foreign account, tampered genesis and a roster without the device', async () => {
  const good = buildPairingConfirmation({ account: 'bob', genesis: gb, tip });
  await assert.rejects(verifyPairingConfirmation({ ...copy(good), account: 'alice' },
    { account: 'bob', deviceId: 'a'.repeat(64) }), /другому аккаунту/);
  const tampered = copy(good);
  tampered.genesis = { ...gb, createdAt: gb.createdAt + 1 };
  await assert.rejects(verifyPairingConfirmation(tampered, { account: 'bob', deviceId: 'a'.repeat(64) }),
    /Invalid genesis signature/);
  await assert.rejects(verifyPairingConfirmation(copy(good), { account: 'bob', deviceId: 'b'.repeat(64) }),
    /отсутствует в подтверждённом ростере/);
});
test('after pairing both devices receive E2EE messages the newcomer can decrypt', async () => {
  const { fresh, session, offer } = await makeSecondDevice('c');
  // Build on the CURRENT roster (earlier tests already grew it), exactly as
  // the approving client does: refresh directory, verify, extend.
  const dir = registry.directory('bob');
  const current = await verifyHistory(dir.history, dir.root, null, dir.history.at(-1).issuedAt, dir.genesis);
  const manifest = await approveDevices(dir.genesis, dir.history,
    [...dir.history.at(-1).devices, offer.device], browser, current);
  await registry.install(manifest, [{ id: offer.device.id, nonce: offer.nonce,
    expiresAt: offer.expiresAt, signature: offer.signature }]);
  const history = [...dir.history, manifest];
  const trust = { senderRoot: bob.root, recipientRoot: bob.root, senderGenesis: gb, recipientGenesis: gb,
    senderCheckpoint: current, recipientCheckpoint: current };
  const m = await sealMessage('привет со второго устройства 🔐', history, history, browser, trust);
  await registry.send(m, await auth(descriptor(vault).id, browser,
    await operationDigest('send', await hash(messageText(m)))));
  const bundles = await registry.fetch(await auth(descriptor(fresh).id, session, await operationDigest('fetch')));
  assert.equal(bundles.length, 1);
  assert.equal(await openMessage(bundles[0], session, trust), 'привет со второго устройства 🔐');
  const own = await registry.fetch(await auth(descriptor(vault).id, browser, await operationDigest('fetch')));
  assert.equal(own.length, 1);
});

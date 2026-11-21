import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, sign as nodeSign, constants, randomBytes } from 'node:crypto';
import { createDeviceRegistry, operationDigest, legacyRoot } from '../multidevice/registry.mjs';
import { createVault, unlockVault, descriptor, approveDevices, sealMessage, openMessage } from '../../client/web/device_crypto.mjs';
import { fingerprint, manifestText, messageText, sign, hash, requestText, pairingText, pairingTextV2,
  genesisText, verifyHistory, deviceId } from '../../client/web/protocol/device-v2.mjs';
import { createPairingChallenge, buildPairingOffer, encodeOffer, decodeOffer,
  verifyPairingOffer, buildPairingConfirmation, encodeConfirmation, decodeConfirmation,
  verifyPairingConfirmation } from '../../client/web/pairing.mjs';

// Challenge-binding (security review 18.11, High): the one-time challenge is
// part of the signed pairing text (pairingTextV2 / offer shade-pair-v2:).
// Negatives: challenge mutation, key swap, downgrade, malformed proofs, TTL,
// weak RSA. Compatibility: v1 offers/proofs during the transition window,
// owner cutoff (pairingV1:false) rejects roster growth but not genesis.
const phrase = 'test-only high entropy vault passphrase 2026';
const newPhrase = 'test-only second device passphrase 2026abc';
let bob, vault, browser, gb, tip, registry, checkpoint;
const sort = devices => [...devices].sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
const copy = structuredClone;
const proofOf = offer => ({ id: offer.device.id, nonce: offer.nonce,
  expiresAt: offer.expiresAt, signature: offer.signature,
  ...(offer.v === 2 ? { challenge: offer.challenge, pairingVersion: 2 } : {}) });
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
async function makeSecondDevice(suffix, version = 2) {
  const fresh = await createVault('bob', newPhrase + suffix);
  const session = await unlockVault(fresh, newPhrase + suffix);
  const challenge = createPairingChallenge();
  const offer = await buildPairingOffer({ account: 'bob', device: descriptor(fresh),
    signing: session.signing, challenge: challenge.nonce, version });
  return { fresh, session, challenge, offer };
}
async function genesisFor(keyPair) {
  const pem = keyPair.publicKey.export({ type: 'spki', format: 'pem' }).toString();
  const root = legacyRoot(pem);
  const recovery = legacyRoot(generateKeyPairSync('rsa', { modulusLength: 4096 })
    .publicKey.export({ type: 'spki', format: 'pem' }).toString());
  const g = { version: 2, account: 'bob', nonce: randomBytes(32).toString('hex'), createdAt: Date.now() - 1000,
    legacy: true, firstDevice: { id: 'primary', encryptionKey: root, signingKey: root },
    recoveryKey: recovery, signature: '' };
  g.signature = nativeSign(genesisText(g), keyPair);
  return { pem, root, g };
}
before(async () => {
  const pair = generateKeyPairSync('rsa', { modulusLength: 4096 });
  const { pem, root, g } = await genesisFor(pair);
  bob = { ...pair, pem, root }; gb = g;
  vault = await createVault('bob', phrase);
  browser = await unlockVault(vault, phrase);
  registry = await createDeviceRegistry({ users: new Map([['bob', { publicKey: pem }]]), persist: async () => true });
  const m = { account: 'bob', rootFingerprint: await fingerprint(root), revision: 1, previous: '',
    issuedAt: Date.now(), expiresAt: Date.now() + 86400000, signer: 'primary',
    devices: sort([{ id: 'primary', encryptionKey: root, signingKey: root }, descriptor(vault)]), signature: '' };
  m.signature = nativeSign(manifestText(m), bob);
  await registry.install(m, [await webProof(vault, browser)], g);
  tip = m;
  checkpoint = await verifyHistory([tip], root, null, tip.issuedAt, gb);
});
test('v2 offer round-trips with the v2 prefix and verifies against its challenge', async () => {
  const { offer } = await makeSecondDevice('a');
  assert.equal(offer.v, 2);
  const text = encodeOffer(offer);
  assert.ok(text.startsWith('shade-pair-v2:'));
  assert.deepEqual(decodeOffer(text), offer);
  assert.equal((await verifyPairingOffer(offer, { account: 'bob', challenge: offer.challenge })).id, offer.device.id);
});
test('mutating the challenge without re-signing invalidates the v2 signature (High fix)', async () => {
  const { offer } = await makeSecondDevice('b');
  const mutated = copy(offer);
  mutated.challenge = randomBytes(15).toString('hex');
  // Echo comparison alone would pass with the mutated challenge as expectation;
  // the signature must fail because the challenge is inside the signed text.
  await assert.rejects(verifyPairingOffer(mutated, { account: 'bob', challenge: mutated.challenge }),
    /Подпись устройства недействительна/);
  await assert.rejects(verifyPairingOffer(mutated, { account: 'bob', challenge: offer.challenge }),
    /Код подключения не совпадает/);
  // Re-signing over the UNBOUND v1 text must not verify a v2 offer either.
  const downgraded = copy(offer);
  downgraded.signature = await sign(pairingText('bob', offer.device, offer.nonce, offer.expiresAt), browser.signing);
  await assert.rejects(verifyPairingOffer(downgraded, { account: 'bob', challenge: offer.challenge }),
    /Подпись устройства недействительна/);
});
test('swapping device keys with the same challenge invalidates the v2 signature', async () => {
  const { offer } = await makeSecondDevice('c');
  const other = await createVault('bob', newPhrase + 'c2');
  const swapped = copy(offer);
  swapped.device = descriptor(other);
  await assert.rejects(verifyPairingOffer(swapped, { account: 'bob', challenge: offer.challenge }),
    /Подпись устройства недействительна/);
});
test('v1 offers stay readable and verifiable during the transition window', async () => {
  const { offer } = await makeSecondDevice('d', 1);
  assert.equal(offer.v, 1);
  const text = encodeOffer(offer);
  assert.ok(text.startsWith('shade-pair-v1:'));
  assert.deepEqual(decodeOffer(text), offer);
  assert.equal((await verifyPairingOffer(offer, { account: 'bob', challenge: offer.challenge })).id, offer.device.id);
});
test('offer prefix and version must agree', async () => {
  const { offer } = await makeSecondDevice('e');
  const v2text = encodeOffer(offer);
  assert.throws(() => decodeOffer('shade-pair-v1:' + v2text.slice('shade-pair-v2:'.length)),
    /Неверный формат кода подключения/);
  const v1text = encodeOffer({ ...offer, v: 1 });
  assert.throws(() => decodeOffer('shade-pair-v2:' + v1text.slice('shade-pair-v1:'.length)),
    /Неверный формат/);
});
test('v2 TTL and weak-RSA negatives mirror v1', async () => {
  const { offer } = await makeSecondDevice('f');
  const stale = copy(offer); stale.expiresAt = Date.now() - 1;
  await assert.rejects(verifyPairingOffer(stale, { account: 'bob', challenge: offer.challenge }), /истёк/);
  const greedy = copy(offer); greedy.expiresAt = Date.now() + 600000;
  await assert.rejects(verifyPairingOffer(greedy, { account: 'bob', challenge: offer.challenge }), /допустимый/);
  const weak = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const spki = weak.publicKey.export({ type: 'spki', format: 'der' }).toString('base64');
  const weakOffer = { v: 2, account: 'bob', device: { id: await deviceId(spki, spki),
    encryptionKey: spki, signingKey: spki }, challenge: 'a'.repeat(30),
    nonce: randomBytes(32).toString('hex'), expiresAt: Date.now() + 60000, signature: 'AAAA' };
  await assert.rejects(verifyPairingOffer(weakOffer, { account: 'bob', challenge: 'a'.repeat(30) }),
    /Unsupported RSA key/);
});
test('registry accepts v2 proofs; downgrade and malformed proofs are rejected', async () => {
  const { offer } = await makeSecondDevice('g');
  const manifest = await approveDevices(gb, [tip], [...tip.devices, offer.device], browser, checkpoint);
  assert.equal((await registry.install(manifest, [proofOf(offer)])).revision, 2);
  await assert.rejects(registry.install(manifest, [proofOf(offer)]), /Stale/);
  // Downgrade: declared v2 but signature over the unbound v1 text.
  const { offer: offer2 } = await makeSecondDevice('h');
  const dir = registry.directory('bob');
  const current = await verifyHistory(dir.history, dir.root, null, dir.history.at(-1).issuedAt, dir.genesis);
  const m2 = await approveDevices(dir.genesis, dir.history,
    [...dir.history.at(-1).devices, offer2.device], browser, current);
  const down = { ...proofOf(offer2),
    signature: await sign(pairingText('bob', offer2.device, offer2.nonce, offer2.expiresAt), browser.signing) };
  await assert.rejects(registry.install(m2, [down]), /Invalid pairing possession proof/);
  // Challenge present without the version declaration is ambiguous → reject.
  const ambiguous = { id: offer2.device.id, nonce: offer2.nonce, expiresAt: offer2.expiresAt,
    signature: offer2.signature, challenge: offer2.challenge };
  await assert.rejects(registry.install(m2, [ambiguous]), /Invalid pairing proof version/);
  // Declared v2 with a malformed challenge → reject before any verify.
  const malformed = { ...proofOf(offer2), challenge: 'zz' };
  await assert.rejects(registry.install(m2, [malformed]), /Invalid pairing challenge/);
  // The honest v2 proof still installs after the rejected attempts.
  assert.equal((await registry.install(m2, [proofOf(offer2)])).revision, 3);
});
test('cutoff: pairingV1=false rejects v1 roster growth but not genesis or v2', async () => {
  const pair = generateKeyPairSync('rsa', { modulusLength: 4096 });
  const { pem, root, g } = await genesisFor(pair);
  const strict = await createDeviceRegistry({ users: new Map([['bob', { publicKey: pem }]]),
    persist: async () => true, pairingV1: false });
  const v = await createVault('bob', phrase);
  const s = await unlockVault(v, phrase);
  const m = { account: 'bob', rootFingerprint: await fingerprint(root), revision: 1, previous: '',
    issuedAt: Date.now(), expiresAt: Date.now() + 86400000, signer: 'primary',
    devices: sort([{ id: 'primary', encryptionKey: root, signingKey: root }, descriptor(v)]), signature: '' };
  m.signature = nativeSign(manifestText(m), { ...pair, root });
  // Genesis enrollment has no trusted-device challenge: v1 proof stays valid.
  await strict.install(m, [await webProof(v, s)], g);
  const cp = await verifyHistory([m], root, null, m.issuedAt, g);
  const { offer } = await makeSecondDevice('i');
  const m2 = await approveDevices(g, [m], [...m.devices, offer.device], s, cp);
  const v1proof = { id: offer.device.id, nonce: offer.nonce, expiresAt: offer.expiresAt,
    signature: await sign(pairingText('bob', offer.device, offer.nonce, offer.expiresAt), s.signing) };
  await assert.rejects(strict.install(m2, [v1proof]), /Pairing v1 proofs are disabled/);
  assert.equal((await strict.install(m2, [proofOf(offer)])).revision, 2);
});
test('full v2 flow: session bootstrap, directory verification, E2EE fanout', async () => {
  const { fresh, session, offer } = await makeSecondDevice('j');
  const dir = registry.directory('bob');
  const current = await verifyHistory(dir.history, dir.root, null, dir.history.at(-1).issuedAt, dir.genesis);
  const manifest = await approveDevices(dir.genesis, dir.history,
    [...dir.history.at(-1).devices, offer.device], browser, current);
  await registry.install(manifest, [proofOf(offer)]);
  const confirmText = encodeConfirmation(buildPairingConfirmation({ account: 'bob', genesis: gb, tip: manifest }));
  const verified = await verifyPairingConfirmation(decodeConfirmation(confirmText),
    { account: 'bob', deviceId: descriptor(fresh).id });
  assert.equal(verified.root, bob.root);
  await registry.authorize(await auth(descriptor(fresh).id, session, await operationDigest('device-session')),
    await operationDigest('device-session'));
  const full = registry.directory('bob');
  await verifyHistory(full.history, full.root, null, Date.now(), full.genesis);
  assert.ok(full.history.at(-1).devices.some(d => d.id === descriptor(fresh).id));
  const history = [...full.history];
  const trust = { senderRoot: bob.root, recipientRoot: bob.root, senderGenesis: gb, recipientGenesis: gb,
    senderCheckpoint: current, recipientCheckpoint: current };
  const m = await sealMessage('challenge-bound pairing 🔐', history, history, browser, trust);
  await registry.send(m, await auth(descriptor(vault).id, browser,
    await operationDigest('send', await hash(messageText(m)))));
  const bundles = await registry.fetch(await auth(descriptor(fresh).id, session, await operationDigest('fetch')));
  assert.equal(bundles.length, 1);
  assert.equal(await openMessage(bundles[0], session, trust), 'challenge-bound pairing 🔐');
});
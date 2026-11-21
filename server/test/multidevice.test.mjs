import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, sign as nodeSign, privateDecrypt, constants, createDecipheriv, randomBytes } from 'node:crypto';
import { createDeviceRegistry, legacyRoot, operationDigest, messageRef } from '../multidevice/registry.mjs';
import { createVault, unlockVault, descriptor, sealMessage, openMessage, encryptRecord, decryptRecord, approveDevices } from '../../client/web/device_crypto.mjs';
import { fingerprint, manifestText, messageText, sign, hash, requestText, pairingText,
  verifyManifest, acceptManifest, verifyHistory, genesisText } from '../../client/web/protocol/device-v2.mjs';

const phrase = 'test-only high entropy vault passphrase 2026';
let alice, bob, vault, browser, recovery, ga, gb;
const copy = structuredClone;
const sort = devices => [...devices].sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
function nativeIdentity() {
  const pair = generateKeyPairSync('rsa', { modulusLength: 4096 });
  const pem = pair.publicKey.export({ type: 'spki', format: 'pem' }).toString();
  return { ...pair, pem, root: legacyRoot(pem) };
}
function nativeSign(text, identity) {
  return nodeSign('sha256', Buffer.from(Buffer.from(text).toString('base64')),
    { key: identity.privateKey, padding: constants.RSA_PKCS1_PSS_PADDING, saltLength: 32 }).toString('base64');
}
function nativeDecrypt(payload, identity) {
  const packed = Buffer.from(privateDecrypt({ key: identity.privateKey, oaepHash: 'sha256' }, Buffer.from(payload.k, 'base64')).toString(), 'base64');
  assert.equal(packed.length, 45); assert.equal(packed[0], 2);
  const bytes = Buffer.from(payload.d, 'base64');
  const aes = createDecipheriv('aes-256-gcm', packed.subarray(1, 33), packed.subarray(33));
  aes.setAuthTag(bytes.subarray(-16));
  return Buffer.concat([aes.update(bytes.subarray(0, -16)), aes.final()]).toString();
}
async function roster(account, identity, devices, previous, now = Date.now()) {
  const m = { account, rootFingerprint: await fingerprint(identity.root),
    revision: (previous?.revision || 0) + 1, previous: previous ? await hash(manifestText(previous)) : '',
    issuedAt: now, expiresAt: now + 86400000,
    signer: 'primary', devices: sort([{ id: 'primary', encryptionKey: identity.root, signingKey: identity.root }, ...devices]), signature: '' };
  m.signature = nativeSign(manifestText(m), identity); return m;
}
async function proof(account = 'bob', v = vault, keys = browser) {
  const d = descriptor(v), nonce = randomBytes(32).toString('hex'), expiresAt = Date.now() + 60000;
  return { id: d.id, nonce, expiresAt, signature: await sign(pairingText(account, d, nonce, expiresAt), keys.signing) };
}
async function auth(registry, account, id, operation, identity) {
  const nonce = registry.challenge(account, id, operation);
  const text = requestText(account, id, nonce, operation);
  return { account, id, nonce, proof: id === 'primary' ? nativeSign(text, identity) : await sign(text, browser.signing) };
}
async function fixture() {
  const legacyUsers = new Map([['alice', { publicKey: alice.pem, encryptedHistory: 'untouched-A' }],
    ['bob', { publicKey: bob.pem, encryptedHistory: 'untouched-B' }]]);
  const original = copy(legacyUsers);
  let saved, fail = false;
  const persist = async value => { if (fail) throw new Error('disk full'); saved = copy(value); };
  const registry = await createDeviceRegistry({ users: legacyUsers, persist });
  const a = await roster('alice', alice, []), b = await roster('bob', bob, [descriptor(vault)]);
  await registry.install(a, [], ga);
  await registry.install(b, [await proof()], gb);
  return { registry, a, b, legacyUsers, original, persist,
    failSave: value => { fail = value; }, saved: () => saved,
    trust: { senderRoot: alice.root, recipientRoot: bob.root, senderGenesis: ga, recipientGenesis: gb } };
}
async function nativeMessage(f, text = 'Android → iPhone 🔐') {
  const { encryptLegacy } = await import('../../client/web/device_crypto.mjs');
  const m = { version: 2, id: randomBytes(32).toString('hex'), from: 'alice', deviceId: 'primary', to: 'bob',
    fromRevision: f.a.revision, toRevision: f.b.revision, fromDigest: await hash(manifestText(f.a)),
    toDigest: await hash(manifestText(f.b)), createdAt: Date.now(), envelopes: [], signature: '' };
  for (const roster of [f.a, f.b]) {
    for (const d of roster.devices) m.envelopes.push({ account: roster.account, deviceId: d.id, payload: await encryptLegacy(text, d.encryptionKey) });
  }
  m.signature = nativeSign(messageText(m), alice); return m;
}
async function send(f, m) {
  return f.registry.send(m, await auth(f.registry, m.from, m.deviceId,
    await operationDigest('send', await hash(messageText(m))), m.from === 'alice' ? alice : bob));
}
before(async () => {
  alice = nativeIdentity(); bob = nativeIdentity(); recovery = nativeIdentity();
  async function genesis(account, identity) {
    const g = { version: 2, account, nonce: randomBytes(32).toString('hex'), createdAt: Date.now() - 1000, legacy: true,
      firstDevice: { id: 'primary', encryptionKey: identity.root, signingKey: identity.root }, recoveryKey: recovery.root, signature: '' };
    g.signature = nativeSign(genesisText(g), identity); return g;
  }
  ga = await genesis('alice', alice); gb = await genesis('bob', bob);
  vault = await createVault('bob', phrase); browser = await unlockVault(vault, phrase);
});

test('additive migration preserves users, roots and opaque legacy ciphertext byte for byte', async () => {
  const f = await fixture(); assert.deepEqual(f.legacyUsers, f.original);
  assert.equal(f.registry.directory('alice').root, alice.root);
  assert.throws(() => f.registry.assertLegacyAllowed('bob'), /upgrade/);
  f.registry.assertLegacyAllowed('carol');
});
test('v1 accounts stay on v1 until explicitly root-approved', async () => {
  const users = new Map([['alice', { publicKey: alice.pem }]]);
  const r = await createDeviceRegistry({ users, persist: async () => true });
  r.assertLegacyAllowed('alice'); assert.deepEqual(r.directory('alice').history, []);
});
test('an older RSA size remains on v1 without stopping migration inspection or rewriting keys', async () => {
  const old = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const pem = old.publicKey.export({ type: 'spki', format: 'pem' }).toString();
  const users = new Map([['older_account', { publicKey: pem, encryptedHistory: 'preserved' }]]);
  const original = copy(users);
  const registry = await createDeviceRegistry({ users, persist: async () => true });
  registry.assertLegacyAllowed('older_account');
  assert.deepEqual(users, original);
  const normalized = registry.directory('older_account').root;
  const { publicKey } = await import('../../client/web/protocol/device-v2.mjs');
  await assert.rejects(publicKey(normalized, 'RSA-PSS', 'verify'), /Unsupported RSA/);
});
test('root-signed full roster and fresh device possession are both mandatory', async () => {
  const r = await createDeviceRegistry({ users: new Map([['bob', { publicKey: bob.pem }]]), persist: async () => true });
  const m = await roster('bob', bob, [descriptor(vault)]);
  await assert.rejects(r.install(m, [], gb), /pairing/);
  const bad = await proof(); bad.signature = nativeSign('fake', alice);
  await assert.rejects(r.install(m, [bad], gb), /possession/);
  const expired = await proof(); expired.expiresAt = Date.now() - 1;
  await assert.rejects(r.install(m, [expired], gb), /Fresh/);
  await r.install(m, [await proof()], gb);
});
test('Google identity, a stolen legacy bearer token, or a device key cannot approve devices', async () => {
  const f = await fixture(); const m = await roster('bob', bob, [], f.b);
  m.signature = await sign(manifestText(m), browser.signing);
  await assert.rejects(f.registry.install(m), /root approval/);
  m.signature = 'google-id-token'; await assert.rejects(f.registry.install(m), /root approval/);
});
test('root/key substitution, duplicate devices and account substitution fail', async () => {
  const f = await fixture();
  const swapped = await roster('bob', alice, [], f.b);
  await assert.rejects(f.registry.install(swapped), /Root identity/);
  const changed = copy(f.b); changed.devices[0].encryptionKey = alice.root;
  await assert.rejects(verifyManifest(changed, bob.root), /mismatch/);
  const duplicated = copy(f.b); duplicated.devices.push(duplicated.devices[0]);
  await assert.rejects(verifyManifest(duplicated, bob.root), /Duplicate/);
  const wrongAccount = copy(f.b); wrongAccount.account = 'alice';
  wrongAccount.revision = 2; wrongAccount.previous = await hash(manifestText(f.a));
  await assert.rejects(f.registry.install(wrongAccount), /Root identity/);
});
test('native-format signed message fans out to Android root and Web device; ack is device-scoped', async () => {
  const f = await fixture(), m = await nativeMessage(f);
  assert.equal((await send(f, m)).accepted, true);
  const webInbox = await f.registry.fetch(await auth(f.registry, 'bob', browser.id, await operationDigest('fetch')));
  assert.equal(await openMessage(webInbox[0], browser, f.trust), 'Android → iPhone 🔐');
  assert.equal(nativeDecrypt(m.envelopes.find(e => e.account === 'bob' && e.deviceId === 'primary').payload, bob), 'Android → iPhone 🔐');
  await f.registry.acknowledge([messageRef(m)], await auth(f.registry, 'bob', browser.id, await operationDigest('ack', [messageRef(m)])));
  assert.equal((await f.registry.fetch(await auth(f.registry, 'bob', browser.id, await operationDigest('fetch')))).length, 0);
  assert.equal((await f.registry.fetch(await auth(f.registry, 'bob', 'primary', await operationDigest('fetch'), bob))).length, 1);
});
test('Web signed ciphertext is readable by native RSA-OAEP/AES-GCM and the relay cannot decrypt it', async () => {
  const f = await fixture();
  const m = await sealMessage('iPhone → Android 🔐', [f.b], [f.a], browser,
    { senderRoot: bob.root, recipientRoot: alice.root, senderGenesis: gb, recipientGenesis: ga });
  await send(f, m);
  assert.equal(nativeDecrypt(m.envelopes[0].payload, alice), 'iPhone → Android 🔐');
  assert.throws(() => nativeDecrypt(m.envelopes[0].payload, bob));
  assert.equal(JSON.stringify(f.saved()).includes('iPhone → Android'), false);
});
test('tampered ciphertext, missing fanout, forged sender and recipient substitution are rejected', async () => {
  const f = await fixture(), m = await nativeMessage(f);
  const tampered = copy(m); tampered.envelopes[0].payload.d = Buffer.alloc(32).toString('base64');
  await assert.rejects(send(f, tampered), /signature/);
  const missing = copy(m); missing.envelopes.pop(); missing.signature = nativeSign(messageText(missing), alice);
  await assert.rejects(send(f, missing), /fanout/);
  const impersonation = copy(m); impersonation.signature = nativeSign(messageText(m), bob);
  await assert.rejects(send(f, impersonation), /signature/);
});
test('directory rollback, same-revision fork, stale fanout and replayed enrollment fail', async () => {
  const f = await fixture(), m = await nativeMessage(f);
  const checkpoint = await acceptManifest(f.b, bob.root);
  const next = await roster('bob', bob, [], f.b); await f.registry.install(next);
  const newPin = await acceptManifest(next, bob.root, checkpoint);
  await assert.rejects(acceptManifest(f.b, bob.root, newPin), /rollback/);
  await assert.rejects(verifyHistory([f.b], bob.root, newPin), /rollback/);
  const fork = await roster('bob', bob, [descriptor(vault)], undefined, f.b.issuedAt + 1);
  await assert.rejects(acceptManifest(fork, bob.root, checkpoint), /fork/);
  await assert.rejects(send(f, m), /Stale/);
  await assert.rejects(f.registry.install(next), /Stale/);
});
test('signed challenge is single-use, operation-bound and account/device-bound', async () => {
  const f = await fixture();
  const a = await auth(f.registry, 'bob', browser.id, await operationDigest('fetch'));
  await f.registry.fetch(a); await assert.rejects(f.registry.fetch(a), /replayed/);
  const b = await auth(f.registry, 'bob', browser.id, await operationDigest('ack', []));
  await assert.rejects(f.registry.fetch(b), /challenge/);
  const c = await auth(f.registry, 'bob', browser.id, await operationDigest('fetch'));
  c.account = 'alice'; await assert.rejects(f.registry.fetch(c), /challenge/);
});
test('revocation invalidates outstanding challenges, purges queued copies and prevents ID resurrection', async () => {
  const f = await fixture(); await send(f, await nativeMessage(f));
  const oldAuth = await auth(f.registry, 'bob', browser.id, await operationDigest('fetch'));
  const revoked = await roster('bob', bob, [], f.b); await f.registry.install(revoked);
  await assert.rejects(f.registry.fetch(oldAuth), /Revoked/);
  assert.throws(() => f.registry.challenge('bob', browser.id, '0'.repeat(64)), /Revoked/);
  assert.equal(f.registry.exportSnapshot().queues[`bob:${browser.id}`].length, 0);
  const restored = await roster('bob', bob, [descriptor(vault)], revoked);
  await assert.rejects(f.registry.install(restored, [await proof()]), /cannot be reused|resurrected/);
});
test('revoked sender queued messages are removed; future messages require fresh per-device ciphertext', async () => {
  const f = await fixture();
  const m = await sealMessage('queued before revoke', [f.b], [f.a], browser,
    { senderRoot: bob.root, recipientRoot: alice.root, senderGenesis: gb, recipientGenesis: ga });
  await send(f, m);
  await f.registry.install(await roster('bob', bob, [], f.b));
  assert.equal((await f.registry.fetch(await auth(f.registry, 'alice', 'primary', await operationDigest('fetch'), alice))).length, 0);
});
test('disk failure rolls back enrollment, queues and receipts; retry is idempotent', async () => {
  const f = await fixture(), m = await nativeMessage(f), old = f.registry.exportSnapshot();
  f.failSave(true); await assert.rejects(send(f, m), /disk full/);
  assert.deepEqual(f.registry.exportSnapshot(), old);
  const revoked = await roster('bob', bob, [], f.b);
  await assert.rejects(f.registry.install(revoked), /disk full/);
  assert.deepEqual(f.registry.exportSnapshot(), old);
  f.failSave(false); await send(f, m);
  assert.equal((await send(f, m)).duplicate, true);
});
test('concurrent directory updates use compare-and-swap; only one revision wins', async () => {
  const f = await fixture();
  const one = await roster('bob', bob, [], f.b), two = await roster('bob', bob, [descriptor(vault)], f.b);
  const results = await Promise.allSettled([f.registry.install(one), f.registry.install(two)]);
  assert.equal(results.filter(r => r.status === 'fulfilled').length, 1);
});
test('restart restores per-device delivery without changing legacy roots or history', async () => {
  const f = await fixture(), m = await nativeMessage(f); await send(f, m);
  const restarted = await createDeviceRegistry({ users: f.legacyUsers, persist: f.persist, snapshot: f.saved() });
  const messages = await restarted.fetch(await auth(restarted, 'bob', browser.id, await operationDigest('fetch')));
  assert.equal(await openMessage(messages[0], browser, f.trust), 'Android → iPhone 🔐');
  assert.deepEqual(f.legacyUsers, f.original);
  const corrupt = f.saved(); corrupt.accounts.bob.root = alice.root;
  await assert.rejects(createDeviceRegistry({ users: f.legacyUsers, persist: f.persist, snapshot: corrupt }), /substitution/);
});
test('vault and local checkpoints survive unlock; wrong password and metadata tampering fail closed', async () => {
  const serialized = JSON.stringify(vault);
  assert.equal(serialized.includes('PRIVATE KEY'), false); assert.equal(serialized.includes(phrase), false);
  const restored = await unlockVault(JSON.parse(serialized), phrase);
  assert.equal(restored.encryption.extractable, false); assert.equal(restored.signing.extractable, false);
  await assert.rejects(crypto.subtle.exportKey('pkcs8', restored.encryption));
  await assert.rejects(unlockVault(vault, 'wrong password'));
  const tampered = copy(vault); tampered.account = 'alice'; await assert.rejects(unlockVault(tampered, phrase));
  const record = await encryptRecord(restored, 'directory:bob', { revision: 7, secret: 'checkpoint-data' });
  assert.deepEqual(await decryptRecord(restored, 'directory:bob', record), { revision: 7, secret: 'checkpoint-data' });
  await assert.rejects(decryptRecord(restored, 'directory:alice', record));
});
test('expired directory leases and broken signed history stop sending', async () => {
  const f = await fixture();
  await assert.rejects(verifyManifest(f.b, bob.root, f.b.expiresAt), /Expired/);
  const next = await roster('bob', bob, [], f.b);
  const skipped = copy(next); skipped.revision = 3; skipped.signature = nativeSign(manifestText(skipped), bob);
  await assert.rejects(verifyHistory([f.b, skipped], bob.root), /chain/);
});
test('ACK cannot erase another sender/device message that deliberately reuses the same ID', async () => {
  const f = await fixture(), incoming = await nativeMessage(f);
  await send(f, incoming);
  const outgoing = await sealMessage('same ID, another sender', [f.b], [f.a], browser,
    { senderRoot: bob.root, recipientRoot: alice.root, senderGenesis: gb, recipientGenesis: ga });
  outgoing.id = incoming.id; outgoing.signature = await sign(messageText(outgoing), browser.signing);
  await send(f, outgoing);
  const refs = [messageRef(outgoing)];
  await f.registry.acknowledge(refs, await auth(f.registry, 'bob', browser.id, await operationDigest('ack', refs)));
  const inbox = await f.registry.fetch(await auth(f.registry, 'bob', browser.id, await operationDigest('fetch')));
  assert.equal(inbox.length, 1); assert.equal(inbox[0].message.from, 'alice');
});
test('legacy Android identity remains an immutable anchor but can be revoked as an active device', async () => {
  const f = await fixture();
  const next = await approveDevices(gb, [f.b], [descriptor(vault)], browser);
  await f.registry.install(next);
  assert.equal(f.registry.directory('bob').root, bob.root);
  assert.throws(() => f.registry.challenge('bob', 'primary', '0'.repeat(64)), /Revoked/);
  assert.deepEqual(f.legacyUsers, f.original);
  const m = await sealMessage('Web without the original Android controller', [f.b, next], [f.a], browser,
    { senderRoot: bob.root, recipientRoot: alice.root, senderGenesis: gb, recipientGenesis: ga });
  await send(f, m);
  assert.equal(nativeDecrypt(m.envelopes.find(e => e.account === 'alice').payload, alice), 'Web without the original Android controller');
});

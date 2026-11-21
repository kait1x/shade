// Lossless rollback journal: integration tests proving that restoring an OLDER
// snapshot while replaying the NEWER live state preserves post-backup messages,
// ACKs, read state, retractions and directory revisions — and that conflicts
// fail closed without touching the target store.
import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { generateKeyPairSync, sign as nodeSign, constants, randomBytes, createHash, createPublicKey } from 'node:crypto';
import { createDeviceRegistry, legacyRoot, operationDigest, messageRef } from '../multidevice/registry.mjs';
import { alphaStore } from '../multidevice/alpha-store.mjs';
import { mergeRollbackSnapshots } from '../multidevice/rollback-journal.mjs';
import { createVault, unlockVault, descriptor, encryptLegacy } from '../../client/web/device_crypto.mjs';
import { fingerprint, manifestText, messageText, sign, hash, requestText, pairingText, genesisText } from '../../client/web/protocol/device-v2.mjs';

const serverRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const CLI = path.join(serverRoot, 'tools', 'migrate-v1-to-v2.mjs');
const SECRET = 'synthetic rollback journal test secret 32+';
const phrase = 'test-only high entropy vault passphrase 2026';
const copy = structuredClone;
const sort = devices => [...devices].sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0);

let alice, bob, recovery, vault, browser, vault2, browser2, ga, gb;
function nativeIdentity() {
  const pair = generateKeyPairSync('rsa', { modulusLength: 4096 });
  const pem = pair.publicKey.export({ type: 'spki', format: 'pem' }).toString();
  return { ...pair, pem, root: legacyRoot(pem) };
}
function nativeSign(text, identity) {
  return nodeSign('sha256', Buffer.from(Buffer.from(text).toString('base64')),
    { key: identity.privateKey, padding: constants.RSA_PKCS1_PSS_PADDING, saltLength: 32 }).toString('base64');
}
async function roster(account, identity, devices, previous, now = Date.now()) {
  const m = { account, rootFingerprint: await fingerprint(identity.root),
    revision: (previous?.revision || 0) + 1, previous: previous ? await hash(manifestText(previous)) : '',
    issuedAt: now, expiresAt: now + 86400000,
    signer: 'primary', devices: sort([{ id: 'primary', encryptionKey: identity.root, signingKey: identity.root }, ...devices]), signature: '' };
  m.signature = nativeSign(manifestText(m), identity); return m;
}
async function pairing(account, v, keys) {
  const d = descriptor(v), nonce = randomBytes(32).toString('hex'), expiresAt = Date.now() + 60000;
  return { id: d.id, nonce, expiresAt, signature: await sign(pairingText(account, d, nonce, expiresAt), keys.signing) };
}
async function auth(registry, account, id, operation, identity, keys) {
  const nonce = registry.challenge(account, id, operation);
  const text = requestText(account, id, nonce, operation);
  return { account, id, nonce, proof: id === 'primary' ? nativeSign(text, identity) : await sign(text, keys.signing) };
}
async function message(f, text, from = alice, to = bob) {
  const sender = f.registry.directory(from === alice ? 'alice' : 'bob').history.at(-1);
  const recipient = f.registry.directory(to === bob ? 'bob' : 'alice').history.at(-1);
  const m = { version: 2, id: randomBytes(32).toString('hex'), from: sender.account, deviceId: 'primary',
    to: recipient.account, fromRevision: sender.revision, toRevision: recipient.revision,
    fromDigest: await hash(manifestText(sender)), toDigest: await hash(manifestText(recipient)),
    createdAt: Date.now(), envelopes: [], signature: '' };
  for (const r of [sender, recipient]) {
    for (const d of r.devices) m.envelopes.push({ account: r.account, deviceId: d.id, payload: await encryptLegacy(text, d.encryptionKey) });
  }
  m.signature = nativeSign(messageText(m), from); return m;
}
async function send(f, m, identity = alice) {
  return f.registry.send(m, await auth(f.registry, m.from, m.deviceId,
    await operationDigest('send', await hash(messageText(m))), identity));
}
async function fixture() {
  const users = new Map([['alice', { publicKey: alice.pem }], ['bob', { publicKey: bob.pem }]]);
  let saved;
  const persist = async value => { saved = copy(value); };
  const registry = await createDeviceRegistry({ users, persist });
  const a = await roster('alice', alice, []), b = await roster('bob', bob, [descriptor(vault)]);
  await registry.install(a, [], ga);
  await registry.install(b, [await pairing('bob', vault, browser)], gb);
  return { registry, saved: () => copy(saved) };
}
async function tempDir(prefix) {
  const build = path.join(serverRoot, 'build');
  await fs.mkdir(build, { recursive: true });
  return fs.mkdtemp(path.join(build, prefix));
}
function cli(args, env = {}) {
  return JSON.parse(execFileSync(process.execPath, [CLI, ...args], {
    cwd: serverRoot, env: { ...process.env, ALPHA_STORAGE_SECRET: SECRET, ...env }, encoding: 'utf8' }));
}
const refsOf = (snapshot, key) => (snapshot.queues[key] || []).map(messageRef);

before(async () => {
  alice = nativeIdentity(); bob = nativeIdentity(); recovery = nativeIdentity();
  vault = await createVault('bob', phrase); browser = await unlockVault(vault, phrase);
  vault2 = await createVault('bob', phrase + ' second device'); browser2 = await unlockVault(vault2, phrase + ' second device');
  async function genesis(account, identity) {
    const g = { version: 2, account, nonce: randomBytes(32).toString('hex'), createdAt: Date.now() - 1000, legacy: true,
      firstDevice: { id: 'primary', encryptionKey: identity.root, signingKey: identity.root }, recoveryKey: recovery.root, signature: '' };
    g.signature = nativeSign(genesisText(g), identity); return g;
  }
  ga = await genesis('alice', alice); gb = await genesis('bob', bob);
});

test('lossless replay: post-backup messages, ACK, read, retract and new device survive restore', { timeout: 120000 }, async () => {
  const f = await fixture();
  const m1 = await message(f, 'before backup 1'), m2 = await message(f, 'before backup 2');
  await send(f, m1); await send(f, m2);
  const bobAuth = async () => auth(f.registry, 'bob', 'primary', await operationDigest('ack', [messageRef(m1)]), bob);
  await f.registry.acknowledge([messageRef(m1)], await bobAuth());
  await f.registry.read([messageRef(m2)], await auth(f.registry, 'bob', 'primary', await operationDigest('read', [messageRef(m2)]), bob));
  const backup = f.saved(); // ── backup point ──

  // Post-backup life: new message, new device, fanout, ACK, retract.
  const m3 = await message(f, 'after backup 3');
  await send(f, m3);
  const b2 = await roster('bob', bob, [descriptor(vault), descriptor(vault2)], f.registry.directory('bob').history.at(-1));
  await f.registry.install(b2, [await pairing('bob', vault2, browser2)]);
  const m4 = await message(f, 'after backup 4'); // fanout to bob primary + second device
  await send(f, m4);
  await f.registry.acknowledge([messageRef(m3)], await auth(f.registry, 'bob', 'primary', await operationDigest('ack', [messageRef(m3)]), bob));
  await f.registry.retract([messageRef(m2)], await auth(f.registry, 'alice', 'primary', await operationDigest('retract', [messageRef(m2)]), alice));
  const live = f.saved();

  const { snapshot: merged, stats } = mergeRollbackSnapshots({ restored: backup, live });
  // Full cryptographic re-verification (signature chains, tombstones, roots).
  const users = new Map(Object.entries(merged.accounts).filter(([, r]) => r.legacy)
    .map(([name, r]) => [name, { publicKey: createPublicKey({ key: Buffer.from(r.root, 'base64'), format: 'der', type: 'spki' })
      .export({ type: 'spki', format: 'pem' }) }]));
  const rebuilt = await createDeviceRegistry({ users, snapshot: copy(merged), persist: async () => true });
  const dir = rebuilt.directory('bob');
  assert.equal(dir.history.at(-1).revision, 2, 'post-backup directory revision replayed');
  assert.equal(dir.history.at(-1).devices.length, 3, 'post-backup device restored');
  assert.ok(stats.directoryRevisionsReplayed >= 1);

  const primaryQ = refsOf(merged, 'bob:primary');
  const secondQ = refsOf(merged, `bob:${descriptor(vault2).id}`);
  assert.ok(!primaryQ.includes(messageRef(m1)), 'pre-backup ACK not resurrected');
  assert.ok(!primaryQ.includes(messageRef(m2)), 'post-backup retract purged queue');
  assert.ok(!primaryQ.includes(messageRef(m3)), 'post-backup ACK applied');
  assert.ok(primaryQ.includes(messageRef(m4)), 'post-backup message preserved');
  assert.ok(secondQ.includes(messageRef(m4)), 'fanout to post-backup device preserved');
  assert.equal(merged.retractions[messageRef(m2)].from, 'alice', 'retract tombstone preserved');
  assert.ok(merged.delivery[messageRef(m1)].devices.find(d => d.id === 'primary').acknowledgedAt, 'ACK state preserved');
  assert.ok(merged.delivery[messageRef(m2)].devices.find(d => d.id === 'primary').readAt, 'read state preserved');
  assert.ok(merged.delivery[messageRef(m3)].devices.find(d => d.id === 'primary').acknowledgedAt, 'post-backup ACK state preserved');
  for (const m of [m1, m2, m3, m4]) assert.ok(merged.receipts[messageRef(m)], 'receipt ledger complete');
  // The rebuilt relay can still deliver the preserved ciphertext.
  const fetched = await rebuilt.fetch(await auth(rebuilt, 'bob', 'primary', await operationDigest('fetch'), bob));
  assert.ok(fetched.some(x => messageRef(x.message) === messageRef(m4)), 'preserved message fetchable after restore');
});

test('CLI replay-restore: verified merge, safety backup, and fail-closed on divergence', { timeout: 120000 }, async () => {
  const f = await fixture();
  const m1 = await message(f, 'cli before backup');
  await send(f, m1);
  const backupSnap = f.saved();
  const m2 = await message(f, 'cli after backup');
  await send(f, m2);
  const liveSnap = f.saved();

  const target = await tempDir('rollback-target-');
  const backupDir = await tempDir('rollback-backup-');
  const targetStore = await alphaStore(target, SECRET);
  await targetStore.save(liveSnap); await targetStore.close();
  const backupStore = await alphaStore(backupDir, SECRET);
  await backupStore.save(backupSnap); await backupStore.close();

  const result = cli(['replay-restore', '--target', target, '--backup', backupDir, '--confirm']);
  assert.equal(result.ok, true);
  assert.ok(result.stats.queueEntriesPreserved >= 1);
  const afterStore = await alphaStore(target, SECRET);
  const after = await afterStore.load(); await afterStore.close();
  assert.ok(refsOf(after, 'bob:primary').includes(messageRef(m2)), 'post-backup message survived CLI restore');
  assert.ok(after.receipts[messageRef(m1)], 'pre-backup receipt kept');
  // Safety backup of the live state exists and decrypts to the live snapshot.
  const safetyStore = await alphaStore(path.dirname(result.liveBackup), SECRET);
  const safety = await safetyStore.load(); await safetyStore.close();
  assert.deepEqual(safety, liveSnap);

  // Divergent directory chains must fail closed and leave the target bytes intact.
  const b2a = await roster('bob', bob, [descriptor(vault)], f.registry.directory('bob').history.at(-1));
  const b2b = await roster('bob', bob, [descriptor(vault2)], f.registry.directory('bob').history.at(-1), Date.now() + 1);
  const divergedLive = copy(liveSnap);
  divergedLive.accounts.bob.history.push(b2a);
  const divergedBackup = copy(backupSnap);
  divergedBackup.accounts.bob.history = [backupSnap.accounts.bob.history[0], b2b];
  const t2 = await tempDir('rollback-diverged-');
  const b2dir = await tempDir('rollback-diverged-backup-');
  const s2 = await alphaStore(t2, SECRET); await s2.save(divergedLive); await s2.close();
  const s2b = await alphaStore(b2dir, SECRET); await s2b.save(divergedBackup); await s2b.close();
  const beforeBytes = await fs.readFile(path.join(t2, 'device-v2.enc'));
  assert.throws(() => cli(['replay-restore', '--target', t2, '--backup', b2dir, '--confirm']),
    /rollback directory divergence/);
  assert.deepEqual(await fs.readFile(path.join(t2, 'device-v2.enc')), beforeBytes, 'failed replay changed nothing');
});

test('revocation after backup is never resurrected by replay', { timeout: 120000 }, async () => {
  const f = await fixture();
  const m1 = await message(f, 'to revoked device');
  await send(f, m1);
  const backup = f.saved();
  // Revoke bob's web device after the backup point.
  const b2 = await roster('bob', bob, [], f.registry.directory('bob').history.at(-1));
  await f.registry.install(b2, []);
  const live = f.saved();
  const { snapshot: merged } = mergeRollbackSnapshots({ restored: backup, live });
  const revokedId = descriptor(vault).id;
  assert.ok(!merged.queues[`bob:${revokedId}`]?.length, 'revoked device queue not resurrected');
  assert.ok(!refsOf(merged, 'bob:primary').includes(messageRef(m1)) ||
    merged.accounts.bob.retired.includes(revokedId), 'revocation tombstone kept');
  assert.ok(merged.accounts.bob.retired.includes(revokedId));
});

test('legacy inbox merge: dedup, ACK tombstones, monotonic migration status', async () => {
  const hashSync = value => createHash('sha256').update(value).digest('hex');
  const entry = (id, from, data) => ({ id, from, timestamp: Date.now(), data, digest: hashSync(data) });
  const e1 = entry('id1', 'carol', 'ciphertext-1'), e2 = entry('id2', 'carol', 'ciphertext-2'), e3 = entry('id3', 'dave', 'ciphertext-3');
  const base = { format: 2, accounts: {}, queues: {}, receipts: {}, delivery: {}, stickers: {}, retractions: {}, pushSubscriptions: {} };
  const restored = { ...copy(base),
    migration: { format: 1, accounts: { alice: { attempts: 1, acked: [], status: 'prepared', inboxImported: 2 } } },
    legacyInbox: { alice: [e1, e2] } };
  const live = { ...copy(base),
    migration: { format: 1, accounts: { alice: { attempts: 2, acked: ['carol:id1'], status: 'enrolled', inboxImported: 3, enrolledAt: 123 } } },
    legacyInbox: { alice: [e2, e3] } };
  const { snapshot: merged } = mergeRollbackSnapshots({ restored, live });
  const inbox = merged.legacyInbox.alice;
  assert.equal(inbox.length, 2, 'acked entry dropped, dedup applied');
  assert.ok(inbox.some(e => e.id === 'id2') && inbox.some(e => e.id === 'id3'));
  assert.ok(!inbox.some(e => e.id === 'id1'), 'ACK tombstone respected');
  assert.equal(merged.migration.accounts.alice.status, 'enrolled');
  assert.equal(merged.migration.accounts.alice.preparedAt ?? null, null);
  assert.equal(merged.migration.accounts.alice.enrolledAt, 123);
  assert.deepEqual(merged.migration.accounts.alice.acked, ['carol:id1']);
});

// Randomized model test: random send/ack/retract event sequences across a
// backup point. Invariant: when the live chain extends the backup chain, the
// merged projection equals the LIVE projection (live is the authoritative
// superset of post-backup knowledge) — no loss, no resurrection.
test('randomized merge model: merged queues/receipts/delivery/retractions equal live', { timeout: 180000 }, async () => {
  for (let round = 0; round < 5; round++) {
    const f = await fixture();
    const sent = [];
    // Pre-backup events.
    for (let i = 0; i < 4; i++) { const m = await message(f, `pre ${round}-${i}`); await send(f, m); sent.push(m); }
    await f.registry.acknowledge([messageRef(sent[0])],
      await auth(f.registry, 'bob', 'primary', await operationDigest('ack', [messageRef(sent[0])]), bob));
    const backup = f.saved();
    // Post-backup random events.
    const rng = randomBytes(64);
    for (let i = 0; i < 8; i++) {
      const pick = rng[i % rng.length] % 4;
      if (pick === 0 || sent.length === 0) {
        const m = await message(f, `post ${round}-${i}`); await send(f, m); sent.push(m);
      } else {
        const m = sent[rng[(i + 7) % rng.length] % sent.length];
        if (pick === 1) {
          await f.registry.acknowledge([messageRef(m)],
            await auth(f.registry, 'bob', 'primary', await operationDigest('ack', [messageRef(m)]), bob));
        } else if (pick === 2) {
          await f.registry.retract([messageRef(m)],
            await auth(f.registry, 'alice', 'primary', await operationDigest('retract', [messageRef(m)]), alice));
        } else {
          await f.registry.read([messageRef(m)],
            await auth(f.registry, 'bob', 'primary', await operationDigest('read', [messageRef(m)]), bob));
        }
      }
    }
    const live = f.saved();
    const { snapshot: merged } = mergeRollbackSnapshots({ restored: backup, live });
    assert.deepEqual(merged.queues, live.queues, `round ${round}: queues`);
    assert.deepEqual(merged.receipts, live.receipts, `round ${round}: receipts`);
    assert.deepEqual(merged.delivery, live.delivery, `round ${round}: delivery`);
    assert.deepEqual(merged.retractions, live.retractions, `round ${round}: retractions`);
    assert.deepEqual(merged.accounts, live.accounts, `round ${round}: accounts`);
  }
});

test('rolling checkpoints: durable, bounded, decryptable, never break the main save', { timeout: 60000 }, async () => {
  const dir = await tempDir('checkpoint-store-');
  const checkpoints = await tempDir('checkpoint-rolling-');
  const store = await alphaStore(dir, SECRET, { checkpointDir: checkpoints, checkpointKeep: 3 });
  const snapshots = [];
  for (let i = 0; i < 5; i++) {
    const snap = { format: 2, accounts: {}, queues: {}, receipts: { [`alice:primary:${'0'.repeat(63)}${i}`]: `digest-${i}` },
      delivery: {}, stickers: {}, retractions: {}, pushSubscriptions: {} };
    snapshots.push(snap);
    await store.save(snap);
  }
  await store.close();
  const files = (await fs.readdir(checkpoints)).filter(f => f.startsWith('checkpoint-') && f.endsWith('.enc')).sort();
  assert.equal(files.length, 3, 'bounded rolling window');
  const latest = JSON.parse(await fs.readFile(path.join(checkpoints, files.at(-1)), 'utf8'));
  assert.ok(latest.nonce && latest.tag && latest.data, 'checkpoint is an encrypted snapshot');
  // The latest checkpoint decrypts with the same secret to the last snapshot.
  const { createDecipheriv, createHash } = await import('node:crypto');
  const key = createHash('sha256').update(SECRET).digest();
  const decipher = createDecipheriv('aes-256-gcm', key, Buffer.from(latest.nonce, 'hex'));
  decipher.setAuthTag(Buffer.from(latest.tag, 'hex'));
  const decoded = JSON.parse(Buffer.concat([decipher.update(Buffer.from(latest.data, 'hex')), decipher.final()]).toString('utf8'));
  assert.deepEqual(decoded, snapshots.at(-1));
});
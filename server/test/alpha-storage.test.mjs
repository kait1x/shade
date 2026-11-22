// IndexedDB storage reliability logic (node + fake-indexeddb): vault commit
// flush isolation, state CAS revisions, and v1→v2 additive upgrade. The real
// WebKit kill/flush behaviour is additionally covered by browser QA reloads.
import test from 'node:test';
import { beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import 'fake-indexeddb/auto';
import { IDBFactory } from 'fake-indexeddb';
import { createVault, unlockVault, saveVault, loadVault, listVaults } from '../../client/web/device_crypto.mjs';
import { readReadMarks, readState, saveReadMarks, writeState } from '../../client/web/alpha-storage.mjs';

const phrase = 'synthetic storage reliability passphrase';
// Fresh IndexedDB factory per test: databases never leak between scenarios.
beforeEach(() => {
  globalThis.indexedDB = new IDBFactory();
  // Minimal synchronous localStorage shim (WebKit-durable journal path).
  const store = new Map();
  globalThis.localStorage = {
    getItem: k => (store.has(k) ? store.get(k) : null),
    setItem: (k, v) => { store.set(k, String(v)); },
    removeItem: k => { store.delete(k); }
  };
});

test('vault save flushes durably, keeps meta out of listings, rejects duplicates', async () => {
  const vault = await createVault('storage_test', phrase);
  await saveVault(vault);
  const loaded = await loadVault(vault.id);
  assert.equal(loaded.id, vault.id);
  assert.equal(loaded.ciphertext, vault.ciphertext);
  const all = await listVaults();
  assert.equal(all.length, 1); // the durability flush record lives in 'meta'
  assert.equal(all[0].id, vault.id);
  await assert.rejects(() => saveVault(vault), /already exists/);
  const session = await unlockVault(loaded, phrase);
  assert.equal(session.account, 'storage_test');
});

test('state writes are CAS-protected, verified by read-back and reversible', async () => {
  const vault = await createVault('state_test', phrase);
  const session = await unlockVault(vault, phrase);
  const empty = await readState(session);
  assert.equal(empty.revision, 0);
  assert.equal(empty.value, null);
  const value = { messages: [{ ref: 'a:b:c', text: 'привет' }], outbox: [] };
  assert.equal(await writeState(session, value, 0), 1);
  const read = await readState(session);
  assert.equal(read.revision, 1);
  assert.deepEqual(read.value, value);
  // Stale revision (another tab) must abort, not overwrite.
  await assert.rejects(() => writeState(session, { messages: [] }, 0), /другой вкладке/);
  assert.equal((await readState(session)).revision, 1);
  assert.equal(await writeState(session, { messages: [], outbox: [] }, 1), 2);
  assert.deepEqual((await readState(session)).value, { messages: [], outbox: [] });
});

test('read marks survive unlocking the vault again and merge concurrent tabs', async () => {
  const vault = await createVault('reads_test', phrase);
  const original = await unlockVault(vault, phrase);
  const history = { messages: [{ ref: 'a:b:c' }], outbox: [] };
  const revision = await writeState(original, history, 0);
  await Promise.all([
    saveReadMarks(original, { alice: 100 }),
    saveReadMarks(original, { alice: 200, bob: 300 }),
  ]);
  await saveReadMarks(original, { alice: 150 });

  const reopened = await unlockVault(vault, phrase);
  assert.deepEqual(await readReadMarks(reopened), { alice: 200, bob: 300 });
  assert.deepEqual(await readState(reopened), { revision, value: history });
  const otherVault = await createVault('other_reads_test', phrase);
  assert.deepEqual(await readReadMarks(await unlockVault(otherVault, phrase)), {});
});

test('deletion journal survives a rolled-back state commit (WebKit loss model)', async () => {
  const vault = await createVault('journal_test', phrase);
  const session = await unlockVault(vault, phrase);
  const m1 = { ref: 'a:primary:11', text: 'keep' };
  const m2 = { ref: 'a:primary:22', text: 'delete me' };
  await writeState(session, { messages: [m1, m2], outbox: [] }, 0);
  await writeState(session, { messages: [m1], outbox: [] }, 1);
  assert.deepEqual((await readState(session)).value.messages, [m1]);
  // Simulate the platform losing the final state commit: roll the raw record
  // back to the pre-delete snapshot. The journal must still hide the message.
  const db = await new Promise((resolve, reject) => {
    const req = indexedDB.open('shade-alpha-state');
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(Error('open failed'));
  });
  const stale = await new Promise((resolve, reject) => {
    const tx = db.transaction('states', 'readonly');
    const rq = tx.objectStore('states').get(session.id);
    tx.oncomplete = () => resolve(rq.result);
    tx.onabort = () => reject(Error('read failed'));
  });
  assert.equal(stale.revision, 2);
  // Forge a revision-2 record containing the deleted message (worst case:
  // the delete commit vanished but an older snapshot with the same revision
  // resurfaces). Journal entries are independent of the state record.
  const { encryptRecord } = await import('../../client/web/device_crypto.mjs');
  const forged = await encryptRecord(session, 'state', { messages: [m1, m2], outbox: [] });
  await new Promise((resolve, reject) => {
    const tx = db.transaction('states', 'readwrite');
    tx.objectStore('states').put({ id: session.id, revision: 2, encrypted: forged });
    tx.oncomplete = resolve;
    tx.onabort = () => reject(Error('forge failed'));
  });
  db.close();
  const recovered = await readState(session);
  assert.deepEqual(recovered.value.messages, [m1], 'journal must prevent resurrection');
});

test('synchronous localStorage journal survives total IDB batch loss (WebKit kill model)', async () => {
  const vault = await createVault('sync_journal', phrase);
  const session = await unlockVault(vault, phrase);
  const m1 = { ref: 'a:primary:11', text: 'keep' };
  const m2 = { ref: 'a:primary:22', text: 'delete me' };
  await writeState(session, { messages: [m1, m2], outbox: [] }, 0);
  await writeState(session, { messages: [m1], outbox: [] }, 1);
  // The durable journal must already contain the removal BEFORE any flush.
  const journal = JSON.parse(localStorage.getItem(`shade-alpha-deletions:${session.id}`));
  assert.ok(journal.entries.some(e => e.ref === 'a:primary:22'));
  // Worst case: the entire last IDB batch (state + IDB journal) is lost and an
  // older snapshot resurfaces. The localStorage journal still hides the ref.
  const db = await new Promise((resolve, reject) => {
    const req = indexedDB.open('shade-alpha-state');
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(Error('open failed'));
  });
  const { encryptRecord } = await import('../../client/web/device_crypto.mjs');
  const forged = await encryptRecord(session, 'state', { messages: [m1, m2], outbox: [] });
  await new Promise((resolve, reject) => {
    const tx = db.transaction(['states', 'deletions'], 'readwrite');
    tx.objectStore('states').put({ id: session.id, revision: 2, encrypted: forged });
    tx.objectStore('deletions').clear();
    tx.oncomplete = resolve;
    tx.onabort = () => reject(Error('forge failed'));
  });
  db.close();
  const recovered = await readState(session);
  assert.deepEqual(recovered.value.messages, [m1], 'sync journal must survive IDB loss');
});

test('refreshDurability re-commits without changing revision (pagehide flush)', async () => {
  const { refreshDurability } = await import('../../client/web/alpha-storage.mjs');
  const vault = await createVault('refresh_test', phrase);
  const session = await unlockVault(vault, phrase);
  const value = { messages: [{ ref: 'a:primary:11', text: 'keep' }], outbox: [] };
  const revision = await writeState(session, value, 0);
  assert.equal(revision, 1);
  await refreshDurability(session, value, revision);
  const after = await readState(session);
  assert.equal(after.revision, 1, 'refresh must not bump the revision');
  assert.deepEqual(after.value.messages, value.messages);
  // Journal re-warm uses a varying tick so StorageTracker schedules a sync.
  const journal = JSON.parse(localStorage.getItem(`shade-alpha-deletions:${session.id}`) || '{"tick":-1}');
  assert.ok(journal.tick >= 0);
  // No-op guards: missing session/value/revision never throw.
  await refreshDurability(null, value, 1);
  await refreshDurability(session, null, 1);
  await refreshDurability(session, value, 0);
});

test('v1 databases upgrade additively to v2 without losing vaults', async () => {
  // Simulate a pre-existing version-1 database with a stored vault record.
  const vault = await createVault('upgrade_test', phrase);
  await new Promise((resolve, reject) => {
    const req = indexedDB.open('shade-device-v2', 1);
    req.onupgradeneeded = () => req.result.createObjectStore('vaults', { keyPath: 'id' });
    req.onsuccess = () => {
      const db = req.result;
      const tx = db.transaction('vaults', 'readwrite');
      tx.objectStore('vaults').put(vault);
      tx.oncomplete = () => { db.close(); resolve(); };
      tx.onabort = () => reject(Error('setup failed'));
    };
    req.onerror = () => reject(Error('setup open failed'));
  });
  const loaded = await loadVault(vault.id); // opens v2, runs additive upgrade
  assert.equal(loaded.ciphertext, vault.ciphertext);
  const session = await unlockVault(loaded, phrase);
  assert.equal(session.account, 'upgrade_test');
  // The upgraded database accepts the durability flush path.
  await saveVault(await createVault('upgrade_second', phrase));
  assert.equal((await listVaults()).length, 2);
});
test('web status refresh retains confirmed reads after reopening the vault', async t => {
  globalThis.window = new EventTarget();
  t.after(() => { delete globalThis.window; });
  const { AlphaClient } = await import('../../client/web/alpha-client.mjs');
  const vault = await createVault('sender_test', phrase);
  const session = await unlockVault(vault, phrase);
  const device = { account: 'receiver', id: 'primary', acknowledgedAt: 100, readAt: 200 };
  const messages = [
    { ref: 'text', from: session.account, status: 'accepted', devices: [device] },
    { ref: 'photo', from: session.account, status: 'accepted', chunkRefs: ['chunk'], devices: [device] },
  ];
  await writeState(session, { messages }, 0);
  const client = new AlphaClient();
  await client.load(vault, phrase);
  client.operation = async (op, refs) => {
    assert.equal(op, 'status');
    assert.deepEqual(refs, ['text', 'chunk']);
    return { text: [], chunk: [{ account: device.account, id: device.id, acknowledgedAt: 150 }] };
  };
  await client.refreshDelivery();

  const reopened = await readState(session);
  assert.deepEqual(reopened.value.messages[0].devices, [device]);
  assert.deepEqual(reopened.value.messages[1].devices, [{ ...device, acknowledgedAt: 150 }]);
});

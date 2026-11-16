import { encryptRecord, decryptRecord } from './device_crypto.mjs';

// Durability model (WebKit last-transaction risk):
// 1. Deletion journal: refs removed from the state are recorded atomically
//    with the state change and re-applied on every read, so a lost final
//    commit can never resurrect a deleted message.
// 2. Re-commit: every critical write is committed twice in separate
//    transactions (with meta flushes); losing the LAST transaction still
//    leaves the identical earlier commit durable. No timing assumptions.
const DELETION_TTL_MS = 7 * 24 * 60 * 60 * 1000;

// WebKit flushes IndexedDB asynchronously (timer-based); an abrupt reload/kill
// inside the flush window loses the last IDB batch, and fresh connections read
// the in-memory server state, NOT disk. localStorage.setItem IS synchronous and
// durable in WebKit, so the deletion journal is written there FIRST (refs only,
// no message content; same-origin trust model already applies to the vault).
// The IDB journal remains as a second copy. readState merges both.
const journalKey = id => `shade-alpha-deletions:${id}`;
function readLocalJournal(id) {
  try {
    if (typeof localStorage === 'undefined') return [];
    const parsed = JSON.parse(localStorage.getItem(journalKey(id)) || '[]');
    return Array.isArray(parsed) ? parsed.filter(e => e && typeof e.ref === 'string') : [];
  } catch { return []; }
}
function writeLocalJournal(id, entries) {
  try {
    if (typeof localStorage === 'undefined') return;
    localStorage.setItem(journalKey(id), JSON.stringify(entries));
  } catch { /* private mode/quota: IDB journal still applies */ }
}
function mergeJournalEntries(existing, removed) {
  const cutoff = Date.now() - DELETION_TTL_MS;
  const byRef = new Map();
  for (const entry of [...existing, ...removed]) {
    if (entry.at >= cutoff) byRef.set(entry.ref, entry);
  }
  return [...byRef.values()];
}

async function database() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open('shade-alpha-state', 3);
    request.onupgradeneeded = event => {
      const db = request.result;
      if (event.oldVersion < 1) db.createObjectStore('states', { keyPath: 'id' });
      if (event.oldVersion < 2) db.createObjectStore('meta', { keyPath: 'id' });
      if (event.oldVersion < 3) db.createObjectStore('deletions', { keyPath: 'ref' });
    };
    request.onsuccess = () => {
      const db = request.result;
      // Another tab upgrading the database must not be blocked by this connection.
      db.onversionchange = () => db.close();
      // Ask for persistent storage (eviction protection); best-effort.
      try { navigator.storage?.persist?.(); } catch { /* unsupported */ }
      resolve(db);
    };
    request.onerror = () => reject(Error('Хранилище недоступно. Ключи не заменены.'));
    request.onblocked = () => reject(Error('Закройте другие вкладки Shade.'));
  });
}
function txDone(tx) {
  return new Promise((resolve, reject) => {
    tx.oncomplete = resolve;
    tx.onabort = () => reject(Error(tx.error?.message || 'Транзакция хранилища прервана.'));
    tx.onerror = () => {};
  });
}
// A follow-up meta transaction forces the preceding commit toward durable
// storage; explicit tx.commit() accelerates the commit itself.
async function durabilityFlush(db) {
  const tx = db.transaction('meta', 'readwrite');
  tx.objectStore('meta').put({ id: 'flush', at: Date.now() });
  if (typeof tx.commit === 'function') tx.commit();
  await txDone(tx);
}
async function readRaw(db, id) {
  const tx = db.transaction('states', 'readonly');
  const req = tx.objectStore('states').get(id);
  const done = txDone(tx);
  const result = await new Promise(resolve => { req.onsuccess = () => resolve(req.result); });
  await done;
  return result;
}
async function readDeletions(db) {
  const tx = db.transaction('deletions', 'readonly');
  const req = tx.objectStore('deletions').getAll();
  const done = txDone(tx);
  const result = await new Promise(resolve => { req.onsuccess = () => resolve(req.result || []); });
  await done;
  return result;
}
function applyDeletions(value, deletions) {
  if (!value || !deletions.length) return value;
  const refs = new Set(deletions.map(d => d.ref));
  return {
    ...value,
    messages: (value.messages || []).filter(m => !refs.has(m.ref)),
    outbox: (value.outbox || []).filter(m => !refs.has(`${m.from}:${m.deviceId}:${m.id}`))
  };
}
export async function readState(session) {
  const db = await database();
  let stored, deletions;
  try {
    stored = await readRaw(db, session.id);
    deletions = await readDeletions(db);
  } finally { db.close(); }
  if (!stored) return { revision: 0, value: null };
  const value = await decryptRecord(session, 'state', stored.encrypted);
  const merged = mergeJournalEntries(deletions, readLocalJournal(session.id));
  return { revision: stored.revision, value: applyDeletions(value, merged) };
}
export async function writeState(session, value, revision) {
  const encrypted = await encryptRecord(session, 'state', value);
  if (encrypted.ciphertext.length > 32 * 1024 * 1024) throw Error('Локальная история достигла лимита альфы.');
  const db = await database();
  try {
    // Detect removals against the currently stored state BEFORE the write tx
    // (async decryption must not run inside an active IDB transaction).
    const previous = await readRaw(db, session.id);
    let removed = [];
    if (previous && (previous.revision || 0) === revision) {
      const oldValue = await decryptRecord(session, 'state', previous.encrypted);
      const nextRefs = new Set((value.messages || []).map(m => m.ref));
      removed = (oldValue.messages || [])
        .filter(m => !nextRefs.has(m.ref))
        .map(m => ({ ref: m.ref, at: Date.now() }));
    }
    // Synchronous durable journal BEFORE the async IDB commit: even if the
    // whole IDB batch is lost to a WebKit kill/reload, removals survive.
    if (removed.length) {
      writeLocalJournal(session.id, mergeJournalEntries(readLocalJournal(session.id), removed));
    }
    const record = { id: session.id, revision: revision + 1, encrypted };
    const commit = async expectedRevision => {
      const tx = db.transaction(['states', 'deletions'], 'readwrite');
      const store = tx.objectStore('states');
      const req = store.get(session.id);
      let casConflict = false;
      req.onsuccess = () => {
        if ((req.result?.revision || 0) !== expectedRevision) { casConflict = true; tx.abort(); return; }
        store.put(record);
        const delStore = tx.objectStore('deletions');
        for (const entry of removed) delStore.put(entry);
        // Prune expired journal entries inside the same atomic commit.
        const all = delStore.getAll();
        all.onsuccess = () => {
          const cutoff = Date.now() - DELETION_TTL_MS;
          for (const entry of all.result || []) if (entry.at < cutoff) delStore.delete(entry.ref);
        };
        if (typeof tx.commit === 'function') tx.commit();
      };
      try {
        await txDone(tx);
      } catch (error) {
        if (casConflict) {
          throw Error('История изменена в другой вкладке или хранилище заполнено. Перезагрузите Shade.');
        }
        throw error;
      }
    };
    await commit(revision);
    await durabilityFlush(db);
    // Re-commit the identical record in a fresh transaction: if the platform
    // loses the last transaction, the earlier identical commit survives.
    await commit(revision + 1);
    await durabilityFlush(db);
    const check = await readRaw(db, session.id);
    if ((check?.revision || 0) !== revision + 1) {
      throw Error('Хранилище не подтвердило запись. Повторите действие.');
    }
    // WebKit flushes commits to disk asynchronously (no JS sync primitive).
    // Background convergence: once a fresh connection still sees stale data
    // after the flush window, rewrite the identical record so durability is
    // achieved while the page lives. The deletion journal protects removals
    // even if the final commit is lost to an abrupt kill.
    ensureDurable(session.id, record, revision + 1);
  } finally { db.close(); }
  return revision + 1;
}
function ensureDurable(id, record, expectedRevision) {
  setTimeout(async () => {
    try {
      for (let attempt = 0; attempt < 2; attempt++) {
        const fresh = await database();
        let rec;
        try { rec = await readRaw(fresh, id); } finally { fresh.close(); }
        if ((rec?.revision || 0) >= expectedRevision) return;
        const db = await database();
        try {
          const tx = db.transaction('states', 'readwrite');
          tx.objectStore('states').put(record);
          if (typeof tx.commit === 'function') tx.commit();
          await txDone(tx);
          await durabilityFlush(db);
        } finally { db.close(); }
        await new Promise(r => setTimeout(r, 1200));
      }
    } catch { /* best-effort convergence; journal still protects deletions */ }
  }, 1200);
}
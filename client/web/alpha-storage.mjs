import { encryptRecord, decryptRecord } from './device_crypto.mjs';

async function database() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open('shade-alpha-state', 2);
    request.onupgradeneeded = event => {
      const db = request.result;
      if (event.oldVersion < 1) db.createObjectStore('states', { keyPath: 'id' });
      // Separate meta store: durability flushes never pollute state records.
      if (event.oldVersion < 2) db.createObjectStore('meta', { keyPath: 'id' });
    };
    request.onsuccess = () => {
      // Ask for persistent storage (eviction protection); best-effort.
      try { navigator.storage?.persist?.(); } catch { /* unsupported */ }
      resolve(request.result);
    };
    request.onerror = () => reject(Error('Хранилище недоступно. Ключи не заменены.'));
    request.onblocked = () => reject(Error('Закройте другие вкладки Shade.'));
  });
}
// WebKit can lose the LAST committed transaction when the process is killed
// right after oncomplete (the commit is flushed to disk asynchronously).
// A small follow-up transaction in a separate store forces the previous
// commit to durable storage; this is a client reliability mechanism, not a
// QA delay. Explicit tx.commit() additionally accelerates the commit itself.
async function durabilityFlush(db) {
  await new Promise((resolve, reject) => {
    const tx = db.transaction('meta', 'readwrite');
    tx.objectStore('meta').put({ id: 'flush', at: Date.now() });
    if (typeof tx.commit === 'function') tx.commit();
    tx.oncomplete = resolve;
    tx.onabort = () => reject(Error('Не удалось подтвердить запись хранилища.'));
    tx.onerror = () => {};
  });
}
export async function readState(session) {
  const db = await database();
  let stored;
  try {
    stored = await new Promise((resolve, reject) => {
      const tx = db.transaction('states', 'readonly');
      const req = tx.objectStore('states').get(session.id);
      tx.oncomplete = () => resolve(req.result);
      tx.onabort = () => reject(Error('Не удалось прочитать историю.'));
    });
  } finally { db.close(); }
  return stored ? { revision: stored.revision, value: await decryptRecord(session, 'state', stored.encrypted) } : { revision: 0, value: null };
}
export async function writeState(session, value, revision) {
  const encrypted = await encryptRecord(session, 'state', value);
  if (encrypted.ciphertext.length > 32 * 1024 * 1024) throw Error('Локальная история достигла лимита альфы.');
  const db = await database();
  try {
    await new Promise((resolve, reject) => {
      const tx = db.transaction('states', 'readwrite'), store = tx.objectStore('states');
      const req = store.get(session.id);
      req.onsuccess = () => {
        if ((req.result?.revision || 0) !== revision) { tx.abort(); return; }
        store.put({ id: session.id, revision: revision + 1, encrypted });
        if (typeof tx.commit === 'function') tx.commit();
      };
      tx.oncomplete = resolve;
      tx.onabort = () => reject(Error('История изменена в другой вкладке или хранилище заполнено. Перезагрузите Shade.'));
      tx.onerror = () => {};
    });
    // Force durability, then verify the commit by an independent read-back.
    await durabilityFlush(db);
    const check = await new Promise((resolve, reject) => {
      const tx = db.transaction('states', 'readonly');
      const req = tx.objectStore('states').get(session.id);
      tx.oncomplete = () => resolve(req.result);
      tx.onabort = () => reject(Error('Не удалось подтвердить запись.'));
    });
    if ((check?.revision || 0) !== revision + 1) {
      throw Error('Хранилище не подтвердило запись. Повторите действие.');
    }
  } finally { db.close(); }
  return revision + 1;
}

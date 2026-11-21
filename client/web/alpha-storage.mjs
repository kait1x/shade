import { encryptRecord, decryptRecord } from './device_crypto.mjs';

async function database() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open('shade-alpha-state', 1);
    request.onupgradeneeded = () => request.result.createObjectStore('states', { keyPath: 'id' });
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(Error('Хранилище недоступно. Ключи не заменены.'));
    request.onblocked = () => reject(Error('Закройте другие вкладки Shade.'));
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
      };
      tx.oncomplete = resolve;
      tx.onabort = () => reject(Error('История изменена в другой вкладке или хранилище заполнено. Перезагрузите Shade.'));
      tx.onerror = () => {};
    });
  } finally { db.close(); }
  return revision + 1;
}

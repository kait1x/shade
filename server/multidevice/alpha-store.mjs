// Separate alpha data only. Compatible with server.js AES-GCM at-rest format;
// never opens, migrates or writes the legacy server's files.
import { createHash, createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';

export async function alphaStore(directory, secret, { checkpointDir = null, checkpointKeep = 20 } = {}) {
  if (!secret || secret.length < 32) throw Error('ALPHA_STORAGE_SECRET must contain at least 32 characters');
  directory = path.resolve(directory);
  const key = createHash('sha256').update(secret).digest();
  await fs.mkdir(directory, { recursive: true, mode: 0o700 });
  if (checkpointDir) {
    checkpointDir = path.resolve(checkpointDir);
    await fs.mkdir(checkpointDir, { recursive: true, mode: 0o700 });
  }
  // Fail closed for production/legacy directories, including accidental reuse.
  for (const file of ['users.json', 'session_secret', 'server_master_key', 'messages.json']) {
    try { await fs.access(path.join(directory, file)); throw Error('Refusing legacy/production data directory'); }
    catch (e) { if (e.code !== 'ENOENT') throw e; }
  }
  const marker = path.join(directory, 'shade-alpha-only');
  await fs.writeFile(marker, 'Isolated Shade Web Alpha v2 data\n', { flag: 'a', mode: 0o600 });
  // Prevent two writers from acknowledging divergent snapshots.
  const lock = await fs.open(path.join(directory, 'writer.lock'), 'wx', 0o600);
  const filename = path.join(directory, 'device-v2.enc');
  let closed = false;
  return {
    async load() {
      let content;
      try { content = await fs.readFile(filename, 'utf8'); } catch (e) { if (e.code === 'ENOENT') return undefined; throw e; }
      const value = JSON.parse(content);
      const decipher = createDecipheriv('aes-256-gcm', key, Buffer.from(value.nonce, 'hex'));
      decipher.setAuthTag(Buffer.from(value.tag, 'hex'));
      return JSON.parse(Buffer.concat([decipher.update(Buffer.from(value.data, 'hex')), decipher.final()]).toString('utf8'));
    },
    async save(snapshot) {
      const nonce = randomBytes(12), cipher = createCipheriv('aes-256-gcm', key, nonce);
      const data = Buffer.concat([cipher.update(JSON.stringify(snapshot), 'utf8'), cipher.final()]);
      const encoded = JSON.stringify({ nonce: nonce.toString('hex'), tag: cipher.getAuthTag().toString('hex'), data: data.toString('hex') });
      const temporary = `${filename}.${randomBytes(8).toString('hex')}.tmp`;
      try {
        await fs.writeFile(temporary, encoded, { mode: 0o600, flush: true, flag: 'wx' });
        await fs.rename(temporary, filename);
        if (process.platform !== 'win32') {
          const dir = await fs.open(directory, 'r');
          try { await dir.sync(); } finally { await dir.close(); }
        }
      } finally { await fs.rm(temporary, { force: true }); }
      // Durable rolling checkpoints for lossless rollback (best-effort: a
      // checkpoint failure must never break messaging; the main save already
      // committed atomically above). Same encrypted bytes, separate directory.
      if (checkpointDir) {
        try {
          const stamp = new Date().toISOString().replace(/[:.]/g, '-');
          const name = `checkpoint-${stamp}-${randomBytes(4).toString('hex')}.enc`;
          const tmp = path.join(checkpointDir, `${name}.tmp`);
          await fs.writeFile(tmp, encoded, { mode: 0o600, flush: true, flag: 'wx' });
          await fs.rename(tmp, path.join(checkpointDir, name));
          const entries = (await fs.readdir(checkpointDir)).filter(f => f.startsWith('checkpoint-') && f.endsWith('.enc')).sort();
          for (const old of entries.slice(0, Math.max(0, entries.length - checkpointKeep))) {
            await fs.rm(path.join(checkpointDir, old), { force: true });
          }
        } catch (e) { console.error('[alpha-store] checkpoint write failed:', e.code || e.message); }
      }
    },
    async close() {
      if (closed) return; closed = true;
      await lock.close(); await fs.unlink(path.join(directory, 'writer.lock'));
    },
  };
}

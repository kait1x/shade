// Separate alpha data only. Reads the original AES-GCM JSON wrapper and the
// compact encrypted snapshot format. Never opens legacy server data.
import { createHash, createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';
import { promisify } from 'node:util';
import { brotliCompress, brotliDecompress, constants } from 'node:zlib';

const compactHeader = Buffer.from('SHD2BR01');
const isCompact = bytes => Buffer.isBuffer(bytes) && bytes.subarray(0, compactHeader.length).equals(compactHeader);
const compress = promisify(brotliCompress);
const decompress = promisify(brotliDecompress);
const deriveKey = secret => createHash('sha256').update(secret).digest();

async function decode(content, key) {
  if (isCompact(content)) {
    const nonceEnd = compactHeader.length + 12;
    const tagEnd = nonceEnd + 16;
    const decipher = createDecipheriv('aes-256-gcm', key, content.subarray(compactHeader.length, nonceEnd));
    decipher.setAAD(compactHeader);
    decipher.setAuthTag(content.subarray(nonceEnd, tagEnd));
    const compressed = Buffer.concat([decipher.update(content.subarray(tagEnd)), decipher.final()]);
    return JSON.parse((await decompress(compressed)).toString('utf8'));
  }
  const value = JSON.parse(content);
  const decipher = createDecipheriv('aes-256-gcm', key, Buffer.from(value.nonce, 'hex'));
  decipher.setAuthTag(Buffer.from(value.tag, 'hex'));
  return JSON.parse(Buffer.concat([decipher.update(Buffer.from(value.data, 'hex')), decipher.final()]).toString('utf8'));
}

export async function readAlphaSnapshot(directory, secret) {
  try { return await decode(await fs.readFile(path.join(directory, 'device-v2.enc')), deriveKey(secret)); }
  catch (error) { if (error.code === 'ENOENT') return undefined; throw error; }
}

export async function alphaStore(directory, secret, { checkpointDir = null, checkpointKeep = 20, compactSnapshots = false } = {}) {
  if (!secret || secret.length < 32) throw Error('ALPHA_STORAGE_SECRET must contain at least 32 characters');
  directory = path.resolve(directory);
  const key = deriveKey(secret);
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
  const presenceFilename = path.join(directory, 'presence.enc');
  const sessionsFilename = path.join(directory, 'sessions.enc');
  let closed = false;
  const writeEncrypted = async (target, value, useCompact = false) => {
    const nonce = randomBytes(12), cipher = createCipheriv('aes-256-gcm', key, nonce);
    const json = JSON.stringify(value);
    let encoded;
    if (useCompact && json.length >= 512 * 1024) {
      const packed = await compress(Buffer.from(json), { params: {
        [constants.BROTLI_PARAM_QUALITY]: 2,
        [constants.BROTLI_PARAM_LGWIN]: 24,
      } });
      cipher.setAAD(compactHeader);
      const data = cipher.update(packed), final = cipher.final();
      encoded = Buffer.concat([compactHeader, nonce, cipher.getAuthTag(), data, final]);
    } else {
      const data = Buffer.concat([cipher.update(json, 'utf8'), cipher.final()]);
      encoded = JSON.stringify({ nonce: nonce.toString('hex'), tag: cipher.getAuthTag().toString('hex'), data: data.toString('hex') });
    }
    const temporary = `${target}.${randomBytes(8).toString('hex')}.tmp`;
    try {
      await fs.writeFile(temporary, encoded, { mode: 0o600, flush: true, flag: 'wx' });
      await fs.rename(temporary, target);
      if (process.platform !== 'win32') {
        const dir = await fs.open(directory, 'r');
        try { await dir.sync(); } finally { await dir.close(); }
      }
    } finally { await fs.rm(temporary, { force: true }); }
    return encoded;
  };
  return {
    async load() {
      let content;
      try { content = await fs.readFile(filename); } catch (e) { if (e.code === 'ENOENT') return undefined; throw e; }
      return decode(content, key);
    },
    // Used after stopping the current writer, immediately before rolling back
    // to binaries that only understand the original AES-GCM JSON wrapper.
    async rewriteLegacySnapshot() {
      let bytes;
      try { bytes = await fs.readFile(filename); } catch (e) { if (e.code === 'ENOENT') return false; throw e; }
      if (!isCompact(bytes)) return false;
      await writeEncrypted(filename, await decode(bytes, key));
      return true;
    },
    // Last-seen hints survive restarts; live "online" itself is socket-derived.
    async loadPresence() {
      try { return await decode(await fs.readFile(presenceFilename), key); }
      catch (e) { if (e.code === 'ENOENT') return {}; throw e; }
    },
    savePresence(presence) { return writeEncrypted(presenceFilename, presence); },
    // Browser sessions survive restarts: a deploy must never log users out.
    async loadSessions() {
      try { return await decode(await fs.readFile(sessionsFilename), key); }
      catch (e) { if (e.code === 'ENOENT') return {}; throw e; }
    },
    saveSessions(sessions) { return writeEncrypted(sessionsFilename, sessions); },
    async save(snapshot) {
      // Checkpoints reuse the exact bytes committed to the main file.
      const encoded = await writeEncrypted(filename, snapshot, compactSnapshots);
      // Durable rolling checkpoints for lossless rollback (best-effort: a
      // checkpoint failure must never break messaging; the main save already
      // committed atomically above). Same encrypted bytes, separate directory.
      if (checkpointDir) {
        try {
          const stamp = new Date().toISOString().replace(/[:.]/g, '-');
          const name = `checkpoint-${stamp}-${randomBytes(4).toString('hex')}.enc`;
          const tmp = path.join(checkpointDir, `${name}.tmp`);
          // The committed file is never modified in place. A hard link keeps
          // the previous bytes intact when the next snapshot atomically replaces it.
          try {
            await fs.link(filename, tmp);
          } catch (error) {
            if (!['EXDEV', 'ENOTSUP', 'EPERM'].includes(error.code)) throw error;
            await fs.writeFile(tmp, encoded, { mode: 0o600, flush: true, flag: 'wx' });
          }
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

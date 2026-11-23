import fs from 'node:fs/promises';
import path from 'node:path';
import { alphaStore } from '../multidevice/alpha-store.mjs';

const { SHADE_ENV, ALPHA_DATA_DIR, ALPHA_STORAGE_SECRET } = process.env;
if (SHADE_ENV !== 'alpha' || !ALPHA_DATA_DIR || !ALPHA_STORAGE_SECRET) {
  throw Error('The isolated Alpha environment is required');
}
const directory = await fs.realpath(ALPHA_DATA_DIR);
await fs.access(path.join(directory, 'shade-alpha-only'));
// Read the protected systemd environment as root, then write as the existing
// data directory owner. The writer lock refuses to convert a live database.
if (process.getuid?.() === 0) {
  const { uid, gid } = await fs.stat(directory);
  if (!uid) throw Error('Expected an unprivileged Alpha data owner');
  process.setgid(gid);
  process.setuid(uid);
}
const store = await alphaStore(directory, ALPHA_STORAGE_SECRET);
try {
  console.log(await store.rewriteLegacySnapshot() ? 'Rewrote latest snapshot for rollback' : 'Snapshot already compatible');
} finally {
  await store.close();
}

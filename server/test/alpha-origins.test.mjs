// Multi-origin trust: canonical app origin + explicit first-party API origin.
// OAuth/cookies stay canonical; unknown origins are rejected fail-closed.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import { fixture, identity, register } from './helpers/alpha-fixture.mjs';
import * as c from '../../client/web/device_crypto.mjs';

async function tempDir() {
  const build = path.resolve('build');
  await fs.mkdir(build, { recursive: true });
  return fs.mkdtemp(path.join(build, 'alpha-origins-'));
}

test('extra first-party origin accepted, unknown rejected, insecure extra refused', { timeout: 60000 }, async () => {
  const dataDir = await tempDir();
  const storageSecret = randomBytes(32).toString('hex');
  const extra = 'https://api.shade.test';
  const f = await fixture({ dataDir, storageSecret, allowedOrigins: [extra] });
  try {
    const canonical = await f.request('/api/session');
    assert.equal(canonical.response.status, 200);
    const viaApi = await f.request('/api/session', undefined, '', { Origin: extra });
    assert.equal(viaApi.response.status, 200);
    const evil = await f.request('/api/session', undefined, '', { Origin: 'https://evil.test' });
    assert.equal(evil.response.status, 403);
    assert.equal(evil.result.error, 'origin_rejected');
    // POST mutations: same-origin rule applies to the extra origin too.
    const alice = await identity('origin_alice');
    const ac = await f.login('synthetic-alice');
    const reg = await f.request('/api/v2/register',
      { genesis: alice.genesis, manifest: alice.manifest,
        proofs: [await c.pairingProof(alice.vault, alice.session)] }, ac, { Origin: extra });
    // First-device registration succeeds through the extra first-party origin.
    assert.equal(reg.response.status, 200, JSON.stringify(reg.result));
  } finally { await f.close(); }
  // Insecure (http) extra origins must be refused at construction.
  await assert.rejects(fixture({ dataDir: await tempDir(), storageSecret,
    allowedOrigins: ['http://api.shade.test'] }), /Invalid extra origin/);
});
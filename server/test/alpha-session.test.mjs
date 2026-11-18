import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import { fixture } from './helpers/alpha-fixture.mjs';

test('alpha: /api/session exposes the verified email only for a logged-in session', { timeout: 60000 }, async t => {
  await fs.mkdir(path.resolve('build'), { recursive: true });
  const dataDir = await fs.mkdtemp(path.resolve('build/alpha-session-'));
  const f = await fixture({ dataDir, storageSecret: randomBytes(32).toString('hex') });
  t.after(async () => { await f.close(); await fs.rm(dataDir, { recursive: true, force: true }); });

  const anon = await f.request('/api/session');
  assert.equal(anon.response.status, 200);
  assert.equal(anon.result.authenticated, false);
  assert.ok(!('email' in anon.result), 'no email field without a session');

  const cookie = await f.login('synthetic-alice');
  const session = await f.request('/api/session', undefined, cookie);
  assert.equal(session.response.status, 200);
  assert.equal(session.result.authenticated, true);
  assert.equal(session.result.email, 'synthetic-alice@synthetic.invalid');

  // A different Google account sees its own email, not a cached one.
  const bobCookie = await f.login('synthetic-bob');
  const bobSession = await f.request('/api/session', undefined, bobCookie);
  assert.equal(bobSession.result.email, 'synthetic-bob@synthetic.invalid');
});
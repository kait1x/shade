import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import fs from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import { createAdminServer } from '../admin.mjs';
import { fixture, identity, register } from './helpers/alpha-fixture.mjs';

test('admin shows scoped metadata on loopback and stays separate from public v2', async t => {
  const dataDir = await fs.mkdtemp(path.join(tmpdir(), 'shade-admin-'));
  const f = await fixture({ dataDir, storageSecret: randomBytes(32).toString('hex') });
  const admin = await createAdminServer(f.adminOverview);
  t.after(async () => {
    await new Promise(resolve => admin.close(resolve));
    try { await f.close(); } finally { await fs.rm(dataDir, { recursive: true, force: true }); }
  });
  admin.listen(0, '127.0.0.1');
  await once(admin, 'listening');
  const origin = 'http://127.0.0.1:' + admin.address().port;
  const alice = await identity('alice_admin_fixture');
  await register(f, alice, await f.login('synthetic-admin-fixture'));

  const page = await fetch(origin);
  assert.equal(page.status, 200);
  assert.equal(page.headers.get('cache-control'), 'no-store');
  assert.match(page.headers.get('content-security-policy'), /frame-ancestors 'none'/);
  assert.match(await page.text(), /Никнейм/);
  assert.equal((await fetch(origin + '/admin.css')).status, 200);
  assert.equal((await fetch(origin + '/admin.js')).status, 200);

  const overview = await fetch(origin + '/overview?q=%40alice&page=999').then(res => res.json());
  assert.equal(overview.accounts, 1);
  assert.equal(overview.devices, 1);
  assert.equal(overview.queued, 0);
  assert.equal(overview.page, 1);
  assert.deepEqual(overview.rows, [{ account: 'alice_admin_fixture', devices: 1, online: false, lastSeen: null }]);
  assert.deepEqual(await fetch(origin + '/overview?online=1').then(res => res.json()).then(data => data.rows), []);

  assert.equal((await fetch(origin + '/overview', { method: 'POST' })).status, 405);
  assert.equal((await fetch(origin + '/overview', { headers: { Origin: 'https://shadechat.ru' } })).status, 403);
  assert.equal((await fetch('http://localhost:' + admin.address().port + '/overview')).status, 403);
  assert.equal((await f.request('/admin')).response.status, 404);
  assert.equal((await f.request('/overview')).response.status, 404);
});

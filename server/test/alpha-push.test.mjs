// Web Push (contract C6): VAPID wake-only notifications, subscription binding,
// SSRF guard, gone-endpoint pruning, unconfigured fail-closed, persistence.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const webPush = require('web-push');
import { fixture, identity, register, operation } from './helpers/alpha-fixture.mjs';
import { sealMessage } from '../../client/web/device_crypto.mjs';

async function tempDir() {
  const build = path.resolve('build');
  await fs.mkdir(build, { recursive: true });
  return fs.mkdtemp(path.join(build, 'alpha-push-'));
}
const subscription = (id) => ({ endpoint: `https://push.example.com/sub/${id}`,
  keys: { p256dh: 'BPpublicKeyValueBase64UrlEncodedExample1234567890', auth: 'authSecretBase64Url' } });
const sendText = async (f, from, to, cookie, text) => {
  const m = await sealMessage(text, [from.manifest], [to.manifest], from.session,
    { senderRoot: from.vault.signingKey, recipientRoot: to.vault.signingKey,
      senderGenesis: from.genesis, recipientGenesis: to.genesis });
  return (await operation(f, from, cookie, 'send', m)).result;
};

test('push subscriptions are device-bound, wake-only, SSRF-guarded and pruned on 410', async () => {
  const dataDir = await tempDir(), storageSecret = randomBytes(32).toString('hex');
  const vapidKeys = webPush.generateVAPIDKeys();
  const pushes = [];
  let failNext = null;
  const pushSender = async (sub, payload, opts) => {
    if (failNext) { const error = failNext; failNext = null; throw error; }
    pushes.push({ sub, payload, opts });
  };
  const f = await fixture({ dataDir, storageSecret, vapidKeys, pushSender });
  const alice = await identity('alice_push'), bob = await identity('bob_push');
  const ac = await f.login('synthetic-alice'), bc = await f.login('synthetic-bob');
  await register(f, alice, ac); await register(f, bob, bc);
  try {
    // Contract C6: the session endpoint exposes the VAPID PUBLIC key for
    // PushManager.subscribe (applicationServerKey), before and after login.
    // The private key must never appear in any response.
    const anon = await f.request('/api/session');
    assert.equal(anon.result.vapidPublicKey, vapidKeys.publicKey);
    assert.ok(!JSON.stringify(anon.result).includes(vapidKeys.privateKey));
    const authed = await f.request('/api/session', undefined, bc);
    assert.equal(authed.result.vapidPublicKey, vapidKeys.publicKey);
    assert.ok(!JSON.stringify(authed.result).includes(vapidKeys.privateKey));
    assert.equal((await operation(f, bob, bc, 'push.subscribe', subscription('bob1'))).result.subscribed, true);
    assert.equal((await sendText(f, alice, bob, ac, 'wake up')).accepted, true);
    assert.equal(pushes.length, 1);
    // Minimal metadata: no content, no refs, no account names in the payload.
    assert.deepEqual(pushes[0].payload, { type: 'wake' });
    assert.equal(pushes[0].opts.TTL, 60);
    assert.equal(pushes[0].sub.endpoint, subscription('bob1').endpoint);

    // Re-subscribe replaces the device endpoint; unsubscribe stops pushes.
    await operation(f, bob, bc, 'push.subscribe', subscription('bob2'));
    await sendText(f, alice, bob, ac, 'second');
    assert.equal(pushes.length, 2);
    assert.equal(pushes[1].sub.endpoint, subscription('bob2').endpoint);
    assert.equal((await operation(f, bob, bc, 'push.unsubscribe', null)).result.subscribed, false);
    await sendText(f, alice, bob, ac, 'third');
    assert.equal(pushes.length, 2);

    // SSRF guard and shape validation.
    for (const endpoint of ['http://push.example.com/x', 'https://127.0.0.1/x',
      'https://localhost/x', 'https://10.0.0.1/x', 'https://[::1]/x', 'https://shade.internal/x']) {
      assert.equal((await operation(f, bob, bc, 'push.subscribe',
        { endpoint, keys: subscription('x').keys })).response.status, 400, endpoint);
    }
    assert.equal((await operation(f, bob, bc, 'push.subscribe',
      { endpoint: 'https://push.example.com/x', keys: { p256dh: '!!!', auth: 'ok' } })).response.status, 400);

    // Gone endpoint (410): send still accepted, subscription pruned.
    await operation(f, bob, bc, 'push.subscribe', subscription('bob3'));
    failNext = Object.assign(new Error('gone'), { statusCode: 410 });
    assert.equal((await sendText(f, alice, bob, ac, 'fourth')).accepted, true);
    await sendText(f, alice, bob, ac, 'fifth');
    assert.equal(pushes.length, 2); // no push after pruning
  } finally { await f.close(); }

  // Unconfigured server fails closed.
  const f2 = await fixture({ dataDir: await tempDir(), storageSecret: randomBytes(32).toString('hex') });
  try {
    const session = await f2.request('/api/session');
    assert.equal(session.result.vapidPublicKey, null);
    const bob2 = await identity('bob_push2');
    const bc2 = await f2.login('synthetic-bob');
    await register(f2, bob2, bc2);
    const reply = await operation(f2, bob2, bc2, 'push.subscribe', subscription('x'));
    assert.equal(reply.response.status, 400);
    assert.equal(reply.result.error, 'push_not_configured');
  } finally { await f2.close(); }

  // Subscriptions persist across restart (encrypted snapshot).
  const f3 = await fixture({ dataDir, storageSecret, vapidKeys, pushSender });
  try {
    const ac3 = await f3.login('synthetic-alice'), bc3 = await f3.login('synthetic-bob');
    await operation(f3, bob, bc3, 'push.subscribe', subscription('bob4'));
    await sendText(f3, alice, bob, ac3, 'after restart');
    assert.equal(pushes.length, 3);
    assert.equal(pushes[2].sub.endpoint, subscription('bob4').endpoint);
  } finally { await f3.close(); }
});
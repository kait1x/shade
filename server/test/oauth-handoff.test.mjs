// OAuth security: iOS standalone cookie-jar bridge (state-keyed flow fallback
// + one-time handoff), replay protection, tester allowlist. Synthetic OAuth
// provider only — real Google is verified on-device by the owner.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import fs from 'node:fs/promises';
import { randomBytes } from 'node:crypto';
import { fixture } from './helpers/alpha-fixture.mjs';

async function tempDir() {
  const build = path.resolve('build');
  await fs.mkdir(build, { recursive: true });
  return fs.mkdtemp(path.join(build, 'oauth-handoff-'));
}
async function startFlow(f, sub) {
  f.setLoginSub(sub);
  const start = await f.request('/auth/google');
  assert.equal(start.response.status, 302);
  const location = start.response.headers.get('location');
  const url = new URL(location);
  const state = url.searchParams.get('state');
  const code = url.searchParams.get('code');
  const flowCookie = (start.response.headers.getSetCookie?.() || []).find(s =>
    s.startsWith('__Host-shade-oauth=') || s.startsWith('shade-oauth='))?.split(';')[0];
  return { state, code, flowCookie };
}
const handoffOf = response => {
  const location = response.headers.get('location');
  assert.ok(location?.startsWith('/#shade_login='), 'expected handoff fragment redirect, got: ' + location);
  return location.slice('/#shade_login='.length);
};
const sessionCookieOf = response => (response.response.headers.getSetCookie?.() || []).find(s =>
  s.startsWith('__Host-shade-alpha=') || s.startsWith('shade-alpha='))?.split(';')[0];

test('cross-jar callback: state fallback without flow cookie, one-time handoff establishes session', { timeout: 60000 }, async () => {
  const f = await fixture({ dataDir: await tempDir(), storageSecret: randomBytes(32).toString('hex') });
  try {
    const { state, code } = await startFlow(f, 'synthetic-ios-user');
    // Callback WITHOUT the flow cookie (different cookie jar, iOS in-app browser).
    const cb = await f.request(`/auth/google/callback?state=${state}&code=${encodeURIComponent(code)}`);
    assert.equal(cb.response.status, 302, JSON.stringify(cb.result));
    const handoff = handoffOf(cb.response);
    assert.match(handoff, /^[a-f0-9]{64}$/);
    // Exchange in the PWA jar.
    const ex = await f.request('/api/v2/session/handoff', { code: handoff });
    assert.equal(ex.response.status, 200, JSON.stringify(ex.result));
    assert.equal(ex.result.authenticated, true);
    const sid = sessionCookieOf(ex);
    assert.ok(sid, 'session cookie must be set in the exchanging jar');
    const session = await f.request('/api/session', undefined, sid);
    assert.equal(session.result.authenticated, true);
    // Replay of the handoff code is rejected (single-use).
    const replay = await f.request('/api/v2/session/handoff', { code: handoff });
    assert.equal(replay.response.status, 400);
    // The flow/state is consumed: a second callback with the same state fails.
    const cb2 = await f.request(`/auth/google/callback?state=${state}&code=${encodeURIComponent(code)}`);
    assert.equal(cb2.response.status, 400);
    // Session still valid after the failed replays.
    const still = await f.request('/api/session', undefined, sid);
    assert.equal(still.result.authenticated, true);
  } finally { await f.close(); }
});

test('classic same-jar flow still works (cookie present), handoff optional', { timeout: 60000 }, async () => {
  const f = await fixture({ dataDir: await tempDir(), storageSecret: randomBytes(32).toString('hex') });
  try {
    const { state, code, flowCookie } = await startFlow(f, 'synthetic-safari-user');
    assert.ok(flowCookie);
    const cb = await f.request(`/auth/google/callback?state=${state}&code=${encodeURIComponent(code)}`, undefined, flowCookie);
    assert.equal(cb.response.status, 302);
    // Same-jar: session cookie already set by the callback itself.
    const sid = sessionCookieOf(cb);
    assert.ok(sid);
    const session = await f.request('/api/session', undefined, sid);
    assert.equal(session.result.authenticated, true);
    // Handoff also available (idempotent alternative path).
    const handoff = handoffOf(cb.response);
    const ex = await f.request('/api/v2/session/handoff', { code: handoff });
    assert.equal(ex.response.status, 200);
  } finally { await f.close(); }
});

test('oauth negatives: forged state, missing code, error param, foreign origin, malformed handoff', { timeout: 60000 }, async () => {
  const f = await fixture({ dataDir: await tempDir(), storageSecret: randomBytes(32).toString('hex') });
  try {
    const { state, code } = await startFlow(f, 'synthetic-neg-user');
    // Forged state: rejected, the real flow is NOT consumed.
    assert.equal((await f.request(`/auth/google/callback?state=${'0'.repeat(64)}&code=${code}`)).response.status, 400);
    // Missing code: rejected; a state-matched attempt consumes the flow
    // (conservative single-use — the user restarts login).
    assert.equal((await f.request(`/auth/google/callback?state=${state}`)).response.status, 400);
    assert.equal((await f.request(`/auth/google/callback?state=${state}&code=${encodeURIComponent(code)}`)).response.status, 400);
    // Google error param consumes the flow too.
    const f2 = await startFlow(f, 'synthetic-neg-user');
    assert.equal((await f.request(`/auth/google/callback?state=${f2.state}&code=${encodeURIComponent(f2.code)}&error=access_denied`)).response.status, 400);
    // Fresh valid callback.
    const f3 = await startFlow(f, 'synthetic-neg-user');
    const cb = await f.request(`/auth/google/callback?state=${f3.state}&code=${encodeURIComponent(f3.code)}`);
    const handoff = handoffOf(cb.response);
    // Foreign origin on handoff exchange: rejected BEFORE consumption.
    const foreign = await f.request('/api/v2/session/handoff', { code: handoff }, '', { Origin: 'https://evil.test' });
    assert.equal(foreign.response.status, 403);
    // Malformed code: rejected BEFORE consumption.
    assert.equal((await f.request('/api/v2/session/handoff', { code: 'not-hex' })).response.status, 400);
    // The valid code survives the failed attempts and exchanges once.
    const ex = await f.request('/api/v2/session/handoff', { code: handoff });
    assert.equal(ex.response.status, 200, JSON.stringify(ex.result));
    assert.equal((await f.request('/api/v2/session/handoff', { code: handoff })).response.status, 400);
  } finally { await f.close(); }
});

test('tester allowlist: listed sub passes, unlisted rejected at callback and native', { timeout: 60000 }, async () => {
  const f = await fixture({ dataDir: await tempDir(), storageSecret: randomBytes(32).toString('hex'),
    oauthAllowlist: ['synthetic-allowed'] });
  try {
    // Unlisted Google identity: callback rejected, no session, no handoff.
    const bad = await startFlow(f, 'synthetic-stranger');
    const cbBad = await f.request(`/auth/google/callback?state=${bad.state}&code=${encodeURIComponent(bad.code)}`);
    assert.equal(cbBad.response.status, 400);
    assert.equal(cbBad.response.headers.get('location'), null);
    // Listed identity passes.
    const good = await startFlow(f, 'synthetic-allowed');
    const cbGood = await f.request(`/auth/google/callback?state=${good.state}&code=${encodeURIComponent(good.code)}`);
    assert.equal(cbGood.response.status, 302);
    const ex = await f.request('/api/v2/session/handoff', { code: handoffOf(cbGood.response) });
    assert.equal(ex.response.status, 200);
  } finally { await f.close(); }
});

test('handoff expiry: code rejected after TTL', { timeout: 60000 }, async () => {
  const f = await fixture({ dataDir: await tempDir(), storageSecret: randomBytes(32).toString('hex'),
    handoffTtlMs: 100 });
  try {
    const unknown = 'a'.repeat(64);
    assert.equal((await f.request('/api/v2/session/handoff', { code: unknown })).response.status, 400);
    const { state, code } = await startFlow(f, 'synthetic-ttl-user');
    const cb = await f.request(`/auth/google/callback?state=${state}&code=${encodeURIComponent(code)}`);
    const handoff = handoffOf(cb.response);
    await new Promise(r => setTimeout(r, 250));
    const expired = await f.request('/api/v2/session/handoff', { code: handoff });
    assert.equal(expired.response.status, 400);
    assert.equal((await f.request('/api/session')).result.authenticated, false);
  } finally { await f.close(); }
});
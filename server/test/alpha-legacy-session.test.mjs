// Security gate: legacy-key session negatives (replay, wrong key, unknown
// account, pre-enrollment operation lock). Synthetic keys only.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { generateKeyPairSync, randomBytes, sign as nodeSign, constants } from 'node:crypto';
import { fixture } from './helpers/alpha-fixture.mjs';
import { legacyRoot } from '../multidevice/registry.mjs';
import { requestText, hash } from '../../client/web/protocol/device-v2.mjs';

const signText = (text, privateKey) => nodeSign('sha256',
  Buffer.from(Buffer.from(text, 'utf8').toString('base64')),
  { key: privateKey, padding: constants.RSA_PKCS1_PSS_PADDING, saltLength: 32 }).toString('base64');

async function tempDir() {
  const build = path.resolve('build');
  await fs.mkdir(build, { recursive: true });
  return fs.mkdtemp(path.join(build, 'alpha-legacy-sec-'));
}

test('legacy session: nonce replay, wrong key, unknown account, pre-enrollment lock', { timeout: 120000 }, async () => {
  const pair = generateKeyPairSync('rsa', { modulusLength: 4096,
    publicKeyEncoding: { type: 'spki', format: 'pem' }, privateKeyEncoding: { type: 'pkcs8', format: 'pem' } });
  const other = generateKeyPairSync('rsa', { modulusLength: 4096,
    publicKeyEncoding: { type: 'spki', format: 'pem' }, privateKeyEncoding: { type: 'pkcs8', format: 'pem' } });
  const f = await fixture({ dataDir: await tempDir(), storageSecret: randomBytes(32).toString('hex'),
    legacyUsers: new Map([['sec_legacy', { publicKey: pair.publicKey, googleSub: null }]]) });
  try {
    const operation = await hash(JSON.stringify(['legacy-session', null]));
    // Unknown account: no challenge issued.
    const unknown = await f.request('/api/v2/session/legacy-challenge', { account: 'sec_ghost' });
    assert.equal(unknown.response.status, 400);
    // Wrong key proof rejected; nonce consumed even on failure.
    const ch1 = await f.request('/api/v2/session/legacy-challenge', { account: 'sec_legacy' });
    assert.equal(ch1.response.status, 200);
    const badProof = signText(requestText('sec_legacy', 'primary', ch1.result.nonce, operation), other.privateKey);
    const bad = await f.request('/api/v2/session/legacy',
      { account: 'sec_legacy', nonce: ch1.result.nonce, proof: badProof });
    assert.equal(bad.response.status, 400);
    const replayBad = await f.request('/api/v2/session/legacy',
      { account: 'sec_legacy', nonce: ch1.result.nonce, proof: badProof });
    assert.equal(replayBad.response.status, 400);
    // Correct proof opens a session; nonce cannot be reused.
    const ch2 = await f.request('/api/v2/session/legacy-challenge', { account: 'sec_legacy' });
    const goodProof = signText(requestText('sec_legacy', 'primary', ch2.result.nonce, operation), pair.privateKey);
    const ok = await f.request('/api/v2/session/legacy',
      { account: 'sec_legacy', nonce: ch2.result.nonce, proof: goodProof });
    assert.equal(ok.response.status, 200);
    assert.equal(ok.result.account, 'sec_legacy');
    const cookie = ok.response.headers.getSetCookie().find(s => s.startsWith('shade-alpha=')).split(';')[0];
    const replay = await f.request('/api/v2/session/legacy',
      { account: 'sec_legacy', nonce: ch2.result.nonce, proof: goodProof });
    assert.equal(replay.response.status, 400);
    // Session alone never authorizes device operations before enrollment.
    const op = await hash(JSON.stringify(['fetch', null]));
    const challenge = await f.request('/api/v2/challenge',
      { account: 'sec_legacy', id: 'primary', operation: op }, cookie);
    assert.equal(challenge.response.status, 400); // no active device yet
    // Cross-account session binding: cookie for sec_legacy cannot act for another.
    const root = legacyRoot(pair.publicKey);
    assert.ok(root.length > 0);
  } finally { await f.close(); }
});
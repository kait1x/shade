const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { createAuthProof } = require('../auth-proof');

test('private-key login proof cannot be replayed or used for another nickname', () => {
  const auth = createAuthProof();
  const { privateKey, publicKey } = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
  const challenge = auth.issue('alice');
  const proof = crypto.sign('sha256', Buffer.from(Buffer.from(`shade-register:v1:alice:${challenge}`).toString('base64')),
    { key: privateKey, padding: crypto.constants.RSA_PKCS1_PSS_PADDING, saltLength: 32 }).toString('base64');
  assert.equal(auth.verify({ username: 'alice', challenge, proof, publicKey }), true);
  assert.equal(auth.verify({ username: 'alice', challenge, proof, publicKey }), false);
  assert.equal(auth.issue('../invalid'), null);
  assert.equal(auth.verify({ username: 'bob', challenge: auth.issue('alice'), proof, publicKey }), false);
});

test('Google verifier requires configured audience, subject and verified email', async () => {
  const auth = createAuthProof({ audience: 'web-client-id', verifyGoogle: async (token, audience) => {
    assert.equal(token, 'token-from-native-sdk');
    assert.equal(audience, 'web-client-id');
    return { sub: 'google-subject', email: 'test@example.com', email_verified: true, name: 'Test' };
  } });
  assert.equal((await auth.googleProfile('token-from-native-sdk')).googleSub, 'google-subject');
  const invalid = createAuthProof({ audience: 'id', verifyGoogle: async () => ({ sub: 'x', email_verified: false }) });
  await assert.rejects(invalid.googleProfile('token'));
  await assert.rejects(createAuthProof({ audience: '' }).googleProfile('token'));
});

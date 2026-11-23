import assert from 'node:assert/strict';
import test from 'node:test';
import { encryptRecord, decryptRecord } from '../../client/web/device_crypto.mjs';
import { unb64 } from '../../client/web/protocol/device-v2.mjs';

test('web vault can reopen encrypted history with a multi-megabyte ciphertext', async () => {
  const storage = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
  const session = { account: 'alice', id: 'primary', storage };
  const history = { messages: [{ image: 'A'.repeat(12 * 1024 * 1024) }] };
  const record = await encryptRecord(session, 'state', history);

  assert.ok(record.ciphertext.length > 16 * 1024 * 1024);
  assert.deepEqual(await decryptRecord(session, 'state', record), history);
});

test('base64 decoder still rejects invalid alphabet, padding and lengths', () => {
  for (const value of ['', 'AAAA\n', 'AAA\n', 'A===', '==AA', 'AA=A', 'AA-_', 'AAA']) {
    assert.throws(() => unb64(value), /Invalid protocol data/);
  }
  assert.throws(() => unb64('AAAA', 3), /Invalid protocol data/);
  assert.deepEqual(unb64('AA=='), Uint8Array.of(0));
  assert.deepEqual(unb64('AAE='), Uint8Array.of(0, 1));
  assert.deepEqual(unb64('AAEC'), Uint8Array.of(0, 1, 2));
});

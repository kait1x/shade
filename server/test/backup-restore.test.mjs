// Тест механизма backup/restore (синтетический снапшот, без реальных данных):
// рестарт из снапшота сохраняет каталоги/очереди/квитанции и E2EE-читаемость;
// подменённый манифест в снапшоте отклоняется fail-closed при загрузке.
// Реальный restore-тест на копии staging-данных — отдельный шаг P5 с «го».
import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { createDeviceRegistry, operationDigest } from '../multidevice/registry.mjs';
import { createVault, unlockVault, descriptor, createRecoveryBackup, finalizeRecoveryBackup,
  createGenesis, approveDevices, pairingProof, sealMessage, openMessage } from '../../client/web/device_crypto.mjs';
import { sign, requestText, hash, messageText } from '../../client/web/protocol/device-v2.mjs';

const password = 'synthetic device password 2026 only';
const recoveryPassword = 'independent synthetic offline recovery passphrase only';
let alice, bob;
async function identity(account) {
  const vault = await createVault(account, password);
  const session = await unlockVault(vault, password);
  let backup = await createRecoveryBackup(account, vault.signingKey, recoveryPassword);
  const genesis = await createGenesis(vault, session, backup.publicKey);
  backup = await finalizeRecoveryBackup(backup, recoveryPassword, genesis);
  const manifest = await approveDevices(genesis, [], [descriptor(vault)], session);
  return { vault, session, genesis, backup, manifest };
}
before(async () => { alice = await identity('br_alice'); bob = await identity('br_bob'); });
const trust = (a, b) => ({ senderRoot: a.genesis.firstDevice.signingKey,
  recipientRoot: b.genesis.firstDevice.signingKey, senderGenesis: a.genesis, recipientGenesis: b.genesis });
async function authenticate(registry, session, operation) {
  const nonce = registry.challenge(session.account, session.id, operation);
  return { account: session.account, id: session.id, nonce,
    proof: await sign(requestText(session.account, session.id, nonce, operation), session.signing) };
}

test('restore from snapshot preserves directories, queues and E2EE readability', async () => {
  let saved;
  const r1 = await createDeviceRegistry({ users: new Map(), persist: async s => { saved = s; },
    verifyGoogle: async token => ({ googleSub: token }) });
  for (const who of [alice, bob]) {
    await r1.register({ genesis: who.genesis, manifest: who.manifest,
      googleIdToken: `verified:${who.genesis.account}`, proofs: [await pairingProof(who.vault, who.session)] });
  }
  const text = 'сообщение до бэкапа 🔐';
  const m = await sealMessage(text, [alice.manifest], [bob.manifest], alice.session, trust(alice, bob));
  await r1.send(m, await authenticate(r1, alice.session, await operationDigest('send', await hash(messageText(m)))));
  assert.ok(saved && saved.receipts && saved.queues);
  // «Рестарт»: новый registry из снапшота (как boot из восстановленного бэкапа).
  const r2 = await createDeviceRegistry({ users: new Map(), snapshot: structuredClone(saved),
    persist: async () => true, verifyGoogle: async token => ({ googleSub: token }) });
  const dir = r2.directory('br_bob');
  assert.equal(dir.history.length, 1);
  assert.equal(dir.history[0].signature, bob.manifest.signature);
  const inbox = await r2.fetch(await authenticate(r2, bob.session, await operationDigest('fetch')));
  const bundle = inbox.find(b => b.message.id === m.id);
  assert.ok(bundle, 'очередь пережила восстановление');
  assert.equal(await openMessage(bundle, bob.session, trust(alice, bob)), text);
});

test('tampered manifest signature in snapshot is rejected fail-closed at load', async () => {
  let saved;
  const r1 = await createDeviceRegistry({ users: new Map(), persist: async s => { saved = s; },
    verifyGoogle: async token => ({ googleSub: token }) });
  await r1.register({ genesis: alice.genesis, manifest: alice.manifest,
    googleIdToken: 'verified:br_alice', proofs: [await pairingProof(alice.vault, alice.session)] });
  const bad = structuredClone(saved);
  bad.accounts.br_alice.history[0].signature = 'A'.repeat(684);
  await assert.rejects(() => createDeviceRegistry({ users: new Map(), snapshot: bad,
    persist: async () => true, verifyGoogle: async token => ({ googleSub: token }) }), /signature|подпис|Invalid|verify/i);
});
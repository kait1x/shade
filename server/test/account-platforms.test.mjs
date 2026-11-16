import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { createDeviceRegistry, operationDigest } from '../multidevice/registry.mjs';
import { createVault, unlockVault, descriptor, createRecoveryBackup, finalizeRecoveryBackup,
  unlockRecoveryBackup, createGenesis, approveDevices, pairingProof, sealMessage, openMessage } from '../../client/web/device_crypto.mjs';
import { sign, requestText, hash, messageText, manifestText, verifyHistory } from '../../client/web/protocol/device-v2.mjs';

const password = 'synthetic device password 2026 only';
const recoveryPassword = 'independent synthetic offline recovery passphrase only';
let web, desktop, second;
async function device(account) {
  const vault = await createVault(account, password);
  return { vault, session: await unlockVault(vault, password), descriptor: descriptor(vault) };
}
async function identity(account) {
  const d = await device(account);
  let backup = await createRecoveryBackup(account, d.vault.signingKey, recoveryPassword);
  const genesis = await createGenesis(d.vault, d.session, backup.publicKey);
  backup = await finalizeRecoveryBackup(backup, recoveryPassword, genesis);
  const manifest = await approveDevices(genesis, [], [d.descriptor], d.session);
  return { ...d, genesis, backup, manifest };
}
before(async () => {
  web = await identity('web_only'); desktop = await identity('desktop_only'); second = await device('web_only');
});
function fixture() {
  let saved, now = Date.now();
  return { create: () => createDeviceRegistry({ users: new Map(), clock: () => now,
    persist: async snapshot => { saved = snapshot; }, verifyGoogle: async token => {
      if (!['verified:web_only', 'verified:desktop_only'].includes(token)) throw Error('Invalid Google token');
      return { googleSub: token };
    } }), saved: () => saved, advance: ms => { now += ms; }, now: () => now };
}
async function register(registry, identity) {
  return registry.register({ genesis: identity.genesis, manifest: identity.manifest,
    googleIdToken: `verified:${identity.genesis.account}`, proofs: [await pairingProof(identity.vault, identity.session)] });
}
async function authenticate(registry, session, operation) {
  const nonce = registry.challenge(session.account, session.id, operation);
  return { account: session.account, id: session.id, nonce,
    proof: await sign(requestText(session.account, session.id, nonce, operation), session.signing) };
}
const trust = (sender, recipient) => ({ senderRoot: sender.genesis.firstDevice.signingKey,
  recipientRoot: recipient.genesis.firstDevice.signingKey, senderGenesis: sender.genesis, recipientGenesis: recipient.genesis });

test('iPhone/Web-first and desktop-only accounts register and exchange E2EE without an Android or legacy root', async () => {
  const r = await fixture().create();
  await register(r, web); await register(r, desktop);
  for (const [from, to] of [[web, desktop], [desktop, web]]) {
    const text = `${from.genesis.account} → ${to.genesis.account} 🔐`;
    const m = await sealMessage(text, [from.manifest], [to.manifest], from.session, trust(from, to));
    await r.send(m, await authenticate(r, from.session, await operationDigest('send', await hash(messageText(m)))));
    const inbox = await r.fetch(await authenticate(r, to.session, await operationDigest('fetch')));
    assert.equal(await openMessage(inbox.find(b => b.message.id === m.id), to.session, trust(from, to)), text);
  }
});
test('Google establishes account registration, but cannot assign keys, replace an identity or link a device', async () => {
  const r = await fixture().create();
  await assert.rejects(r.register({ genesis: web.genesis, manifest: web.manifest,
    googleIdToken: 'invalid', proofs: [await pairingProof(web.vault, web.session)] }), /Google/);
  await register(r, web);
  await assert.rejects(register(r, web), /already exists/);
  const forged = structuredClone(web.manifest); forged.revision = 2; forged.previous = await hash('invalid predecessor');
  forged.signature = 'server-assigned-key';
  await assert.rejects(r.install(forged));
});
test('a trusted second device can approve a roster and revoke the first device; Android is never a mandatory controller', async () => {
  const r = await fixture().create(); await register(r, web);
  const two = await approveDevices(web.genesis, [web.manifest], [web.descriptor, second.descriptor], web.session);
  await r.install(two, [await pairingProof(second.vault, second.session)]);
  const onlySecond = await approveDevices(web.genesis, [web.manifest, two], [second.descriptor], second.session);
  await r.install(onlySecond);
  assert.equal(r.directory('web_only').history.at(-1).devices.length, 1);
  assert.equal(r.directory('web_only').root, web.vault.signingKey);
  assert.throws(() => r.challenge('web_only', web.session.id, '0'.repeat(64)), /Revoked/);
  const fake = structuredClone(onlySecond);
  fake.revision = 4; fake.previous = await hash(manifestText(onlySecond));
  fake.signer = web.session.id;
  fake.signature = await sign(manifestText(fake), web.session.signing);
  await assert.rejects(r.install(fake), /unauthorized/);
});
test('offline encrypted recovery authorizes fresh device keys after losing the first/only device', async () => {
  const r = await fixture().create(); await register(r, web);
  const recovery = await unlockRecoveryBackup(JSON.parse(JSON.stringify(web.backup)), recoveryPassword, web.genesis);
  assert.equal(recovery.signing.extractable, false);
  const recovered = await approveDevices(web.genesis, [web.manifest], [second.descriptor], recovery);
  await r.install(recovered, [await pairingProof(second.vault, second.session)]);
  assert.equal(r.directory('web_only').root, web.vault.signingKey);
  assert.equal(r.directory('web_only').genesis.recoveryKey, web.backup.publicKey);
  assert.throws(() => r.challenge('web_only', web.session.id, '0'.repeat(64)), /Revoked/);
  await r.fetch(await authenticate(r, second.session, await operationDigest('fetch')));
  // The backup contains only its own independent recovery key, not device PKCS8.
  assert.equal(JSON.stringify(web.backup).includes(password), false);
});
test('wrong recovery secret, substituted genesis, stolen Google account and revoked keys cannot recover access', async () => {
  await assert.rejects(unlockRecoveryBackup(web.backup, 'wrong recovery passphrase', web.genesis));
  const substituted = structuredClone(web.genesis); substituted.nonce = 'f'.repeat(64);
  await assert.rejects(unlockRecoveryBackup(web.backup, recoveryPassword, substituted), /exact account genesis/);
  await assert.rejects(unlockRecoveryBackup(desktop.backup, recoveryPassword, web.genesis), /identity mismatch/);
  const r = await fixture().create(); await register(r, web);
  const recovery = await unlockRecoveryBackup(web.backup, recoveryPassword, web.genesis);
  const recovered = await approveDevices(web.genesis, [web.manifest], [second.descriptor], recovery);
  await r.install(recovered, [await pairingProof(second.vault, second.session)]);
  await assert.rejects(approveDevices(web.genesis, [web.manifest, recovered], [web.descriptor], recovery), /resurrected/);
});
test('recovery remains possible after the old roster lease expires; legacy identity anchor remains unchanged', async () => {
  const f = fixture(), r = await f.create(); await register(r, web); f.advance(2 * 86400000);
  const recovery = await unlockRecoveryBackup(web.backup, recoveryPassword, web.genesis);
  const recovered = await approveDevices(web.genesis, [web.manifest], [second.descriptor], recovery, null, f.now());
  await r.install(recovered, [await pairingProof(second.vault, second.session, f.now())]);
  assert.equal(r.directory('web_only').history.at(-1).signer, 'recovery');
});
test('new account snapshots restart locally without a preexisting Android user record', async () => {
  const f = fixture(), r = await f.create(); await register(r, web);
  const restarted = await createDeviceRegistry({ users: new Map(), snapshot: f.saved(), persist: async () => true });
  assert.equal(restarted.directory('web_only').genesis.firstDevice.id, web.session.id);
  await restarted.fetch(await authenticate(restarted, web.session, await operationDigest('fetch')));
});
test('all allowed devices receive independent ciphertext; removing the first device does not stop future messages', async () => {
  const r = await fixture().create(); await register(r, web); await register(r, desktop);
  const two = await approveDevices(web.genesis, [web.manifest], [web.descriptor, second.descriptor], web.session);
  await r.install(two, [await pairingProof(second.vault, second.session)]);
  const m = await sealMessage('to both devices', [desktop.manifest], [web.manifest, two], desktop.session, trust(desktop, web));
  assert.equal(m.envelopes.filter(e => e.account === 'web_only').length, 2);
  assert.equal(m.envelopes.length, 3); assert.notEqual(m.envelopes[0].payload.d, m.envelopes[1].payload.d);
  await r.send(m, await authenticate(r, desktop.session, await operationDigest('send', await hash(messageText(m)))));
  for (const d of [web, second]) {
    const inbox = await r.fetch(await authenticate(r, d.session, await operationDigest('fetch')));
    assert.equal(await openMessage(inbox[0], d.session, trust(desktop, web)), 'to both devices');
  }
  const three = await approveDevices(web.genesis, [web.manifest, two], [second.descriptor], second.session);
  await r.install(three);
  const latest = await sealMessage('after first device removed', [desktop.manifest], [web.manifest, two, three], desktop.session, trust(desktop, web));
  const recipientCopies = latest.envelopes.filter(e => e.account === 'web_only');
  assert.equal(recipientCopies.length, 1); assert.equal(recipientCopies[0].deviceId, second.session.id);
  await r.send(latest, await authenticate(r, desktop.session, await operationDigest('send', await hash(messageText(latest)))));
  const inbox = await r.fetch(await authenticate(r, second.session, await operationDigest('fetch')));
  assert.equal(await openMessage(inbox.at(-1), second.session, trust(desktop, web)), 'after first device removed');
  const pin = await verifyHistory([web.manifest, two, three], web.vault.signingKey, null, Date.now(), web.genesis);
  await assert.rejects(verifyHistory([web.manifest], web.vault.signingKey, pin, Date.now(), web.genesis), /rollback/);
});

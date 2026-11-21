// Test-only bridge: real alpha.mjs HTTP server with a synthetic web identity
// whose recovery package is FINALIZED (pinned to the exact genesis). The Dart
// V2ChatRepository performs recoverWithBackup against the REAL server; this
// bridge only owns the synthetic identity and read-only assertions. No
// production data, no real keys.
import readline from 'node:readline';
import fs from 'node:fs/promises';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import { fixture, register } from '../test/helpers/alpha-fixture.mjs';
import { createVault, unlockVault, descriptor, createRecoveryBackup,
  finalizeRecoveryBackup, createGenesis, approveDevices } from '../../client/web/device_crypto.mjs';
import { operationDigest } from '../multidevice/registry.mjs';

const account = 'native_rec';
const devicePhrase = 'synthetic recovery device passphrase 2026';
const recoveryPhrase = 'independent synthetic offline recovery passphrase only';
let f, who;
console.log(JSON.stringify({ ready: true }));
for await (const line of readline.createInterface({ input: process.stdin })) {
  try {
    const request = JSON.parse(line);
    let result;
    if (request.action === 'init') {
      const build = path.resolve('../server/build');
      await fs.mkdir(build, { recursive: true });
      const dataDir = await fs.mkdtemp(path.join(build, 'alpha-native-recovery-'));
      f = await fixture({ dataDir, storageSecret: randomBytes(32).toString('hex') });
      const vault = await createVault(account, devicePhrase);
      const session = await unlockVault(vault, devicePhrase);
      let backup = await createRecoveryBackup(account, vault.signingKey, recoveryPhrase);
      const genesis = await createGenesis(vault, session, backup.publicKey);
      backup = await finalizeRecoveryBackup(backup, recoveryPhrase, genesis);
      const manifest = await approveDevices(genesis, [], [descriptor(vault)], session);
      who = { vault, session, genesis, backup, manifest };
      await register(f, who, await f.login('synthetic-native-rec'));
      result = { origin: f.origin, account, recoveryPhrase,
        package: { backup, genesis }, oldDeviceId: session.id };
    } else if (request.action === 'snapshot') {
      // Read-only server state for assertions: retired devices and the tip.
      const snap = f.registry.exportSnapshot();
      const tip = f.registry.directory(account).history.at(-1);
      result = { retired: snap.accounts[account].retired, revision: tip.revision,
        signer: tip.signer, devices: tip.devices.map(d => d.id) };
    } else if (request.action === 'old-challenge') {
      // После восстановления старое устройство больше не получает challenge.
      // Запрос с валидной Google-сессией аккаунта: без сессии сервер вернул бы
      // 401 login_required, а не отказ по ростеру.
      const operation = await operationDigest('fetch');
      const cookie = await f.login('synthetic-native-rec');
      const reply = await f.request('/api/v2/challenge',
        { account, id: who.session.id, operation }, cookie);
      result = { status: reply.response.status };
    } else throw Error('Unknown test action');
    console.log(JSON.stringify({ ok: true, result }));
  } catch (error) {
    console.log(JSON.stringify({ ok: false, error: error.message }));
  }
}
await f?.close();
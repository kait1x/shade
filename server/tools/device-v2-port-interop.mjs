// Test-only bridge for the Dart device-v2 port (DeviceV2Crypto). Synthetic
// browser keys stay in this process; only public data, ciphertext, test
// plaintext and signatures cross stdin/stdout. No production data is touched.
import readline from 'node:readline';
import * as c from '../../client/web/device_crypto.mjs';
import { verify, verifyGenesis, verifyHistory } from '../../client/web/protocol/device-v2.mjs';
import { legacyRoot } from '../multidevice/registry.mjs';

const vaultPhrase = 'synthetic test vault password only';
const recoveryPhrase = 'synthetic independent recovery password only';
const web = await c.createVault('port_web', vaultPhrase);
const webSession = await c.unlockVault(web, vaultPhrase);
const webRecovery = await c.createRecoveryBackup('port_web', web.signingKey, recoveryPhrase);
const webGenesis = await c.createGenesis(web, webSession, webRecovery.publicKey);
const webManifest = await c.approveDevices(webGenesis, [], [c.descriptor(web)], webSession);
const webBackup = await c.finalizeRecoveryBackup(webRecovery, recoveryPhrase, webGenesis);
let native = null;
console.log(JSON.stringify({ ready: true, web: {
  descriptor: c.descriptor(web), genesis: webGenesis, manifest: webManifest,
  root: web.signingKey, recovery: { backup: webBackup, genesis: webGenesis, phrase: recoveryPhrase } } }));
for await (const line of readline.createInterface({ input: process.stdin })) {
  try {
    const request = JSON.parse(line);
    let result;
    if (request.action === 'accept-native') {
      const root = legacyRoot(request.publicKey);
      await verifyGenesis(request.genesis, root);
      await verifyHistory([request.manifest], root, null, Date.now(), request.genesis);
      native = { root, genesis: request.genesis, manifest: request.manifest };
      result = { accepted: true };
    } else if (request.action === 'web-seal') {
      if (!native) throw Error('native roster missing');
      const message = await c.sealMessage(request.text, [webManifest], [native.manifest], webSession,
        { senderRoot: web.signingKey, recipientRoot: native.root,
          senderGenesis: webGenesis, recipientGenesis: native.genesis });
      result = { message, senderHistory: [webManifest], recipientHistory: [native.manifest] };
    } else if (request.action === 'native-open') {
      if (!native) throw Error('native roster missing');
      result = { plaintext: await c.openMessage(
        { message: request.message, senderHistory: [native.manifest], recipientHistory: [webManifest] },
        webSession, { senderRoot: native.root, recipientRoot: web.signingKey,
          senderGenesis: native.genesis, recipientGenesis: webGenesis }) };
    } else if (request.action === 'unlock-dart-recovery') {
      const recovery = await c.unlockRecoveryBackup(request.backup, request.phrase, request.genesis);
      const probe = Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString('base64');
      const { sign } = await import('../../client/web/protocol/device-v2.mjs');
      result = { probe, signature: await sign(probe, recovery.signing), publicKey: request.backup.publicKey };
    } else if (request.action === 'verify-recovery-signature') {
      result = { valid: await verify(request.probe, request.signature, request.publicKey) };
    } else throw Error('Unknown test action');
    console.log(JSON.stringify({ ok: true, result }));
  } catch (error) {
    console.log(JSON.stringify({ ok: false, error: error.message }));
  }
}
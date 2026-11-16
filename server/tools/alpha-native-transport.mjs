// Test-only bridge: real alpha.mjs HTTP/WSS server with synthetic OAuth and a
// synthetic legacy Android user. The Dart AlphaTransport talks to the real
// server directly; this bridge only owns the WebCrypto peer. No production
// data, no real keys.
import readline from 'node:readline';
import fs from 'node:fs/promises';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import { fixture, identity, register, operation } from '../test/helpers/alpha-fixture.mjs';
import { legacyRoot, messageRef } from '../multidevice/registry.mjs';
import { sealMessage, openMessage } from '../../client/web/device_crypto.mjs';

let f, web, wc, nc, nativeGenesis, nativeManifest, nativeRoot;
const nativeAccount = 'native_android';
console.log(JSON.stringify({ ready: true }));
for await (const line of readline.createInterface({ input: process.stdin })) {
  try {
    const request = JSON.parse(line);
    let result;
    if (request.action === 'init') {
      const build = path.resolve('../server/build');
      await fs.mkdir(build, { recursive: true });
      const dataDir = await fs.mkdtemp(path.join(build, 'alpha-transport-'));
      nativeRoot = legacyRoot(request.publicKey);
      f = await fixture({ dataDir, storageSecret: randomBytes(32).toString('hex'),
        legacyUsers: new Map([[nativeAccount, { publicKey: request.publicKey, googleSub: 'synthetic-native' }]]) });
      web = await identity('native_web');
      wc = await f.login('synthetic-web');
      nc = await f.login('synthetic-native');
      await register(f, web, wc);
      result = { origin: f.origin, nativeCookie: nc, web: {
        root: web.vault.signingKey, genesis: web.genesis, manifest: web.manifest,
        descriptor: { id: web.session.id, encryptionKey: web.vault.encryptionKey, signingKey: web.vault.signingKey },
        publicKey: `-----BEGIN PUBLIC KEY-----\n${web.vault.encryptionKey}\n-----END PUBLIC KEY-----`,
        signingKey: `-----BEGIN PUBLIC KEY-----\n${web.vault.signingKey}\n-----END PUBLIC KEY-----` } };
    } else if (request.action === 'accept-native') {
      nativeGenesis = request.genesis; nativeManifest = request.manifest;
      result = { accepted: true };
    } else if (request.action === 'web-send') {
      const trust = { senderRoot: web.vault.signingKey, recipientRoot: nativeRoot,
        senderGenesis: web.genesis, recipientGenesis: nativeGenesis };
      const m = await sealMessage(request.text, [web.manifest], [nativeManifest], web.session, trust);
      const sent = await operation(f, web, wc, 'send', m);
      if (!sent.result.accepted) throw Error('send rejected');
      result = { ref: messageRef(m) };
    } else if (request.action === 'web-fetch-open') {
      const inbox = (await operation(f, web, wc, 'fetch')).result;
      const bundle = inbox.find(b => b.message.from === nativeAccount);
      if (!bundle) throw Error('no native message in web inbox');
      const trust = { senderRoot: nativeRoot, recipientRoot: web.vault.signingKey,
        senderGenesis: nativeGenesis, recipientGenesis: web.genesis };
      const plaintext = await openMessage(bundle, web.session, trust);
      const ref = messageRef(bundle.message);
      await operation(f, web, wc, 'ack', [ref]);
      result = { plaintext, ref };
    } else if (request.action === 'web-status') {
      result = (await operation(f, web, wc, 'status', [request.ref])).result;
    } else throw Error('Unknown test action');
    console.log(JSON.stringify({ ok: true, result }));
  } catch (error) {
    console.log(JSON.stringify({ ok: false, error: error.message }));
  }
}
await f?.close();
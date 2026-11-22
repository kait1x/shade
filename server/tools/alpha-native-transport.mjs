// Test-only bridge: real alpha.mjs HTTP/WSS server with synthetic OAuth and a
// synthetic legacy Android user. The Dart AlphaTransport talks to the real
// server directly; this bridge only owns the WebCrypto peer. No production
// data, no real keys.
import readline from 'node:readline';
import fs from 'node:fs/promises';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { randomBytes, createHash } from 'node:crypto';
import { fixture, identity, register, operation, stickers } from '../test/helpers/alpha-fixture.mjs';
import { buildV1Fixture, writeV1Queue } from '../test/helpers/v1-fixture.mjs';
import { legacyRoot, messageRef } from '../multidevice/registry.mjs';
import { sealMessage, openMessage } from '../../client/web/device_crypto.mjs';

// Alpha wire payload agreement (mirror of alpha-client.mjs, zcode/pwa-parity).
const REPLY_PREVIEW_LIMIT = 2000;
function encodePayload(text, reply) {
  return JSON.stringify({ shade: 1, t: text, r: { ref: reply.ref, from: reply.from,
    text: reply.text.slice(0, REPLY_PREVIEW_LIMIT) } });
}
function decodePayload(payload) {
  try {
    const parsed = JSON.parse(payload);
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed) &&
      parsed.shade === 1 && typeof parsed.t === 'string' &&
      (parsed.r === null || parsed.r === undefined || (typeof parsed.r === 'object' &&
        typeof parsed.r.ref === 'string' && typeof parsed.r.from === 'string' &&
        typeof parsed.r.text === 'string'))) {
      return { text: parsed.t, reply: parsed.r ? { ref: parsed.r.ref, from: parsed.r.from,
        text: parsed.r.text } : null };
    }
  } catch { /* JSON-like plain text renders unchanged. */ }
  return { text: payload, reply: null };
}

let f, web, wc, nc, nativeGenesis, nativeManifest, nativeRoot;
let bridgeV1Dir, bridgeSecret, bridgeQueues, bridgeAckPath;
const nativeAccount = 'native_android';
console.log(JSON.stringify({ ready: true }));
for await (const line of readline.createInterface({ input: process.stdin })) {
  try {
    const request = JSON.parse(line);
    let result;
    if (request.action === 'init-registration') {
      const build = path.resolve('../server/build');
      await fs.mkdir(build, { recursive: true });
      const dataDir = await fs.mkdtemp(path.join(build, 'alpha-registration-'));
      f = await fixture({ dataDir, storageSecret: randomBytes(32).toString('hex') });
      result = { origin: f.origin, cookie: await f.login('synthetic-native') };
    } else if (request.action === 'init-bridge') {
      // Full v1->v2 bridge E2E: synthetic v1 store in the REAL at-rest format,
      // operator CLI prepare, alpha with read-only legacySource, Google-linked
      // legacy account. Dart enrolls and drains the bridged v1 queue.
      const build = path.resolve('../server/build');
      await fs.mkdir(build, { recursive: true });
      bridgeV1Dir = await fs.mkdtemp(path.join(build, 'v1-bridge-'));
      const targetBase = await fs.mkdtemp(path.join(build, 'alpha-bridge-'));
      const targetDir = path.join(targetBase, 'store');
      bridgeSecret = randomBytes(32).toString('hex');
      const targetSecret = randomBytes(32).toString('hex');
      bridgeAckPath = path.join(targetBase, 'bridge-ack.json');
      const id1 = randomBytes(16).toString('hex'), id2 = randomBytes(16).toString('hex');
      const photoB64 = Buffer.from(Array.from({ length: 64 }, (_, i) => i)).toString('base64');
      await buildV1Fixture(bridgeV1Dir, { secret: bridgeSecret, users: [
        { account: nativeAccount, googleSub: 'synthetic-native', publicKey: request.publicKey },
        { account: 'v1_peer' },
      ], messages: [
        { to: nativeAccount, from: 'v1_peer', id: id1, text: 'v1 текст до миграции' },
        { to: nativeAccount, from: 'v1_peer', id: id2, text: `IMG:${photoB64}` },
      ] });
      bridgeQueues = new Map([[nativeAccount, [
        { id: id1, from: 'v1_peer', timestamp: Date.now(), data: null },
      ]]]);
      execFileSync(process.execPath,
        ['tools/migrate-v1-to-v2.mjs', 'prepare', '--source', bridgeV1Dir, '--target', targetDir, '--all'],
        { cwd: path.resolve('../server'), env: { ...process.env, ALPHA_STORAGE_SECRET: targetSecret }, stdio: 'pipe' });
      nativeRoot = legacyRoot(request.publicKey);
      const { openV1Source } = await import('../multidevice/v1-source.mjs');
      const srcCheck = await openV1Source(bridgeV1Dir, { secret: bridgeSecret });
      const keyMatch = srcCheck.users.get(nativeAccount)?.publicKey === request.publicKey;
      f = await fixture({ dataDir: targetDir, storageSecret: targetSecret,
        legacySource: { dataDir: bridgeV1Dir },
        guardFile: path.join(targetBase, 'guard.json'), bridgeAckFile: bridgeAckPath });
      web = await identity('native_web');
      wc = await f.login('synthetic-web');
      nc = await f.login('synthetic-native');
      await register(f, web, wc);
      result = { origin: f.origin, nativeCookie: nc, bridgeAckPath, queuedIds: [id1, id2], keyMatch,
        web: { root: web.vault.signingKey, genesis: web.genesis, manifest: web.manifest } };
    } else if (request.action === 'v1-send') {
      // A v1 sender enqueues AFTER enrollment: the live top-up must deliver it.
      const id = randomBytes(16).toString('hex');
      const { v1Seal } = await import('../test/helpers/v1-fixture.mjs');
      const src = await import('../multidevice/v1-source.mjs').then(m => m.openV1Source(bridgeV1Dir, { secret: bridgeSecret }));
      // Ciphertext is sealed to the RECIPIENT's (native device) public key.
      const recipient = src.users.get(nativeAccount);
      const current = await src.queueFor(nativeAccount);
      const merged = [...current.map(e => ({ id: e.id, from: e.from, timestamp: e.timestamp, data: e.data })),
        { id, from: 'v1_peer', timestamp: Date.now(), data: v1Seal(request.text, recipient.publicKey) }];
      bridgeQueues.set(nativeAccount, merged);
      await writeV1Queue(bridgeV1Dir, bridgeSecret, bridgeQueues);
      result = { id };
    } else if (request.action === 'init') {
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
    } else if (request.action === 'web-gift-native') {
      const gift = await stickers(f, web, wc, 'POST', '/stickers/gift', {
        toUsername: nativeAccount, stickerId: 'flowers', note: 'Test gift', requestId: randomBytes(16).toString('hex')
      });
      if (gift.response.status !== 200) throw Error(JSON.stringify(gift.result));
      result = gift.result;
    } else if (request.action === 'web-send') {
      const trust = { senderRoot: web.vault.signingKey, recipientRoot: nativeRoot,
        senderGenesis: web.genesis, recipientGenesis: nativeGenesis };
      if (request.media) {
        // Media chunk contract (DEVICE_V2_API §5): RAW_CHUNK = 32768.
        const bytes = Buffer.from(request.media, 'base64');
        const total = Math.ceil(bytes.length / 32768);
        const mediaId = randomBytes(16).toString('hex');
        for (let index = 0; index < total; index++) {
          const chunk = bytes.subarray(index * 32768, (index + 1) * 32768).toString('base64');
          const payload = JSON.stringify({ shade: 1, m: { id: mediaId, mime: 'image/jpeg', index, total, chunk } });
          const m = await sealMessage(payload, [web.manifest], [nativeManifest], web.session, trust);
          if (!(await operation(f, web, wc, 'send', m)).result.accepted) throw Error('media send rejected');
        }
        result = { mediaId, total };
      } else {
        const m = await sealMessage(request.reply ? encodePayload(request.text, request.reply) : request.text,
          [web.manifest], [nativeManifest], web.session, trust);
        const sent = await operation(f, web, wc, 'send', m);
        if (!sent.result.accepted) throw Error('send rejected');
        result = { ref: messageRef(m) };
      }
    } else if (request.action === 'web-fetch-media') {
      const inbox = (await operation(f, web, wc, 'fetch')).result;
      const trust = { senderRoot: nativeRoot, recipientRoot: web.vault.signingKey,
        senderGenesis: nativeGenesis, recipientGenesis: web.genesis };
      const parts = [];
      const refs = [];
      for (const bundle of inbox.filter(b => b.message.from === nativeAccount)) {
        const plaintext = await openMessage(bundle, web.session, trust);
        refs.push(messageRef(bundle.message));
        const parsed = JSON.parse(plaintext);
        if (parsed.shade === 1 && parsed.m) parts[parsed.m.index] = Buffer.from(parsed.m.chunk, 'base64');
      }
      if (refs.length) await operation(f, web, wc, 'ack', refs);
      const assembled = Buffer.concat(parts.filter(Boolean));
      result = { hex: createHash('sha256').update(assembled).digest('hex'),
        count: parts.filter(Boolean).length, b64: assembled.toString('base64') };
    } else if (request.action === 'web-retractions') {
      result = (await operation(f, web, wc, 'retractions', { since: request.since || 0 })).result;
    } else if (request.action === 'web-fetch-open') {
      const inbox = (await operation(f, web, wc, 'fetch')).result;
      const bundle = inbox.find(b => b.message.from === nativeAccount);
      if (!bundle) throw Error('no native message in web inbox');
      const trust = { senderRoot: nativeRoot, recipientRoot: web.vault.signingKey,
        senderGenesis: nativeGenesis, recipientGenesis: web.genesis };
      const plaintext = await openMessage(bundle, web.session, trust);
      const ref = messageRef(bundle.message);
      await operation(f, web, wc, 'ack', [ref]);
      const decoded = decodePayload(plaintext);
      result = { plaintext: decoded.text, reply: decoded.reply, ref };
    } else if (request.action === 'web-status') {
      result = (await operation(f, web, wc, 'status', [request.ref])).result;
    } else throw Error('Unknown test action');
    console.log(JSON.stringify({ ok: true, result }));
  } catch (error) {
    console.log(JSON.stringify({ ok: false, error: error.message }));
  }
}
await f?.close();
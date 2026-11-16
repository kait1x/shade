// Test-only bridge: real alpha.mjs HTTP/WSS server with synthetic OAuth and a
// synthetic legacy Android user. The Dart AlphaTransport talks to the real
// server directly; this bridge only owns the WebCrypto peer. No production
// data, no real keys.
import readline from 'node:readline';
import fs from 'node:fs/promises';
import path from 'node:path';
import { randomBytes, createHash } from 'node:crypto';
import { fixture, identity, register, operation } from '../test/helpers/alpha-fixture.mjs';
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
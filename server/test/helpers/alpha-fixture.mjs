// Synthetic OAuth ONLY for isolated tests; never exported by the alpha server.
import net from 'node:net';
import https from 'node:https';
import { createAlphaServer } from '../../alpha.mjs';
import { hash, sign, requestText, messageText } from '../../../client/web/protocol/device-v2.mjs';
import * as c from '../../../client/web/device_crypto.mjs';
import { stickersOperation } from '../../multidevice/v2-stickers.mjs';

export async function freePort() {
  const socket = net.createServer(); await new Promise(r => socket.listen(0, '127.0.0.1', r));
  const port = socket.address().port; await new Promise(r => socket.close(r)); return port;
}
export async function fixture(options) {
  const port = options.port || await freePort(), origin = `${options.tls ? 'https' : 'http'}://127.0.0.1:${port}`;
  let loginSub = 'synthetic-alice';
  const instance = await createAlphaServer({ ...options, publicOrigin: origin,
    oauthProvider: { configured: true,
      start: ({ state }) => `${origin}/auth/google/callback?state=${state}&code=${encodeURIComponent(loginSub)}`,
      finish: async code => { if (!code.startsWith('synthetic-')) throw Error('Invalid test code'); return { googleSub: code }; } } });
  await new Promise(r => instance.server.listen(port, '127.0.0.1', r));
  async function request(route, body, cookie = '', headers = {}, method) {
    const httpMethod = method || (body === undefined ? 'GET' : 'POST');
    // Same-origin semantics: real browsers and the native transport send Origin.
    const baseHeaders = { Origin: origin, ...headers };
    if (options.tls) return new Promise((resolve, reject) => {
      const req = https.request(origin + route, { ca: options.tls.cert, method: httpMethod,
        headers: { Cookie: cookie, ...(body === undefined ? {} : { 'Content-Type': 'application/json' }), ...baseHeaders } }, res => {
        let content = ''; res.on('data', bytes => { content += bytes; });
        res.on('end', () => resolve({ response: { status: res.statusCode, headers: {
          get: key => res.headers[key.toLowerCase()], getSetCookie: () => res.headers['set-cookie'] || [] } },
          result: (res.headers['content-type'] || '').includes('application/json') ? JSON.parse(content) : null }));
      });
      req.on('error', reject); if (body !== undefined) req.write(JSON.stringify(body)); req.end();
    });
    const response = await fetch(origin + route, { redirect: 'manual', headers: { Cookie: cookie,
      ...(body === undefined ? {} : { 'Content-Type': 'application/json' }), ...baseHeaders },
      ...(body === undefined ? {} : { method: httpMethod, body: JSON.stringify(body) }) });
    return { response, result: (response.headers.get('content-type') || '').includes('application/json') ? await response.json() : null };
  }
  async function login(sub) {
    loginSub = sub;
    const first = await request('/auth/google');
    const flow = first.response.headers.getSetCookie()[0].split(';')[0];
    const callback = await request(new URL(first.response.headers.get('location')).pathname + new URL(first.response.headers.get('location')).search, undefined, flow);
    return callback.response.headers.getSetCookie().find(s => s.startsWith(`${options.tls ? '__Host-' : ''}shade-alpha=`)).split(';')[0];
  }
  // Native-style login with an injected verifyGoogle (tests only).
  async function loginToken(idToken) {
    const reply = await request('/api/v2/session/google', { idToken });
    if (reply.response.status !== 200) throw Error(JSON.stringify(reply.result));
    return reply.response.headers.getSetCookie().find(s => s.startsWith(`${options.tls ? '__Host-' : ''}shade-alpha=`)).split(';')[0];
  }
  return { ...instance, origin, port, request, login, loginToken, setLoginSub: value => { loginSub = value; } };
}
export async function identity(account) {
  const phrase = 'synthetic alpha device passphrase only';
  const vault = await c.createVault(account, phrase), session = await c.unlockVault(vault, phrase);
  const recovery = await c.createRecoveryBackup(account, vault.signingKey, 'synthetic independent recovery password only');
  const genesis = await c.createGenesis(vault, session, recovery.publicKey);
  const manifest = await c.approveDevices(genesis, [], [c.descriptor(vault)], session);
  return { vault, session, genesis, manifest };
}
export async function register(f, who, cookie) {
  const reply = await f.request('/api/v2/register', { genesis: who.genesis, manifest: who.manifest,
    proofs: [await c.pairingProof(who.vault, who.session)] }, cookie);
  if (reply.response.status !== 200) throw Error(JSON.stringify(reply.result));
}
export async function proof(f, who, cookie, op, body = null) {
  const operation = await hash(JSON.stringify([op, op === 'send' ? await hash(messageText(body)) : body]));
  const { account, id } = who.session;
  const { result, response } = await f.request('/api/v2/challenge', { account, id, operation }, cookie);
  if (response.status !== 200) throw Error(JSON.stringify(result));
  return { account, id, nonce: result.nonce,
    proof: await sign(requestText(account, id, result.nonce, operation), who.session.signing) };
}
export async function operation(f, who, cookie, op, body = null) {
  return f.request('/api/v2/operation', { op, body, auth: await proof(f, who, cookie, op, body) }, cookie);
}
export const trust = (a,b) => ({ senderRoot: a.vault.signingKey, recipientRoot: b.vault.signingKey,
  senderGenesis: a.genesis, recipientGenesis: b.genesis });
// Device-proof authorized call into the adapted v1 stickers/profiles routes.
// route is router-relative ('/stickers/gift'); digest binds method+path+body.
export async function stickers(f, who, cookie, method, route, body = null) {
  const operation = await stickersOperation(method, route, body);
  const { account, id } = who.session;
  const challenge = await f.request('/api/v2/challenge', { account, id, operation }, cookie);
  if (challenge.response.status !== 200) throw Error(JSON.stringify(challenge.result));
  const auth = { account, id, nonce: challenge.result.nonce,
    proof: await sign(requestText(account, id, challenge.result.nonce, operation), who.session.signing) };
  return f.request('/api/v2' + route, method === 'GET' ? undefined : body, cookie,
    { 'x-device-auth': JSON.stringify(auth) }, method);
}

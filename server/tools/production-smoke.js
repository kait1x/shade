'use strict';
// Public, non-mutating checks. No credentials or TLS exceptions are used.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { io } = require('socket.io-client');
const base = process.argv[2];
if (!base || new URL(base).protocol !== 'https:') throw Error('Usage: node tools/production-smoke.js https://host');
(async () => {
  const health = await fetch(base + '/api/health', { signal: AbortSignal.timeout(15000) });
  assert.equal(health.status, 200);
  assert.equal((await health.json()).ok, true);
  const key = await (await fetch(base + '/api/server/public-key')).json();
  const fingerprint = crypto.createHash('sha256').update(crypto.createPublicKey(key.publicKey).export({type:'spki',format:'der'})).digest('hex').match(/../g).join(':');
  if (process.env.SERVER_PUBLIC_KEY_FINGERPRINT) assert.equal(fingerprint, process.env.SERVER_PUBLIC_KEY_FINGERPRINT);
  console.log('PASS HTTPS health and server identity');
  const avatar = await fetch(base + '/user/kait1x/avatar');
  assert.equal(avatar.status, 401);
  for (const route of ['/admin', '/api/stats']) assert.equal((await fetch(base + route)).status, 404);
  console.log('PASS private avatar and administrative routes');
  const socket = io(base, {transports:['websocket'],reconnection:false,autoConnect:false,timeout:10000});
  try {
    await new Promise((resolve,reject) => {
      const timer=setTimeout(()=>reject(Error('WSS authentication timeout')),15000);
      socket.once('connect_error', error=>{clearTimeout(timer);reject(error);});
      socket.once('connect',()=>socket.emit('register',{username:'shade_invalid_probe',token:'invalid-probe'}));
      socket.once('authError',()=>{clearTimeout(timer);resolve();});
      socket.connect();
    });
    console.log('PASS public WSS upgrade and invalid-session rejection');
  } finally {socket.disconnect();}
})().catch(error => {console.error(error.message);process.exitCode=1;});

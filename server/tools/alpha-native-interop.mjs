// Isolated test bridge for the existing Dart/Android CryptoService. The native
// private key NEVER enters this process. Real HTTP + WebSocket, synthetic users.
import readline from 'node:readline';
import fs from 'node:fs/promises';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import { io } from 'socket.io-client';
import { fixture, identity, register, operation, proof } from '../test/helpers/alpha-fixture.mjs';
import { legacyRoot } from '../multidevice/registry.mjs';
import { createRecoveryBackup, sealMessage, openMessage } from '../../client/web/device_crypto.mjs';
import { fingerprint, genesisText, manifestText, messageText, hash, requestText } from '../../client/web/protocol/device-v2.mjs';

let f, web, wc, nc, genesis, manifest, root, pending, nativeMessage, socket;
const nativeAccount = 'native_android';
const nativeTrust = () => ({ senderRoot: web.vault.signingKey, recipientRoot: root,
  senderGenesis: web.genesis, recipientGenesis: genesis });
async function challenge(op, body = null) {
  const operation = await hash(JSON.stringify([op, op === 'send' ? await hash(messageText(body)) : body]));
  const { result } = await f.request('/api/v2/challenge', { account:nativeAccount,id:'primary',operation }, nc);
  pending = { op, body, auth:{ account:nativeAccount,id:'primary',nonce:result.nonce } };
  return requestText(nativeAccount,'primary',result.nonce,operation);
}
async function finish(signature) {
  const reply = await f.request('/api/v2/operation', { ...pending,auth:{ ...pending.auth,proof:signature } },nc);
  if (reply.response.status !== 200) throw Error(JSON.stringify(reply.result));
  return reply.result;
}
console.log(JSON.stringify({ ready:true }));
try {
  for await (const line of readline.createInterface({ input:process.stdin })) {
    try {
      const request = JSON.parse(line); let result;
      if (request.action === 'init') {
        const build = path.resolve('../server/build'); await fs.mkdir(build,{recursive:true});
        const dataDir = await fs.mkdtemp(path.join(build,'alpha-native-'));
        root = legacyRoot(request.publicKey);
        f = await fixture({ dataDir,storageSecret:randomBytes(32).toString('hex'),
          legacyUsers:new Map([[nativeAccount,{publicKey:request.publicKey,googleSub:'synthetic-native'}]]) });
        web = await identity('native_web'); wc = await f.login('synthetic-web'); nc = await f.login('synthetic-native');
        await register(f,web,wc);
        const recovery = await createRecoveryBackup(nativeAccount,root,'synthetic native offline recovery phrase');
        const now = Date.now();
        genesis = {version:2,account:nativeAccount,nonce:randomBytes(32).toString('hex'),createdAt:now,
          legacy:true,firstDevice:{id:'primary',encryptionKey:root,signingKey:root},recoveryKey:recovery.publicKey,signature:''};
        manifest = {account:nativeAccount,rootFingerprint:await fingerprint(root),revision:1,previous:'',
          issuedAt:now,expiresAt:now+86400000,devices:[genesis.firstDevice],signer:'primary',signature:''};
        result = {genesisText:genesisText(genesis),manifestText:manifestText(manifest),
          webPublicKey:`-----BEGIN PUBLIC KEY-----\n${web.vault.encryptionKey}\n-----END PUBLIC KEY-----`,
          webSigningKey:`-----BEGIN PUBLIC KEY-----\n${web.vault.signingKey}\n-----END PUBLIC KEY-----`};
      } else if (request.action === 'enroll') {
        genesis.signature = request.genesisSignature; manifest.signature = request.manifestSignature;
        const response = await f.request('/api/v2/legacy-enrollment',{genesis,manifest},nc);
        if (response.response.status !== 200) throw Error(JSON.stringify(response.result));
        socket = io(f.origin,{autoConnect:false,transports:['websocket'],extraHeaders:{Cookie:wc},auth:await proof(f,web,wc,'socket')});
        await new Promise((resolve,reject) => { socket.once('connect',resolve);socket.once('connect_error',reject);socket.connect(); });
        result = {root:f.registry.directory(nativeAccount).root,websocket:socket.io.engine.transport.name};
      } else if (request.action === 'web-send') {
        const m = await sealMessage(request.text,[web.manifest],[manifest],web.session,nativeTrust());
        const sent = await operation(f,web,wc,'send',m); if (!sent.result.accepted) throw Error('send rejected');
        result = {proofText:await challenge('fetch')};
      } else if (request.action === 'native-fetch') {
        const inbox = await finish(request.proof);
        const bundle = inbox.find(b => b.message.from === 'native_web');
        result = {payload:bundle.message.envelopes.find(e => e.deviceId === 'primary').payload,
          messageText:messageText(bundle.message),signature:bundle.message.signature,
          proofText:await challenge('ack',[`${bundle.message.from}:${bundle.message.deviceId}:${bundle.message.id}`])};
      } else if (request.action === 'native-ack') {
        result = await finish(request.proof);
      } else if (request.action === 'prepare-native-send') {
        nativeMessage = {version:2,id:randomBytes(32).toString('hex'),from:nativeAccount,deviceId:'primary',to:'native_web',
          fromRevision:1,toRevision:1,fromDigest:await hash(manifestText(manifest)),toDigest:await hash(manifestText(web.manifest)),
          createdAt:Date.now(),envelopes:[{account:nativeAccount,deviceId:'primary',payload:request.ownPayload},
            {account:'native_web',deviceId:web.session.id,payload:request.webPayload}],signature:''};
        result = {messageText:messageText(nativeMessage),proofText:await challenge('send',nativeMessage)};
      } else if (request.action === 'native-send') {
        nativeMessage.signature = request.signature;
        const accepted = await finish(request.proof);
        const inbox = (await operation(f,web,wc,'fetch')).result;
        const bundle = inbox.find(b => b.message.from === nativeAccount);
        const trust = {senderRoot:root,recipientRoot:web.vault.signingKey,senderGenesis:genesis,recipientGenesis:web.genesis};
        const plaintext = await openMessage(bundle,web.session,trust);
        const ref = `${nativeMessage.from}:${nativeMessage.deviceId}:${nativeMessage.id}`;
        await operation(f,web,wc,'ack',[ref]);
        result = {accepted:accepted.accepted,plaintext,proofText:await challenge('status',[ref])};
      } else if (request.action === 'native-status') {
        const status = await finish(request.proof);
        result = {devices:Object.values(status)[0],root:f.registry.directory(nativeAccount).root};
      } else throw Error('Unknown test action');
      console.log(JSON.stringify({ok:true,result}));
    } catch (error) { console.log(JSON.stringify({ok:false,error:error.message})); }
  }
} finally { socket?.disconnect(); await f?.close(); }

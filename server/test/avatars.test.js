'use strict';
const {test} = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const sharp = require('sharp');
const {installStickers} = require('../stickers');
const {normalizeAvatar} = require('../avatars');

const photo = async () => (await sharp({create:{width:900,height:600,channels:3,background:'#69746c'}})
  .jpeg().withMetadata({exif:{IFD0:{Artist:'private-test-author'},IFD3:{GPSLatitudeRef:'N'}}}).toBuffer()).toString('base64');

test('avatar validation decodes bytes, bounds pixels and strips metadata', async () => {
  const result = await normalizeAvatar(await photo());
  const metadata = await sharp(Buffer.from(result,'base64')).metadata();
  assert.equal(metadata.width,512); assert.equal(metadata.height,512);
  assert.equal(metadata.format,'jpeg'); assert.equal(metadata.exif,undefined);
  assert.equal(metadata.icc,undefined);
  for(const format of ['png','webp']) {
    const input=await sharp({create:{width:64,height:96,channels:4,background:'#77887788'}})[format]().toBuffer();
    assert.ok(await normalizeAvatar(input.toString('base64')));
  }
  for(const value of ['',23,'not an image',Buffer.from('<svg/>').toString('base64'),'A'.repeat(699056),Buffer.from([255,216,255,0]).toString('base64')]) {
    await assert.rejects(normalizeAvatar(value),e=>e.status===400);
  }
  const huge=await sharp({create:{width:5000,height:5000,channels:3,background:'black'}}).png().toBuffer();
  await assert.rejects(normalizeAvatar(huge.toString('base64')),e=>e.status===400);
  assert.equal(await normalizeAvatar(null),null);
  assert.equal(await normalizeAvatar(undefined),undefined);
});

test('authenticated profile routes preserve frames/photos, reject conflicts, survive reload and roll back failed writes', async t => {
  const users=new Map([['alice',{displayName:'Алиса',avatarUrl:'https://example.invalid/google.jpg'}],['bob',{}]]);
  let persisted=new Map(),fail=false;
  const changes=[];
  async function start(initial) {
    const app=express(); app.use(express.json({limit:'1mb'}));
    const auth=(req,res,next)=>req.headers['x-test-token']==='fixture' && users.has(req.headers['x-username']) ? (req.auth={username:req.headers['x-username']},next()) : res.status(401).json({error:'Authentication required'});
    installStickers(app,auth,users,initial,async next=>{
      await new Promise(resolve=>setTimeout(resolve,5));
      if(fail) return false;
      persisted=new Map(JSON.parse(JSON.stringify([...next])));
    },(name,revision)=>changes.push({name,revision}));
    const server=app.listen(0,'127.0.0.1');
    await new Promise(resolve=>server.once('listening',resolve));
    t.after(()=>{server.closeAllConnections();server.close();});
    const request=async (path,body,who='alice',token='fixture')=>{
      const response=await fetch(`http://127.0.0.1:${server.address().port}${path}`,{
        method:body ? 'PUT' : 'GET',headers:{'Content-Type':'application/json','x-username':who,'x-test-token':token},
        ...(body ? {body:JSON.stringify(body)} : {})});
      return {status:response.status,headers:response.headers,data:await response.json()};
    };
    return request;
  }
  let request=await start(new Map());
  assert.equal((await request('/user/alice/avatar',null,'alice','')).status,401);
  let result=await request('/user/alice/avatar');
  assert.equal(result.headers.get('cache-control'),'no-store');
  assert.equal(result.data.imageUrl,users.get('alice').avatarUrl);
  result=await request('/profile/avatar',{frame:'minimal',revision:0});
  assert.equal(result.status,200); assert.equal(result.data.imageUrl,users.get('alice').avatarUrl);
  const image=await photo();
  result=await request('/profile/avatar',{image,frame:'silver',revision:1});
  assert.equal(result.status,200); assert.equal(result.data.frame,'silver'); assert.ok(result.data.image);
  assert.equal(result.data.imageUrl,null);
  const uploaded=result.data.image;
  assert.equal((await request('/user/alice/avatar',null,'bob')).data.image,uploaded);
  assert.equal((await request('/user/bob/avatar')).data.image,null);
  assert.equal((await request('/profile/avatar',{frame:'neon',revision:2})).status,400);
  assert.equal((await request('/profile/avatar',{frame:'none',revision:2,username:'bob'})).status,400);
  const races=await Promise.all(['graphite','none'].map(frame=>request('/profile/avatar',{frame,revision:2})));
  assert.deepEqual(races.map(r=>r.status).sort(),[200,409]);
  assert.equal((await request('/user/alice/avatar')).data.image,uploaded);
  assert.equal(changes.length,3,'only successful commits broadcast');
  fail=true;
  assert.equal((await request('/profile/avatar',{frame:'none',image:null,revision:3})).status,503);
  assert.equal((await request('/user/alice/avatar')).data.image,uploaded);
  assert.equal(changes.length,3);
  fail=false;
  request=await start(persisted);
  assert.equal((await request('/user/alice/avatar')).data.image,uploaded,'profile survives store reload');
  result=await request('/profile/avatar',{image:null,frame:'silver',revision:3});
  assert.equal(result.data.image,null); assert.equal(result.data.imageUrl,null);
  request=await start(persisted);
  result=await request('/user/alice/avatar');
  assert.equal(result.data.image,null); assert.equal(result.data.imageUrl,null,'deleted Google photo stays hidden');
  assert.equal(result.data.frame,'silver','deleting a photo preserves the frame');
  await request('/profile/avatar',{image,frame:'silver',revision:4});
  users.set('alice',{publicKey:'a-new-account-key'});
  result=await request('/user/alice/avatar');
  assert.equal(result.data.image,null,'a reused nickname cannot read the previous account photo');
  assert.equal(result.data.frame,'none');
  result=await request('/profile/avatar',{frame:'graphite',revision:5});
  assert.equal(result.data.image,null,'changing a frame cannot resurrect the previous account photo');
});

test('small avatar requests assemble atomically, retry safely and keep user boundaries', async t => {
  const users=new Map([['chunk_owner',{publicKey:'owner-key'}],['chunk_peer',{publicKey:'peer-key'}]]);
  let stored=new Map(),fail=false,events=0;
  const app=express();app.use(express.json({limit:'1mb'}));
  const auth=(req,res,next)=>users.has(req.headers['x-username']) ? (req.auth={username:req.headers['x-username']},next()) : res.status(401).json({error:'auth'});
  installStickers(app,auth,users,stored,async next=>{if(fail)return false;stored=new Map(next);},()=>events++);
  const server=app.listen(0,'127.0.0.1');await new Promise(resolve=>server.once('listening',resolve));
  t.after(()=>{server.closeAllConnections();server.close();});
  const request=async(body,{user='chunk_owner',method='POST',path='/profile/avatar/chunk'}={})=>{
    const res=await fetch(`http://127.0.0.1:${server.address().port}${path}`,{method,headers:{'content-type':'application/json','x-username':user},body:JSON.stringify(body)});
    return {status:res.status,data:await res.json()};
  };
  const image=await photo(),uploadId='chunk-request-12345678';
  const meta={uploadId,total:image.length,frame:'silver',revision:0};
  const part={...meta,offset:0,chunk:image.slice(0,512)};
  assert.equal((await request(part,{user:'unknown'})).status,401);
  assert.equal((await request({...part,chunk:'A'.repeat(65537)})).status,400);
  assert.equal((await request({...part,total:699056})).status,400);
  assert.equal((await request(part)).data.offset,512);
  assert.equal((await request(part)).data.offset,512,'lost part acknowledgement is safe to retry');
  assert.equal((await request({...part,offset:512},{user:'chunk_peer'})).status,409,'a peer cannot append to another user upload');
  assert.equal((await request({...part,offset:10})).status,409);
  let final;
  for(let offset=512;offset<image.length;offset+=512) final=await request({...meta,offset,chunk:image.slice(offset,offset+512)});
  assert.equal(final.status,200);assert.equal(final.data.complete,true);assert.equal(final.data.profile.revision,1);
  assert.equal(final.data.profile.image,undefined,'acknowledgements stay small');
  assert.ok(stored.get('chunk_owner').avatarImage);assert.equal(events,1);
  const lastOffset=Math.floor((image.length-1)/512)*512;
  assert.equal((await request({...meta,offset:lastOffset,chunk:image.slice(lastOffset)})).data.profile.revision,1);
  assert.equal(events,1,'retrying the final part cannot create a second commit');
  const direct={image,frame:'graphite',revision:1,uploadId:'direct-request-12345678'};
  assert.equal((await request(direct,{method:'PUT',path:'/profile/avatar'})).data.revision,2);
  assert.equal((await request(direct,{method:'PUT',path:'/profile/avatar'})).data.revision,2);
  assert.equal((await request({...direct,frame:'none'},{method:'PUT',path:'/profile/avatar'})).status,409);
  const receipt=await request({uploadId:direct.uploadId,total:image.length,frame:'graphite',revision:1,offset:0,chunk:image.slice(0,512)});
  assert.equal(receipt.data.complete,true,'a committed direct request can finish fallback immediately');
  assert.equal(receipt.data.profile.revision,2);assert.equal(events,2);
  const tiny=(await sharp({create:{width:16,height:16,channels:3,background:'gray'}}).jpeg().toBuffer()).toString('base64');
  assert.ok(tiny.length<=512);
  const one={uploadId:'retry-disk-123456789',total:tiny.length,frame:'minimal',revision:2,offset:0,chunk:tiny};
  fail=true;assert.equal((await request(one)).status,503);assert.equal(stored.get('chunk_owner').avatarRevision,2);
  fail=false;assert.equal((await request(one)).data.profile.revision,3);assert.equal(events,3);
});

'use strict';
const { randomUUID, createHash } = require('node:crypto');
const { normalizeAvatar, avatarFields, avatarOwner } = require('./avatars');
const avatarLimit = require('express-rate-limit')({windowMs:60000,max:20,
  keyGenerator:req=>req.auth.username,standardHeaders:true,legacyHeaders:false,
  validate:{xForwardedForHeader:false},
  message:{error:'Слишком много изменений. Повторите через минуту.'}});
const avatarPartLimit = require('express-rate-limit')({windowMs:60000,max:2400,
  keyGenerator:req=>req.auth.username,standardHeaders:true,legacyHeaders:false,
  validate:{xForwardedForHeader:false},
  message:{error:'Слишком много частей изображения. Повторите позже.'}});
const catalog = ['orbit', 'moth', 'comet', 'ghost', 'flowers'];
const empty = () => ({ inventory: [], wall: [], revision: 0 });
function reject(status, message) { throw Object.assign(new Error(message), { status }); }
function installStickers(app, auth, users, initial, persist, avatarChanged = () => {}) {
  let committed = initial;
  let writes = Promise.resolve();
  const read = name => committed.get(name) || empty();
  const uploads = new Map();
  const validUploadId = id => typeof id==='string' && /^[a-zA-Z0-9_-]{16,80}$/.test(id);
  const sameUpload = (s,user,input) => input.uploadId && s.avatarUploadId===input.uploadId &&
    s.avatarOwner===avatarOwner(user) && s.avatarUploadMeta?.revision===input.revision &&
    s.avatarUploadMeta?.frame===input.frame && s.avatarUploadMeta?.total===input.total;
  const uploadReceipt = profile => {
    const {image,...metadata}=profile;
    return {complete:true,profile:metadata};
  };
  function dropUpload(name,upload) {
    clearTimeout(upload.timer);
    if(uploads.get(name)===upload) uploads.delete(name);
  }
  function mutate(fn) {
    const task = writes.then(async () => {
      const next = new Map(committed);
      const result = fn(next);
      if (result.changed) {
        if ((await persist(next)) === false) reject(503, 'Не удалось сохранить изменения');
        committed = next;
      }
      return result.body;
    });
    writes = task.catch(() => {});
    return task;
  }
  function endpoint(method,path,fn) {
    app[method](path,auth,async (req,res) => {
      try {
        if (req.body && Buffer.byteLength(JSON.stringify(req.body)) > 16384) reject(413,'Слишком большой запрос');
        res.json(await fn(req,req.auth.username));
      } catch (e) { res.status(e.status || 500).json({error:e.status ? e.message : 'Ошибка хранилища'}); }
    });
  }
  endpoint('get','/user/:username/stickers',(req) => {
    const name=req.params.username;
    if (!users.has(name)) reject(404,'Пользователь не найден');
    const s=read(name);
    return {displayName:s.displayName || users.get(name).displayName || name,revision:s.revision,wall:s.wall,
      inventory:s.inventory.map(({giftId,stickerId}) => ({giftId,stickerId}))};
  });
  endpoint('get','/stickers/inventory',(_,name) => {const { inventory, wall, revision }=read(name);return {inventory,wall,revision};});
  endpoint('put','/profile/name',(req,name) => mutate(next => {
    const displayName=req.body?.displayName;
    if(typeof displayName!=='string' || !displayName.trim() || displayName.trim().length>64) reject(400,'Имя должно содержать от 1 до 64 символов');
    next.set(name,{...read(name),displayName:displayName.trim()});
    return {changed:true,body:{displayName:displayName.trim()}};
  }));
  // Avatar settings share the existing encrypted, serialized profile store.
  // No public/static photo URLs and no new storage service.
  app.get('/user/:username/avatar', auth, (req,res) => {
    const name=req.params.username;
    if (!users.has(name)) return res.status(404).json({error:'Пользователь не найден'});
    res.set('Cache-Control','no-store');
    res.json(avatarFields(read(name), users.get(name), name));
  });
  app.put('/profile/avatar', auth, avatarLimit, async (req,res) => {
    try {
      res.set('Cache-Control','no-store').json(await commitAvatar(req.auth.username,req.body || {}));
    } catch(e) { res.status(e.status || 500).json({error:e.status ? e.message : 'Не удалось сохранить аватар'}); }
  });
  async function commitAvatar(name,input) {
      if (Object.keys(input).some(k=>!['image','frame','revision','uploadId'].includes(k)) ||
          !Number.isSafeInteger(input.revision) || input.revision<0 ||
          !['none','minimal','silver','graphite'].includes(input.frame) ||
          (input.uploadId!==undefined && !validUploadId(input.uploadId))) reject(400,'Некорректные настройки аватара');
      const digest=createHash('sha256').update(JSON.stringify([input.image,input.image===undefined,input.frame,input.revision])).digest('hex');
      const image=await normalizeAvatar(input.image);
      let changed=false;
      const body=await mutate(next => {
        if (!users.has(name)) reject(404,'Пользователь не найден');
        const current=read(name);
        if(input.uploadId && current.avatarUploadId===input.uploadId && current.avatarOwner===avatarOwner(users.get(name))) {
          if(current.avatarUploadDigest!==digest) reject(409,'Запрос загрузки уже использован');
          return {changed:false,body:avatarFields(current,users.get(name),name)};
        }
        if ((current.avatarRevision || 0)!==input.revision) reject(409,'Аватар уже изменился. Обновите профиль и повторите сохранение.');
        const updated={...current, avatarOwner:avatarOwner(users.get(name)), avatarFrame:input.frame, avatarRevision:input.revision+1,
          avatarUploadId:input.uploadId || null, avatarUploadDigest:input.uploadId ? digest : null,
          avatarUploadMeta:input.uploadId ? {revision:input.revision,frame:input.frame,total:input.image?.length || 0} : null};
        if (current.avatarOwner!==updated.avatarOwner) delete updated.avatarImage;
        if (image!==undefined) updated.avatarImage=image;
        next.set(name,updated);
        changed=true;
        return {changed:true,body:avatarFields(updated,users.get(name),name)};
      });
      if(changed) avatarChanged(name,body.revision);
      return body;
  }
  // Bounded, short-lived assembly in memory; originals are never written to disk.
  // Small complete HTTP requests also work on paths that stall large TLS writes.
  app.post('/profile/avatar/chunk',auth,avatarPartLimit,
    (req,res,next)=>req.body?.offset===0 ? avatarLimit(req,res,next) : next(),async(req,res)=>{
    try {
      const input=req.body || {}, {uploadId,offset,total,chunk,frame,revision}=input;
      if(Object.keys(input).some(k=>!['uploadId','offset','total','chunk','frame','revision'].includes(k)) ||
          !validUploadId(uploadId) || !Number.isSafeInteger(offset) || offset<0 ||
          !Number.isSafeInteger(total) || total<1 || total>699052 ||
          typeof chunk!=='string' || chunk.length<1 || chunk.length>65536 || !/^[A-Za-z0-9+/=]+$/.test(chunk) ||
          offset+chunk.length>total || !Number.isSafeInteger(revision) || revision<0 ||
          !['none','minimal','silver','graphite'].includes(frame)) reject(400,'Некорректная часть аватара');
      const name=req.auth.username,user=users.get(name);
      if(!user) reject(404,'Пользователь не найден');
      res.set('Cache-Control','no-store');
      if(sameUpload(read(name),user,input)) return res.json(uploadReceipt(avatarFields(read(name),user,name)));
      let upload=uploads.get(name);
      if(upload && (upload.id!==uploadId || upload.owner!==avatarOwner(user))) {
        if(offset!==0) reject(409,'Загрузка устарела. Повторите сохранение.');
        dropUpload(name,upload);upload=null;
      }
      if(!upload) {
        if(offset!==0) reject(409,'Загрузка истекла. Повторите сохранение.');
        if(uploads.size>=8) reject(503,'Сервер занят загрузками. Повторите позже.');
        upload={id:uploadId,owner:avatarOwner(user),total,frame,revision,offset:0,parts:[],lastOffset:-1,lastChunk:null};
        upload.timer=setTimeout(()=>dropUpload(name,upload),120000);upload.timer.unref();
        uploads.set(name,upload);
      }
      if(upload.total!==total || upload.frame!==frame || upload.revision!==revision) reject(409,'Параметры загрузки изменились');
      clearTimeout(upload.timer);
      upload.timer=setTimeout(()=>dropUpload(name,upload),120000);upload.timer.unref();
      if(offset!==upload.offset) {
        if(offset!==upload.lastOffset || chunk!==upload.lastChunk) reject(409,'Неверный порядок частей');
        return res.json(upload.committing ? await upload.committing : {offset:upload.offset,complete:false});
      }
      upload.lastOffset=offset;upload.lastChunk=chunk;upload.parts.push(chunk);upload.offset+=chunk.length;
      if(upload.offset<total) return res.json({offset:upload.offset,complete:false});
      upload.committing=(async()=>{
        try {
          const profile=await commitAvatar(name,{image:upload.parts.join(''),frame,revision,uploadId});
          dropUpload(name,upload);
          return uploadReceipt(profile);
        } catch(e) {
          upload.parts.pop();upload.offset=offset;upload.committing=null;
          throw e;
        }
      })();
      res.json(await upload.committing);
    } catch(e) {res.status(e.status || 500).json({error:e.status ? e.message : 'Не удалось сохранить аватар'});}
  });
  endpoint('post','/stickers/gift',(req,name) => mutate(next => {
    const {toUsername,stickerId,note='',requestId}=req.body || {};
    if (Object.keys(req.body || {}).some(k=>!['toUsername','stickerId','note','requestId'].includes(k))) reject(400,'Неизвестное поле');
    if (!users.has(toUsername)) reject(404,'Получатель не найден');
    if (toUsername===name || !catalog.includes(stickerId) || typeof note!=='string' || note.length>240 ||
      typeof requestId!=='string' || !/^[a-zA-Z0-9_-]{16,80}$/.test(requestId)) reject(400,'Проверьте данные подарка');
    const sender=read(name), recipient=read(toUsername);
    const receipt=sender.receipts?.find(r=>r.requestId===requestId);
    if (receipt) {
      const gift=recipient.inventory.find(g=>g.giftId===receipt.giftId);
      if (!gift || gift.note!==note || gift.stickerId!==stickerId) reject(409,'Запрос уже использован');
      return {changed:false,body:{giftId:gift.giftId}};
    }
    const now=Date.now(), receipts=sender.receipts || [];
    if(receipts.filter(r=>r.at>now-60000).length>=8 || receipts.length>=10000 || recipient.inventory.length>=2000) reject(429,'Достигнут лимит подарков');
    const giftId=randomUUID();
    next.set(toUsername,{...recipient,inventory:[...recipient.inventory,{giftId,stickerId,note,fromUsername:name,receivedAt:now}]});
    next.set(name,{...sender,receipts:[...receipts,{requestId,giftId,at:now}]});
    return {changed:true,body:{giftId}};
  }));
  endpoint('put','/stickers/wall',(req,name) => mutate(next => {
    const {wall,revision}=req.body || {}, s=read(name);
    if(Object.keys(req.body || {}).some(k=>!['wall','revision'].includes(k)) || !Array.isArray(wall) || wall.length>32) reject(400,'Некорректная стена');
    if(revision!==s.revision) reject(409,'Стена уже изменилась');
    const ids=new Set(), owned=new Set(s.inventory.map(g=>g.giftId));
    const range=(n,lo,hi)=>Number.isFinite(n)&&n>=lo&&n<=hi;
    for(const p of wall) {
      if(!p || Object.keys(p).some(k=>!['giftId','xNorm','yNorm','scale','rotation','zIndex'].includes(k)) ||
        !owned.has(p.giftId) || ids.has(p.giftId) || !range(p.xNorm,0,1) || !range(p.yNorm,0,1) ||
        !range(p.scale,0.5,2) || !range(p.rotation,-Math.PI,Math.PI) || !Number.isInteger(p.zIndex) || !range(p.zIndex,0,31)) reject(400,'Некорректное размещение');
      ids.add(p.giftId);
    }
    next.set(name,{...s,wall,revision:revision+1});
    return {changed:true,body:{wall,revision:revision+1}};
  }));
}
module.exports={installStickers,catalog};

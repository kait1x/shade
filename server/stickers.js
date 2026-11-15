'use strict';
const { randomUUID } = require('node:crypto');
const catalog = ['orbit', 'moth', 'comet', 'ghost'];
const empty = () => ({ inventory: [], wall: [], revision: 0 });
function reject(status, message) { throw Object.assign(new Error(message), { status }); }
function installStickers(app, auth, users, initial, persist) {
  let committed = initial;
  let writes = Promise.resolve();
  const read = name => committed.get(name) || empty();
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

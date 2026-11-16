'use strict';
const sharp = require('sharp');
const {createHash} = require('node:crypto');
const fail = (status, message) => { throw Object.assign(new Error(message), {status}); };

// Gallery originals never reach disk. Validate the actual decoded format,
// reject animation/bombs, then re-encode to remove EXIF/GPS and other metadata.
async function normalizeAvatar(value) {
  if (value === null) return null;
  // Undefined means keep the photo, e.g. changing a frame on a Google avatar.
  if (value === undefined) return undefined;
  if (typeof value !== 'string' || !value.length || value.length > 699052 ||
      !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) {
    fail(400,'Выберите изображение JPEG, PNG или WebP до 512 КБ');
  }
  const bytes = Buffer.from(value,'base64');
  if (bytes.length > 512*1024) fail(413,'Изображение слишком большое');
  try {
    const pipeline = sharp(bytes,{limitInputPixels:16000000,failOn:'warning'});
    const metadata = await pipeline.metadata();
    if (!['jpeg','png','webp'].includes(metadata.format) || (metadata.pages || 1)>1 ||
        !metadata.width || !metadata.height || metadata.width*metadata.height>16000000) {
      fail(400,'Поддерживаются только статичные JPEG, PNG и WebP');
    }
    return (await pipeline.rotate().resize(512,512,{fit:'cover'}).jpeg({quality:85}).toBuffer()).toString('base64');
  } catch(e) {
    if(e.status) throw e;
    fail(400,'Не удалось прочитать изображение');
  }
}

function avatarFields(settings,user,name) {
  const owns = settings.avatarOwner === avatarOwner(user);
  const custom = owns && Object.hasOwn(settings,'avatarImage');
  return {image:custom ? settings.avatarImage : null,
    // Explicit null hides the Google photo even after a new Google sign-in.
    imageUrl:custom ? null : (user.avatarUrl || null),
    frame:owns ? (settings.avatarFrame || 'none') : 'none', revision:settings.avatarRevision || 0,
    displayName:settings.displayName || user.displayName || name};
}
// Reused nicknames must never inherit a deleted account's private photo.
const avatarOwner = user => createHash('sha256').update(user.publicKey || '').digest('hex');
module.exports={normalizeAvatar,avatarFields,avatarOwner};

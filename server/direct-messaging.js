'use strict';
// direct-messaging.js — маршрутизация личных сообщений на сервере Shade.
// Сервер — «глухой ретранслятор»: хранит и пересылает только зашифрованные
// конверты, содержимое прочитать не может. Здесь: валидация запросов,
// офлайн-очереди, квитанции sent/delivered/read и «удалить у всех».
// Авторизация — по socket.username, назначенному слоем аутентификации.
const crypto = require('node:crypto');
// Лимиты защиты от переполнения: размер сообщения, суммарный размер очередей,
// срок хранения (7 дней) и максимум квитанций.
const MAX_PAYLOAD_BYTES = 10 * 1024 * 1024;
const MAX_QUEUE_BYTES = 30 * 1024 * 1024;
const TTL = 7 * 24 * 60 * 60 * 1000;
const MAX_RECEIPTS = 10000;

// One serialized transaction queue for ALL sockets. Queues and receipts are saved
// in a single atomic snapshot, before any ACK, notification or delivery.
// Фабрика обработчиков личных сообщений. Зависимости (io, persist, encrypt/
// decrypt, push, receipts) внедряются снаружи — модуль тестируем изолированно.
function createDirectMessaging({ io, users, onlineUsers, offlineBuffer,
  encrypt, decrypt, persist, push, receipts }) {
  let tail = Promise.resolve();
  // Общая serial-очередь: обработчики сокетов выполняются строго по очереди,
  // поэтому очереди и квитанции не страдают от гонок параллельных событий.
  const serial = task => {
    const next = tail.then(task);
    tail = next.catch(() => {});
    return next;
  };
  // Офлайн-очередь шифруется в покое (обёртка {s: ...}); unwrap снимает её
  // перед доставкой и проверками. Само сообщение при этом остаётся
  // E2E-шифрованным (k/d) — содержимое серверу недоступно.
  const unwrap = value => value?.s ? decrypt(value) : value;
  // Ключ квитанции: id сообщения уникален в рамках отправителя.
  const keyOf = (from, id) => `${from}:${id}`;
  // Точечная доставка: событие уходит только онлайн-получателю.
  const emitTo = (username, event, data) => {
    const target = onlineUsers.get(username);
    if (target) io.to(target).emit(event, data);
  };
  // Активный сокет = сокет, которому сейчас действительно принадлежит username
  // (защита от «призрачных» обработчиков после переподключения).
  const active = socket => socket.username && onlineUsers.get(socket.username) === socket.id;
  // Отказ операции: в ack-колбэк, если он есть, иначе событием 'error'.
  const fail = (socket, ack, error) => {
    if (typeof ack === 'function') ack({ ok: false, error });
    else socket.emit('error', { message: error });
  };
  // Транзакция: перед изменением снимаются копии очередей и квитанций,
  // persist() (атомарный снапшот) выполняется ДО любых уведомлений; при
  // сбое состояние полностью откатывается.
  async function transaction(change) {
    const previousQueues = new Map([...offlineBuffer].map(([user, queue]) => [user, [...queue]]));
    const previousReceipts = new Map(receipts);
    try {
      change();
      if (await persist() === false) throw new Error('Server storage unavailable; try later');
    } catch (error) {
      offlineBuffer.clear(); previousQueues.forEach((v, k) => offlineBuffer.set(k, v));
      receipts.clear(); previousReceipts.forEach((v, k) => receipts.set(k, v));
      throw error;
    }
  }
  // Чистка просроченного (TTL 7 дней) в квитанциях и офлайн-очередях.
  function prune() {
    const cutoff = Date.now() - TTL;
    for (const [key, receipt] of receipts) if (receipt.timestamp < cutoff) receipts.delete(key);
    for (const [user, queue] of offlineBuffer) {
      const remaining = queue.filter(value => (unwrap(value)?.timestamp || 0) >= cutoff);
      if (remaining.length) offlineBuffer.set(user, remaining); else offlineBuffer.delete(user);
    }
  }
  // Если квитанции нет, но сообщение ещё лежит в очереди получателя,
  // квитанция восстанавливается из очереди. Это же служит дедупликацией:
  // повтор с тем же id распознаётся по digest и не ставится повторно.
  function restoreLegacyReceipt(from, to, id) {
    const key = keyOf(from, id);
    let receipt = receipts.get(key);
    if (!receipt) {
      const envelope = (offlineBuffer.get(to) || []).map(unwrap).find(item => item?.from === from && item.id === id);
      if (envelope) {
        receipt = { from, to, id, digest: crypto.createHash('sha256').update(envelope.data).digest('hex'), timestamp: envelope.timestamp, status: 'sent' };
        receipts.set(key, receipt);
      }
    }
    return receipt;
  }
  // Регистрация обработчиков Socket.IO одного сокета: каждое событие проходит
  // проверку активной сессии и общей serial-очереди.
  function attach(socket) {
    // Обёртка слушателя: авторизация, сериализация и аккуратный отказ
    // клиенту при недоступности хранилища вместо падения сервера.
    const on = (event, handler) => socket.on(event, (payload, ack) => {
      serial(async () => {
        if (!active(socket)) return fail(socket, ack, 'Authentication required');
        await handler(payload, ack);
      }).catch(() => fail(socket, ack, 'Server storage unavailable; try later'));
    });
    // Приём сообщения: проверяются получатель, id и форма шифрованного payload
    // (k/d). Сервер содержимое не расшифровывает — только валидирует структуру
    // и пересылает.
    on('message', async (payload, ack) => {
      const from = socket.username;
      if (!payload || typeof payload.to !== 'string' || typeof payload.data !== 'string') return fail(socket, ack, 'Invalid message');
      const to = payload.to.toLowerCase().trim(), id = payload.id;
      if (!users.has(to) || to === from) return fail(socket, ack, 'Unknown recipient');
      if (typeof id !== 'string' || !/^[a-zA-Z0-9_-]{16,80}$/.test(id)) return fail(socket, ack, 'Invalid message ID');
      if (Buffer.byteLength(payload.data) > MAX_PAYLOAD_BYTES) return fail(socket, ack, 'Payload too large (max 10 MiB)');
      try {
        const parsed = JSON.parse(payload.data);
        if (!parsed || typeof parsed.k !== 'string' || !parsed.k || typeof parsed.d !== 'string' || !parsed.d) throw Error();
      } catch { return fail(socket, ack, 'Invalid encrypted payload'); }
      const digest = crypto.createHash('sha256').update(payload.data).digest('hex');
      // Дедупликация: повтор с тем же id принимается только для того же
      // сообщения (получатель + digest) — это ретрай после обрыва сети;
      // конфликт id с другим содержимым отклоняется.
      const old = restoreLegacyReceipt(from, to, id);
      if (old && old.timestamp >= Date.now() - TTL) {
        if (old.to !== to || old.digest !== digest) return fail(socket, ack, 'Message ID conflict');
        if (typeof ack === 'function') ack({ ok: true, id, status: old.status });
        return;
      }
      // Постановка в офлайн-очередь получателя и квитанция 'sent' — в одной
      // транзакции; при переполнении очереди ничего не меняется.
      const envelope = { id, from, data: payload.data, timestamp: Date.now() };
      let full = false;
      await transaction(() => {
        prune();
        const queue = offlineBuffer.get(to) || [];
        const queued = encrypt(envelope);
        const bytes = queue.reduce((sum, value) => sum + Buffer.byteLength(JSON.stringify(value)), 0);
        full = receipts.size >= MAX_RECEIPTS || queue.length >= 200 || bytes + Buffer.byteLength(JSON.stringify(queued)) > MAX_QUEUE_BYTES;
        if (full) return;
        offlineBuffer.set(to, [...queue, queued]);
        receipts.set(keyOf(from, id), { from, to, id, digest, timestamp: envelope.timestamp, status: 'sent' });
      });
      if (full) return fail(socket, ack, 'Server or recipient queue is full; try later');
      // Живая доставка онлайн-получателю; push — только если он офлайн.
      emitTo(to, 'message', envelope);
      if (!onlineUsers.has(to)) Promise.resolve(push(to, from)).catch(() => {});
      if (typeof ack === 'function') ack({ ok: true, id, status: 'sent' });
    });
    // Квитанции delivered/read: статусы обновляются пачками (до 200 id),
    // доставленные сообщения убираются из офлайн-очереди, отправитель
    // получает событие messageStatus.
    const acknowledge = status => async (payload, ack) => {
      if (!payload || typeof payload.from !== 'string' || !Array.isArray(payload.msgIds)) return fail(socket, ack, 'Invalid receipt');
      const ids = [...new Set(payload.msgIds)].filter(id => typeof id === 'string').slice(0, 200);
      const updates = [];
      await transaction(() => {
        for (const id of ids) {
          const receipt = restoreLegacyReceipt(payload.from, socket.username, id);
          if (!receipt || receipt.to !== socket.username || receipt.deletedAt) continue;
          const next = { ...receipt, status: receipt.status === 'read' ? 'read' : status };
          receipts.set(keyOf(payload.from, id), next);
          updates.push({ msgId: id, status: next.status, from: socket.username });
        }
        const accepted = new Set(updates.map(value => value.msgId));
        offlineBuffer.set(socket.username, (offlineBuffer.get(socket.username) || []).filter(value => {
          const item = unwrap(value);
          return !item || item.from !== payload.from || !accepted.has(item.id);
        }));
      });
      for (const update of updates) emitTo(payload.from, 'messageStatus', update);
      if (typeof ack === 'function') ack({ ok: true, msgIds: updates.map(value => value.msgId) });
    };
    on('delivered', acknowledge('delivered'));
    on('read', acknowledge('read'));
    // «Удалить у всех»: квитанция помечается deletedAt, а неотправленное
    // сообщение убирается из офлайн-очереди получателя.
    on('deleteMessage', async (payload, ack) => {
      if (!payload?.forEveryone || typeof payload.to !== 'string' || typeof payload.msgId !== 'string') return fail(socket, ack, 'Invalid deletion');
      const receipt = restoreLegacyReceipt(socket.username, payload.to, payload.msgId);
      if (!receipt || receipt.to !== payload.to) return fail(socket, ack, 'Message not found');
      await transaction(() => {
        receipts.set(keyOf(socket.username, payload.msgId), { ...receipt, deletedAt: Date.now() });
        offlineBuffer.set(payload.to, (offlineBuffer.get(payload.to) || []).filter(value => {
          const item = unwrap(value);
          return item?.id !== payload.msgId || item.from !== socket.username;
        }));
      });
      emitTo(payload.to, 'messageDeleted', { msgId: payload.msgId, from: socket.username });
      if (typeof ack === 'function') ack({ ok: true });
    });
  }
  // Публичный API: attach — подключение сокетов, sweep — периодическая чистка
  // по TTL, replay — досылка очереди и статусов после переподключения.
  return {
    attach,
    sweep: () => serial(() => transaction(prune)),
    replay: socket => serial(() => {
      if (!active(socket)) return;
      for (const value of offlineBuffer.get(socket.username) || []) {
        const message = unwrap(value);
        if (message && message.timestamp >= Date.now() - TTL) socket.emit('message', message);
      }
      for (const receipt of receipts.values()) {
        if (receipt.timestamp < Date.now() - TTL) continue;
        if (receipt.from === socket.username) socket.emit('messageStatus', { msgId: receipt.id, from: receipt.to, status: receipt.status });
        if (receipt.to === socket.username && receipt.deletedAt) socket.emit('messageDeleted', { msgId: receipt.id, from: receipt.from });
      }
    }),
  };
}
module.exports = { createDirectMessaging };

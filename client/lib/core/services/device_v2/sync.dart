/// Оркестрация синхронизации device-v2 для native UI.
///
/// Слой поверх готового стека repository/store/transport: полный цикл sync
/// (lease → outbox → inbox → legacy-мост → tombstones → статусы доставки),
/// wake-hints и периодический опрос, проекции для экранов (список чатов,
/// диалог, профиль, устройства) и долговечная offline-очередь исходящих.
///
/// Queue-контракт как в web (client/web/alpha-client.mjs): сообщение сначала
/// коммитится в подписанный outbox (V2Store), retry повторяет ТОТ ЖЕ
/// ciphertext/ID и никогда не перешифровывает сообщение после неоднозначной
/// отправки. Статусы: queued (в очереди), blocked (сервер отклонил: 400/409),
/// accepted → sent/delivered/read по подписанной status-проекции.
///
/// Offline: уже запечатанные сообщения переживают любой сбой сети и
/// доставляются повторным flush; self-chat запечатывается полностью offline
/// (свой каталог хранится в store). Новый peer-send без сети запечатывается
/// против последней ОНЛАЙН-проверенной history контакта (contactHistory):
/// fail-closed — без подтверждённого контакта или проверенной цепочки
/// честный отказ, подмена/rollback истории блокируется verifyHistory.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../database/database_service.dart';
import 'crypto.dart';
import 'payload.dart';
import 'protocol.dart';
import 'repository.dart';
import 'store.dart';
import 'transport.dart';

/// Сообщение диалога, готовое к отрисовке (статусы веб-контракта).
class V2MessageView {
  final String ref;
  final String peer;
  final bool mine;
  final int createdAt;
  final String text;
  final Map<String, dynamic>? reply;
  final bool isImage;
  final Uint8List? imageData;
  final bool mediaPending;

  /// queued | blocked | sent | delivered | read | received | retracted.
  final String status;
  final String? statusLabel;

  const V2MessageView({
    required this.ref,
    required this.peer,
    required this.mine,
    required this.createdAt,
    required this.text,
    this.reply,
    this.isImage = false,
    this.imageData,
    this.mediaPending = false,
    required this.status,
    this.statusLabel,
  });
}

/// Строка списка чатов: последнее сообщение + его статус.
class V2ChatSummary {
  final String peer;
  final bool confirmed;
  final int? lastAt;
  final String? lastText;
  final bool lastMine;
  final bool lastIsImage;
  final String? lastStatus;
  final int pendingCount;

  const V2ChatSummary({
    required this.peer,
    required this.confirmed,
    this.lastAt,
    this.lastText,
    this.lastMine = false,
    this.lastIsImage = false,
    this.lastStatus,
    this.pendingCount = 0,
  });
}

/// Устройство из проверенного каталога аккаунта.
class V2DeviceView {
  final String id;
  final String fingerprint;
  final bool current;
  final bool primary;

  const V2DeviceView({
    required this.id,
    required this.fingerprint,
    required this.current,
    required this.primary,
  });
}

/// Профиль устройства v2: имя, якорь, каталог. displayName/avatar через
/// profile API в native-транспорте пока нет — экран показывает имя+ключ.
class V2ProfileView {
  final String account;
  final String rootFingerprint;
  final String genesisDigest;
  final int revision;
  final int leaseExpiresAt;
  final int deviceCount;
  final String sessionId;

  const V2ProfileView({
    required this.account,
    required this.rootFingerprint,
    required this.genesisDigest,
    required this.revision,
    required this.leaseExpiresAt,
    required this.deviceCount,
    required this.sessionId,
  });
}

class V2TypingEvent {
  final String account;
  final int until;
  const V2TypingEvent(this.account, this.until);
}

class V2PresenceEvent {
  final String account;
  final bool online;
  const V2PresenceEvent(this.account, this.online);
}

/// UI-контракт синхронизации. Реализация — поверх V2ChatRepository;
/// widget-тесты подменяют провайдер fake-реализацией этого интерфейса.
abstract class V2SyncService {
  factory V2SyncService({
    required V2ChatRepository repository,
    required DatabaseService database,
  }) =>
      _V2SyncService(repository, database);

  String get account;
  bool get syncing;
  String? get lastError;

  /// Инвалидация проекций: после sync-цикла, отправки, удаления, отзыва.
  Stream<void> get changes;
  Stream<V2TypingEvent> get typing;
  Stream<V2PresenceEvent> get presence;

  /// Wake-hints + периодический опрос + socket (потерянные hints чинятся
  /// подписанным fetch). Вызывается один раз после enrollment/restore.
  void start();
  Future<void> syncNow();

  Future<List<V2ChatSummary>> chats();
  Future<List<V2MessageView>> conversation(String peer);

  /// Отправка с долговечной очередью: сетевой сбой не теряет сообщение.
  Future<String> send(String peer, String text, {Map<String, dynamic>? reply});
  Future<void> confirmContact(String peer, String genesisDigest);
  Future<bool> peerUpgradeBlocked(String peer);
  Future<void> markRead(List<String> refs);
  Future<void> deleteLocal(String ref);
  Future<void> retract(String ref);

  void watch(String peer);
  void unwatch(String peer);
  void sendTyping(String peer);

  Future<V2ProfileView?> profile();
  Future<List<V2DeviceView>> devices({bool refresh = false});

  void dispose();
}

/// Коды серверных отказов (400/409), при которых повтор ТОГО ЖЕ конверта
/// бессмысленен до изменения условий: собеседник не на v2 либо каталог/
/// сообщение детерминированно отклонены. Остальные ошибки — retryable.
bool _isBlockedCode(String? code) =>
    code == 'peer_upgrade_required' || code == 'operation_rejected';

String _blockedLabel(String? code) => code == 'peer_upgrade_required'
    ? 'Собеседник ещё не перешёл на v2 — сообщение будет доставлено после перехода'
    : 'Сервер отклонил сообщение (устаревший каталог или конфликт)';

bool _isNetworkError(Object error) =>
    error is SocketException || error is HttpException;

String _errorText(Object error) {
  if (error is AlphaTransportException) {
    return switch (error.code) {
      'login_required' => 'Сессия истекла — подключите устройство заново',
      'peer_upgrade_required' => 'Собеседник ещё не перешёл на v2',
      'rate_limited' => 'Слишком много запросов — повторим позже',
      'operation_rejected' => 'Сервер отклонил операцию',
      _ => 'Сервер недоступен (${error.code})',
    };
  }
  if (_isNetworkError(error)) return 'Нет соединения с сервером';
  if (error is ProtocolException) return error.reason;
  if (error is StateError) return error.message;
  return 'Ошибка синхронизации';
}

class _V2SyncService implements V2SyncService {
  final V2ChatRepository _repository;
  final DatabaseService _database;

  final _changes = StreamController<void>.broadcast();
  final _typing = StreamController<V2TypingEvent>.broadcast();
  final _presence = StreamController<V2PresenceEvent>.broadcast();

  Timer? _wakeDebounce;
  bool _started = false;
  bool _syncing = false;
  bool _pendingWake = false;
  bool _disposed = false;
  String? _lastError;
  int _retractionCursor = 0;

  /// Сериализация отправок: before/after-снимок outbox однозначно определяет,
  /// успел ли repository закоммитить конверт до сетевого сбоя.
  Future<void> _sendQueue = Future.value();

  _V2SyncService(this._repository, this._database);

  V2Store get _store => _repository.store;
  AlphaTransport get _transport => _repository.transport;

  /// Текущая сессия устройства (primary-якорь либо вторичное устройство из
  /// completePairing/recoverWithBackup): id и ключи для auth/расшифровки.
  DeviceV2Session get _session => _repository.session;
  String get _sessionId => _session.id;

  @override
  String get account => _repository.account;
  @override
  bool get syncing => _syncing;
  @override
  String? get lastError => _lastError;
  @override
  Stream<void> get changes => _changes.stream;
  @override
  Stream<V2TypingEvent> get typing => _typing.stream;
  @override
  Stream<V2PresenceEvent> get presence => _presence.stream;

  void _emit() {
    if (!_disposed && !_changes.isClosed) _changes.add(null);
  }

  @override
  void start() {
    if (_started || _disposed) return;
    _started = true;
    _transport.onWake = _scheduleSync;
    _transport.onTyping = (account, until) {
      if (!_typing.isClosed) _typing.add(V2TypingEvent(account, until));
    };
    _transport.onPresence = (account, online) {
      if (!_presence.isClosed) _presence.add(V2PresenceEvent(account, online));
    };
    _transport.startPolling();
    // Socket — только hints; сбой подключения чинится периодическим fetch.
    // Auth сокета — текущим устройством (не якорем): proof подписывается
    // ключом сессии, nonce одноразовый при каждом reconnect.
    unawaited(_transport
        .connectSocket(
            account: account,
            id: _sessionId,
            privateKey: _session.signingPrivateKey)
        .catchError((Object _) {}));
    unawaited(syncNow());
  }

  void _scheduleSync() {
    if (_disposed) return;
    if (_syncing) {
      _pendingWake = true;
      return;
    }
    _wakeDebounce?.cancel();
    _wakeDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!_disposed) unawaited(syncNow());
    });
  }

  @override
  Future<void> syncNow() async {
    if (_syncing || _disposed || !_repository.enrolled) return;
    _syncing = true;
    _emit();
    Object? firstError;
    // Каждый шаг независим: сбой outbox не блокирует разбор входящих
    // (как в web-контракте), ошибка цикла видна UI, но не роняет его.
    Future<void> step(Future<void> Function() action) async {
      try {
        await action();
      } catch (error) {
        firstError ??= error;
      }
    }

    await step(() => _repository.renewLease());
    await step(() => _repository.flushOutbox());
    await step(() async {
      await _repository.syncInbox();
    });
    await step(() async {
      await _repository.syncLegacyInbox();
    });
    await step(() async {
      _retractionCursor =
          await _repository.syncRetractions(since: _retractionCursor);
    });
    await step(() async {
      final refs = await _recentOutRefs();
      if (refs.isNotEmpty) await _repository.refreshDelivery(refs);
    });

    _lastError = firstError == null ? null : _errorText(firstError!);
    _syncing = false;
    _emit();
    if (_pendingWake) {
      _pendingWake = false;
      _scheduleSync();
    }
  }

  Future<List<String>> _recentOutRefs() async {
    final db = await _database.database;
    final rows = await db.rawQuery(
        "SELECT ref FROM v2_messages WHERE direction='out' "
        'ORDER BY created_at DESC LIMIT 200');
    return [for (final row in rows) row['ref'] as String];
  }

  /// Расшифровка собственного конверта запечатанного outbox-сообщения:
  /// конверт адресован текущему устройству и шифровался его публичным ключом.
  Future<Map<String, dynamic>> _decodeOutboxMessage(
      Map<String, dynamic> message) async {
    final own = (message['envelopes'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((e) =>
            e['account'] == account && e['deviceId'] == _sessionId);
    final plain = await _repository.crypto
        .decryptData(jsonEncode(own['payload']), _session.encryptionPrivateKey);
    return decodePayload(plain);
  }

  /// Ключ расшифровки строки истории: bridged v1 — исходный RSA;
  /// v2 — ключ ТЕКУЩЕГО устройства (у primary совпадает с якорем).
  String _rowKey(String ref) => ref.startsWith('v1:')
      ? (_repository.legacyPrivateKey ?? _repository.privateKey)
      : _session.encryptionPrivateKey;

  /// Статус исходящего по подписанной проекции сервера (refreshDelivery
  /// запрашивает её auth-ом текущего устройства). Агрегация как в web:
  /// read любого устройства получателя → read, ACK любого → delivered.
  Future<String> _deliveryStatus(String ref) async {
    final devices = await _store.deliveryFor(ref);
    if (devices.any((d) => d['readAt'] != null)) return 'read';
    if (devices.any((d) => d['acknowledgedAt'] != null)) return 'delivered';
    return 'sent';
  }

  @override
  Future<List<V2ChatSummary>> chats() async {
    final contacts = <String, bool>{
      for (final c in await _store.listContacts())
        c['account'] as String: c['confirmed'] == true
    };
    final db = await _database.database;
    final peerRows = await db
        .rawQuery('SELECT peer FROM v2_messages GROUP BY peer');
    final outbox = await _store.outboxAll();
    final peers = <String>{
      account, // «Избранное» доступно всегда, без подтверждения контакта
      ...contacts.keys,
      for (final row in peerRows) row['peer'] as String,
      for (final entry in outbox) entry['peer'] as String,
    };

    final summaries = <V2ChatSummary>[];
    for (final peer in peers) {
      final pending =
          outbox.where((e) => e['peer'] == peer).toList(growable: false);
      int? lastAt;
      String? lastText;
      var lastMine = false;
      var lastIsImage = false;
      String? lastStatus;

      if (pending.isNotEmpty) {
        // Очередь важнее принятой истории: пользователь видит, что сообщение
        // ещё не доставлено (queued/blocked), а не старый accepted-статус.
        final entry = pending.last;
        final message = entry['message'] as Map<String, dynamic>;
        final decoded = await _decodeOutboxMessage(message);
        lastAt = message['createdAt'] as int;
        lastMine = true;
        lastIsImage = decoded['media'] != null;
        lastText = lastIsImage ? 'Фото' : decoded['text'] as String? ?? '';
        lastStatus =
            _isBlockedCode(entry['lastError'] as String?) ? 'blocked' : 'queued';
      } else {
        final rows = await db.query('v2_messages',
            where: 'peer=?',
            whereArgs: [peer],
            orderBy: 'created_at DESC, ref DESC',
            limit: 1);
        if (rows.isNotEmpty) {
          final row = rows.first;
          final ref = row['ref'] as String;
          lastAt = row['created_at'] as int;
          lastMine = row['direction'] == 'out';
          final plain = await _repository.crypto
              .decryptData(row['payload'] as String, _rowKey(ref));
          final decoded = decodePayload(plain);
          lastIsImage = decoded['media'] != null;
          lastText = lastIsImage ? 'Фото' : decoded['text'] as String? ?? '';
          if (row['status'] == 'retracted') {
            lastStatus = 'retracted';
            lastText = 'Сообщение отозвано';
          } else if (lastMine) {
            lastStatus = await _deliveryStatus(ref);
          } else {
            lastStatus = 'received';
          }
        }
      }

      summaries.add(V2ChatSummary(
        peer: peer,
        confirmed: peer == account || contacts[peer] == true,
        lastAt: lastAt,
        lastText: lastText,
        lastMine: lastMine,
        lastIsImage: lastIsImage,
        lastStatus: lastStatus,
        pendingCount: pending.length,
      ));
    }

    summaries.sort((a, b) {
      if (a.peer == account) return -1;
      if (b.peer == account) return 1;
      final at = (b.lastAt ?? 0).compareTo(a.lastAt ?? 0);
      return at != 0 ? at : a.peer.compareTo(b.peer);
    });
    return summaries;
  }

  @override
  Future<List<V2MessageView>> conversation(String peer) async {
    final rows = await _repository.getMessages(peer);
    final views = <V2MessageView>[];
    for (final row in rows) {
      final mine = row['direction'] == 'out';
      final ref = row['ref'] as String;
      final String status;
      if (row['status'] == 'retracted') {
        status = 'retracted';
      } else if (mine) {
        status = await _deliveryStatus(ref);
      } else {
        status = 'received';
      }
      views.add(V2MessageView(
        ref: ref,
        peer: peer,
        mine: mine,
        createdAt: row['createdAt'] as int,
        text: row['text'] as String? ?? '',
        reply: row['reply'] as Map<String, dynamic>?,
        isImage: row['isImage'] == true,
        imageData: row['imageData'] as Uint8List?,
        mediaPending: row['mediaPending'] == true,
        status: status,
      ));
    }

    // Долговечная очередь: запечатанные, но ещё не принятые сервером.
    final entries =
        (await _store.outboxAll()).where((e) => e['peer'] == peer);
    final mediaParts = <String, List<Map<String, dynamic>>>{};
    final mediaStatus = <String, String>{};
    for (final entry in entries) {
      final message = entry['message'] as Map<String, dynamic>;
      final decoded = await _decodeOutboxMessage(message);
      final status =
          _isBlockedCode(entry['lastError'] as String?) ? 'blocked' : 'queued';
      final media = decoded['media'];
      if (media is Map<String, dynamic>) {
        final id = media['id'] as String;
        (mediaParts[id] ??= []).add({...decoded, 'ref': messageRef(message),
          'createdAt': message['createdAt']});
        // Агрегация статуса медиа: blocked любого чанка блокирует запись.
        if (status == 'blocked' || mediaStatus[id] != 'blocked') {
          mediaStatus[id] = status;
        }
        continue;
      }
      views.add(V2MessageView(
        ref: messageRef(message),
        peer: peer,
        mine: true,
        createdAt: message['createdAt'] as int,
        text: decoded['text'] as String? ?? '',
        reply: decoded['reply'] as Map<String, dynamic>?,
        status: status,
        statusLabel: status == 'blocked'
            ? _blockedLabel(entry['lastError'] as String?)
            : null,
      ));
    }
    for (final entry in mediaParts.entries) {
      final parts = entry.value;
      final assembled = assembleMedia(
          parts.map((p) => p['media'] as Map<String, dynamic>).toList());
      final first = parts.first;
      views.add(V2MessageView(
        ref: first['ref'] as String,
        peer: peer,
        mine: true,
        createdAt: first['createdAt'] as int,
        text: '',
        isImage: assembled != null,
        imageData: assembled,
        mediaPending: assembled == null,
        status: mediaStatus[entry.key] ?? 'queued',
      ));
    }

    views.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return views;
  }

  @override
  Future<String> send(String peer, String text,
      {Map<String, dynamic>? reply}) {
    final result = _sendQueue.then((_) => _send(peer, text, reply: reply));
    _sendQueue = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  Future<String> _send(String peer, String text,
      {Map<String, dynamic>? reply}) async {
    final before =
        (await _store.outboxAll()).map((e) => e['id'] as String).toSet();
    try {
      final id = await _repository.sendMessage(peer, text, reply: reply);
      _emit();
      return id;
    } catch (error) {
      if (_isNetworkError(error)) {
        // repository коммитит конверт в outbox ДО flush: сетевой сбой
        // доставки не отменяет отправку — сообщение остаётся в очереди
        // тем же ciphertext/ID и будет доставлено повторным sync.
        final after = await _store.outboxAll();
        final added = after.where(
            (e) => e['peer'] == peer && !before.contains(e['id']));
        if (added.isNotEmpty) {
          _emit();
          return added.last['id'] as String;
        }
        // Конверт не был закоммичен (сбой сети до seal): offline-seal
        // против pinned каталога контакта.
        return _sealOfflinePeer(peer, encodePayload(text, reply));
      }
      rethrow;
    }
  }

  /// Offline-seal peer-чата против закреплённого каталога: history контакта
  /// сохраняется долговечно при каждой успешной ОНЛАЙН-верификации
  /// (confirmContact/_peerDirectory). Lease и цепочки сверяются внутри
  /// sealMessage (verifyHistory против checkpoint): подмена/rollback/fork
  /// блокируют запечатку ДО коммита. Конверт коммитится в outbox тем же
  /// ciphertext/ID — retry через flushOutbox, без перешифрования.
  Future<String> _sealOfflinePeer(String peer, String payload) async {
    final acc = _repository.accountSnapshot;
    final ownHistory = _repository.ownHistory;
    if (acc == null || ownHistory == null) {
      throw StateError('Устройство не зарегистрировано в device-v2.');
    }
    final self = peer == account;
    final contact = self ? null : await _store.loadContact(peer);
    if (!self && (contact == null || contact['confirmed'] != true)) {
      throw StateError('Контакт не подтверждён: сверьте genesis digest.');
    }
    final peerHistory =
        self ? ownHistory : await _repository.contactHistory(peer);
    if (peerHistory == null) {
      throw StateError(
          'Нет соединения: каталог собеседника ещё не проверен онлайн. Повторите отправку после подключения.');
    }
    final message = await _repository.v2.sealMessage(
        payload,
        ownHistory,
        peerHistory,
        // Текущая сессия устройства: flushOutbox ищет свой конверт по тому
        // же deviceId, retry подписывается тем же ключом сессии.
        _session,
        AccountTrust(
            root: _repository.root,
            genesis: acc['genesis'] as Map<String, dynamic>,
            checkpoint: acc['checkpoint'] as Map<String, dynamic>),
        AccountTrust(
            root: self ? _repository.root : contact!['root'] as String,
            genesis: self
                ? acc['genesis'] as Map<String, dynamic>
                : contact!['genesis'] as Map<String, dynamic>,
            checkpoint: self
                ? acc['checkpoint'] as Map<String, dynamic>
                : contact!['checkpoint'] as Map<String, dynamic>));
    await _store.putOutbox(message['id'] as String, peer, message);
    _emit();
    return message['id'] as String;
  }

  @override
  Future<void> confirmContact(String peer, String genesisDigest) async {
    await _repository.confirmContact(peer, genesisDigest);
    _emit();
  }

  @override
  Future<bool> peerUpgradeBlocked(String peer) =>
      _repository.isPeerUpgradeBlocked(peer);

  @override
  Future<void> markRead(List<String> refs) async {
    if (refs.isEmpty) return;
    try {
      await _repository.markRead(refs);
    } catch (_) {
      // Read-ACK идемпотентен и best-effort: сбой не ломает диалог,
      // непрочитанные refs будут отправлены при следующем открытии.
    }
  }

  @override
  Future<void> deleteLocal(String ref) async {
    await _repository.deleteLocal(ref);
    _emit();
  }

  @override
  Future<void> retract(String ref) async {
    await _repository.retractMessage(ref);
    _emit();
  }

  @override
  void watch(String peer) => _transport.watch(peer);
  @override
  void unwatch(String peer) => _transport.unwatch(peer);
  @override
  void sendTyping(String peer) => _transport.sendTyping(peer);

  @override
  Future<V2ProfileView?> profile() async {
    final acc = _repository.accountSnapshot;
    if (acc == null) return null;
    final history = acc['history'] as List;
    final tip = history.last as Map<String, dynamic>;
    return V2ProfileView(
      account: account,
      rootFingerprint: spkiFingerprint(_repository.root),
      genesisDigest:
          sha256Hex(genesisText(acc['genesis'] as Map<String, dynamic>)),
      revision: tip['revision'] as int,
      leaseExpiresAt: tip['expiresAt'] as int,
      deviceCount: (tip['devices'] as List).length,
      sessionId: acc['sessionId'] as String? ?? 'primary',
    );
  }

  @override
  Future<List<V2DeviceView>> devices({bool refresh = false}) async {
    final acc = _repository.accountSnapshot;
    if (acc == null) return [];
    var tip = (acc['history'] as List).last as Map<String, dynamic>;
    if (refresh) {
      // Read-only сверка с сервером: цепочка проверяется от genesis против
      // закреплённого checkpoint; локальное состояние не перезаписывается.
      // Auth — текущим устройством.
      final dir = await _transport.directory(account,
          account: account,
          id: _sessionId,
          privateKey: _session.signingPrivateKey);
      await _repository.v2.verifier.verifyHistory(dir['history'] as List,
          dir['root'] as String, acc['checkpoint'] as Map<String, dynamic>,
          genesis: dir['genesis'] as Map<String, dynamic>);
      tip = (dir['history'] as List).last as Map<String, dynamic>;
    }
    return [
      for (final d in (tip['devices'] as List).cast<Map<String, dynamic>>())
        V2DeviceView(
          id: d['id'] as String,
          fingerprint: spkiFingerprint(d['encryptionKey'] as String),
          current: d['id'] == _sessionId,
          primary: d['id'] == 'primary',
        )
    ];
  }

  @override
  void dispose() {
    _disposed = true;
    _wakeDebounce?.cancel();
    if (_started) {
      _transport.onWake = null;
      _transport.onTyping = null;
      _transport.onPresence = null;
    }
    _changes.close();
    _typing.close();
    _presence.close();
  }
}
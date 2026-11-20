/// Локальный импорт истории v1 (SQLCipher) в хранилище device-v2.
///
/// Выполняется ТОЛЬКО после успешного enrollLegacy и только на устройстве:
///  - чтение v1 идёт через существующий DatabaseService (исключительно SELECT);
///  - каждая запись расшифровывается исходным v1-ключом, нормализуется и
///    перешифровывается свежим AES-256-GCM конвертом в формат v2-хранилища
///    (таблица v2_messages через V2Store);
///  - оригинальные метаданные сохраняются: id (network_id либо local:<rowid>),
///    createdAt (timestamp), from/to (peer/direction), reply (значения v1
///    {s,t} переносятся в {from,text} без потери содержимого);
///  - дедуп по ref `v1:<peer>:<id>` — тому же пространству, что использует
///    мост (syncLegacyInbox), поэтому одна и та же запись не появится дважды;
///  - курсор + долговечный журнал: сбой посередине продолжает импорт с
///    последней зафиксированной позиции, повторная обработка батча отсекается
///    дедупом по ref (без дублей и без потери);
///  - v1-хранилище НИКОГДА не удаляется и не изменяется; plaintext истории не
///    покидает устройство и не отправляется на сервер.
///
/// Недоставленные исходящие (queued/upgrade_required/в outbox v1) не
/// импортируются: они остаются в очередях v1 до дренирования мостом, чтобы
/// не выдавать недоставленное за доставленное. Группы v1 не переносятся
/// (протокол v2 — только диалоги 1:1); их история остаётся в v1.
///
/// Журнал импорта — аддитивная таблица v2_history_import_journal, создаётся
/// здесь же (CREATE TABLE IF NOT EXISTS): схема DatabaseService не меняется,
/// v1-таблицы не затрагиваются.
library;

import 'dart:convert';

import 'package:fast_rsa/fast_rsa.dart';
import 'package:sqflite_common/sqflite.dart' show ConflictAlgorithm, Database;

import '../../database/database_service.dart';
import '../crypto_service.dart';
import 'repository.dart';
import 'store.dart';

/// Прогресс импорта: обработано записей / всего записей v1.
typedef HistoryImportProgress = void Function(int processed, int total);

/// Итог импорта (счётчики долговечного журнала, накопительные по запускам).
class HistoryImportResult {
  /// Всего записей в v1-хранилище на момент запуска.
  final int total;

  /// Записей перенесено в v2 (суммарно по журналам всех запусков).
  final int imported;

  /// Повторно встреченные записи, отсечённые дедупом по ref.
  final int duplicates;

  /// Недоставленные исходящие, оставленные в очередях v1.
  final int pendingLeft;

  /// Записи, которые не удалось расшифровать (остались в v1 без изменений).
  final int failed;

  /// Запуск продолжил ранее начатый импорт (журнал уже существовал).
  final bool resumed;

  /// Скан v1 завершён (включая повтор неудачных записей).
  final bool done;

  const HistoryImportResult({
    required this.total,
    required this.imported,
    required this.duplicates,
    required this.pendingLeft,
    required this.failed,
    required this.resumed,
    required this.done,
  });
}

class V1HistoryImporter {
  final DatabaseService database;
  final V2Store store;
  final CryptoService crypto;
  final String account;

  /// Приватный якорь устройства (PEM); после rotation — новый ключ.
  final String privateKey;

  /// Исходный v1-ключ после rotation: им расшифровывается старая история.
  final String? legacyPrivateKey;

  /// Размер батча между фиксациями курсора в журнале.
  final int batchSize;

  /// Защита от параллельных запусков по одному аккаунту в этом процессе.
  static final Set<String> _active = <String>{};

  V1HistoryImporter({
    required this.database,
    required this.store,
    required this.crypto,
    required this.account,
    required this.privateKey,
    this.legacyPrivateKey,
    this.batchSize = 100,
  }) : assert(batchSize > 0, 'batchSize должен быть положительным');

  /// Импорт истории репозитория после enrollLegacy/enrollWithRotation.
  factory V1HistoryImporter.forRepository(V2ChatRepository repository,
          {required DatabaseService database, int batchSize = 100}) =>
      V1HistoryImporter(
          database: database,
          store: repository.store,
          crypto: repository.crypto,
          account: repository.account,
          privateKey: repository.privateKey,
          legacyPrivateKey: repository.legacyPrivateKey,
          batchSize: batchSize);

  // ── Состояние запуска (фиксируется в журнале после каждого батча) ──────

  int _lastId = 0;
  int _processed = 0;
  int _total = 0;
  int _imported = 0;
  int _duplicates = 0;
  int _pendingLeft = 0;
  final Set<int> _failedIds = <int>{};
  bool _journalExisted = false;

  late Map<int, String> _peerByConversation;
  late Set<String> _outboxIds;
  late String _decryptionKey;
  late String _encryptionPublicKey;

  /// Был ли импорт уже завершён ранее (для идемпотентного UI).
  Future<bool> completed() async {
    final db = await database.database;
    await _ensureJournalTable(db);
    final rows = await db.query('v2_history_import_journal',
        columns: ['phase'],
        where: 'account = ?',
        whereArgs: [account],
        limit: 1);
    return rows.isNotEmpty && rows.first['phase'] == 'done';
  }

  /// Полный скан v1 с курсором и дедупом. Идемпотентен: повторный запуск
  /// досканирует только новые записи и повторит неудачные; дубли не создаёт.
  Future<HistoryImportResult> run({HistoryImportProgress? onProgress}) async {
    // Импорт возможен только после enrollment: иначе нет аккаунта v2.
    final acc = await store.loadAccount(account);
    if (acc == null) {
      throw StateError(
          'Импорт истории доступен после регистрации устройства на v2.');
    }
    if (!_active.add(account)) {
      throw StateError('Импорт истории уже выполняется.');
    }
    try {
      final db = await database.database;
      await _ensureJournalTable(db);
      await _loadJournal(db);
      _total = await _count(db, 'SELECT COUNT(*) AS n FROM messages');
      // Ключ расшифровки v1 и ключ перешифровки совпадают с тем, которым
      // getMessages читает bridged-записи `v1:` (legacyPrivateKey ?? privateKey):
      // история остаётся читаемой и после rotation, и без неё.
      _decryptionKey = legacyPrivateKey ?? privateKey;
      _encryptionPublicKey =
          await RSA.convertPrivateKeyToPublicKey(_decryptionKey);
      _peerByConversation = {
        for (final row in await database.getConversations())
          row['id'] as int: row['name'] as String
      };
      _outboxIds = {
        for (final row in await db.query('outbox', columns: ['network_id']))
          if (row['network_id'] != null) row['network_id'] as String
      };
      await _saveJournal(db, 'running');
      onProgress?.call(_processed, _total);

      // Основной скан: только записи после курсора, по возрастанию rowid.
      while (true) {
        final rows = await db.rawQuery(
            'SELECT id, conversation_id, encrypted_content, network_id, '
            'network_sender, is_outgoing, status, timestamp '
            'FROM messages WHERE id > ? ORDER BY id ASC LIMIT ?',
            [_lastId, batchSize]);
        if (rows.isEmpty) break;
        for (final row in rows) {
          await processRow(row);
        }
        _lastId = rows.last['id'] as int;
        _processed =
            await _count(db, 'SELECT COUNT(*) AS n FROM messages WHERE id <= ?',
                [_lastId]);
        await _saveJournal(db, 'running');
        onProgress?.call(_processed, _total);
      }

      // Повтор записей, не расшифровавшихся в прошлых запусках: ключ мог
      // появиться позже (например, после восстановления legacy-ключа).
      if (_failedIds.isNotEmpty) {
        final retry = _failedIds.toList()..sort();
        _failedIds.clear();
        for (final id in retry) {
          final rows = await db.rawQuery(
              'SELECT id, conversation_id, encrypted_content, network_id, '
              'network_sender, is_outgoing, status, timestamp '
              'FROM messages WHERE id = ?',
              [id]);
          if (rows.isNotEmpty) await processRow(rows.first);
        }
        await _saveJournal(db, 'running');
      }

      await _saveJournal(db, 'done');
      onProgress?.call(_processed, _total);
      return HistoryImportResult(
          total: _total,
          imported: _imported,
          duplicates: _duplicates,
          pendingLeft: _pendingLeft,
          failed: _failedIds.length,
          resumed: _journalExisted,
          done: true);
    } finally {
      _active.remove(account);
    }
  }

  /// Обработка одной записи v1. Выделена в защищённый метод, чтобы тест
  /// мог имитировать сбой посередине батча (crash-resume).
  Future<void> processRow(Map<String, dynamic> row) async {
    final id = row['id'] as int;
    final outgoing = (row['is_outgoing'] as int? ?? 0) == 1;
    final networkId = row['network_id'] as String?;
    final sender = (row['network_sender'] as String? ?? '').trim();
    final senderValid =
        sender.isNotEmpty && sender != '@self' && !sender.startsWith('legacy:');
    final convName = _peerByConversation[row['conversation_id'] as int];
    // «Избранное» и чат с собственным ником — self-chat аккаунта v2.
    final String? peer = convName == null
        ? (senderValid ? sender : null)
        : (convName == 'Избранное' || convName == account ? account : convName);
    if (peer == null) {
      // Нет ни диалога, ни отправителя: запись остаётся в v1, не теряется.
      _failedIds.add(id);
      return;
    }
    final status = row['status'] as String? ?? 'sent';
    if (outgoing &&
        (status == 'queued' ||
            status == 'pending' ||
            status == 'failed' ||
            status == 'upgrade_required' ||
            (networkId != null && _outboxIds.contains(networkId)))) {
      // Недоставленное остаётся в очереди v1: мост дренирует её отдельно.
      _pendingLeft++;
      return;
    }
    final String plain;
    try {
      plain = await crypto.decryptData(
          row['encrypted_content'] as String, _decryptionKey);
    } catch (_) {
      // Повреждённая/чужая запись: фиксируем для повтора, v1 не трогаем.
      _failedIds.add(id);
      return;
    }
    final messageId = networkId ?? 'local:$id';
    // Реф входящего совпадает с мостом (`v1:<from>:<id>`): запись, уже
    // доставленная мостом, не продублируется локальным импортом.
    final refPeer = !outgoing && senderValid ? sender : peer;
    final ref = 'v1:$refPeer:$messageId';
    final payload = Map<String, dynamic>.from(jsonDecode(
            await crypto.encryptData(_normalizeReply(plain), _encryptionPublicKey))
        as Map);
    final createdAt = (row['timestamp'] as num).toInt();
    if (outgoing) {
      if (await store.hasRef(ref)) {
        _duplicates++;
      } else {
        await store.insertSent(
            ref: ref,
            peer: peer,
            messageId: messageId,
            createdAt: createdAt,
            payload: payload);
        _imported++;
      }
    } else {
      final inserted = await store.insertReceived(
          ref: ref,
          peer: peer,
          messageId: messageId,
          createdAt: createdAt,
          payload: payload);
      if (inserted) {
        _imported++;
      } else {
        _duplicates++;
      }
    }
  }

  /// Reply v1 хранится как {"t","r":{"s","t"}}; v2-UI читает {from,text}.
  /// Значения переносятся без потери; остальные форматы не изменяются.
  String _normalizeReply(String plain) {
    try {
      final parsed = jsonDecode(plain);
      if (parsed is Map<String, dynamic> && parsed['t'] is String) {
        final r = parsed['r'];
        if (r is Map<String, dynamic> &&
            r['t'] is String &&
            r['text'] is! String) {
          return jsonEncode({
            't': parsed['t'],
            'r': {
              'from': r['s'] is String ? r['s'] : '',
              'text': r['t'],
            }
          });
        }
      }
    } catch (_) {
      // Обычный текст (в том числе JSON-подобный) переносится как есть.
    }
    return plain;
  }

  // ── Журнал (аддитивная таблица, v1 не затрагивается) ───────────────────

  Future<void> _ensureJournalTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS v2_history_import_journal (
        account      TEXT PRIMARY KEY,
        phase        TEXT NOT NULL,
        last_id      INTEGER NOT NULL DEFAULT 0,
        processed    INTEGER NOT NULL DEFAULT 0,
        total        INTEGER NOT NULL DEFAULT 0,
        imported     INTEGER NOT NULL DEFAULT 0,
        duplicates   INTEGER NOT NULL DEFAULT 0,
        pending_left INTEGER NOT NULL DEFAULT 0,
        failed_ids   TEXT NOT NULL DEFAULT '[]',
        created_at   INTEGER NOT NULL,
        updated_at   INTEGER NOT NULL
      )
    ''');
  }

  Future<void> _loadJournal(Database db) async {
    final rows = await db.query('v2_history_import_journal',
        where: 'account = ?', whereArgs: [account], limit: 1);
    _journalExisted = rows.isNotEmpty;
    if (rows.isEmpty) return;
    final row = rows.first;
    _lastId = row['last_id'] as int;
    _processed = row['processed'] as int;
    _total = row['total'] as int;
    _imported = row['imported'] as int;
    _duplicates = row['duplicates'] as int;
    _pendingLeft = row['pending_left'] as int;
    _failedIds
      ..clear()
      ..addAll((jsonDecode(row['failed_ids'] as String) as List).cast<int>());
  }

  Future<void> _saveJournal(Database db, String phase) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert(
        'v2_history_import_journal',
        {
          'account': account,
          'phase': phase,
          'last_id': _lastId,
          'processed': _processed,
          'total': _total,
          'imported': _imported,
          'duplicates': _duplicates,
          'pending_left': _pendingLeft,
          'failed_ids': jsonEncode(_failedIds.toList()..sort()),
          'created_at': now,
          'updated_at': now
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<int> _count(Database db, String sql, [List<Object?> args = const []])
      async =>
      (await db.rawQuery(sql, args)).first['n'] as int;
}
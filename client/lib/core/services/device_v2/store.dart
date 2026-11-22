/// Локальное хранилище device-v2 поверх существующей SQLCipher-БД.
///
/// Аддитивные таблицы v9: ciphertext сообщений, replay-дедупликация,
/// подписанный outbox (тот же ciphertext/ID при retry), checkpoints каталогов.
/// v1-таблицы, ключи и история не изменяются.
library;

import 'dart:convert';

import 'package:sqflite_common/sqflite.dart';

import '../../database/database_service.dart';

class V2Store {
  final DatabaseService _service;
  V2Store(this._service);

  String? _owner;
  Future<Database> get chatDatabase =>
      _owner == null ? _db : _service.chatDatabase(_owner!);
  Future<Database> get _db => _service.database;

  Future<void> saveAccount({
    required String account,
    required String root,
    required Map<String, dynamic> genesis,
    required List<dynamic> history,
    required Map<String, dynamic> checkpoint,
    required String sessionId,
    Map<String, dynamic>? recovery,
    String? anchorKey,
    String? legacyKey,
  }) async {
    _owner = account;
    await chatDatabase;
    await (await _db).insert(
        'v2_accounts',
        {
          'account': account,
          'root': root,
          'genesis': jsonEncode(genesis),
          'history': jsonEncode(history),
          'checkpoint': jsonEncode(checkpoint),
          'recovery': recovery == null ? null : jsonEncode(recovery),
          'session_id': sessionId,
          // Колонки появились в schema v11: на более старых схемах не пишем.
          if (anchorKey != null) 'anchor_key': anchorKey,
          if (legacyKey != null) 'legacy_key': legacyKey,
          'created_at': DateTime.now().millisecondsSinceEpoch
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> loadAccount(String account) async {
    final rows = await (await _db).query('v2_accounts',
        where: 'account=?', whereArgs: [account], limit: 1);
    if (rows.isEmpty) return null;
    final row = rows.first;
    _owner = account;
    return {
      'account': row['account'],
      'root': row['root'],
      'genesis': jsonDecode(row['genesis'] as String),
      'history': jsonDecode(row['history'] as String),
      'checkpoint': jsonDecode(row['checkpoint'] as String),
      'recovery': row['recovery'] == null
          ? null
          : jsonDecode(row['recovery'] as String),
      'sessionId': row['session_id'],
      'anchorKey': row['anchor_key'],
      'legacyKey': row['legacy_key']
    };
  }

  Future<void> saveContact({
    required String account,
    required String root,
    required Map<String, dynamic> genesis,
    required Map<String, dynamic> checkpoint,
    required String genesisDigest,
    required bool confirmed,
    List<dynamic>? history,
  }) async {
    await (await chatDatabase).insert(
        'v2_contacts',
        {
          'account': account,
          'root': root,
          'genesis': jsonEncode(genesis),
          'checkpoint': jsonEncode(checkpoint),
          'genesis_digest': genesisDigest,
          'confirmed': confirmed ? 1 : 0,
          // Проверенная цепочка каталога для offline-seal (schema v12).
          // null у старых записей: offline-seal недоступен до онлайн-верификации.
          'history': history == null ? null : jsonEncode(history),
          'updated_at': DateTime.now().millisecondsSinceEpoch
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> loadContact(String account) async {
    final rows = await (await chatDatabase).query('v2_contacts',
        where: 'account=?', whereArgs: [account], limit: 1);
    if (rows.isEmpty) return null;
    final row = rows.first;
    return {
      'account': row['account'],
      'root': row['root'],
      'genesis': jsonDecode(row['genesis'] as String),
      'checkpoint': jsonDecode(row['checkpoint'] as String),
      'genesisDigest': row['genesis_digest'],
      'confirmed': row['confirmed'] == 1,
      'history':
          row['history'] == null ? null : jsonDecode(row['history'] as String)
    };
  }

  Future<List<Map<String, dynamic>>> listContacts() async {
    final rows =
        await (await chatDatabase).query('v2_contacts', orderBy: 'account');
    return [
      for (final row in rows)
        {
          'account': row['account'],
          'genesisDigest': row['genesis_digest'],
          'confirmed': row['confirmed'] == 1 &&
              jsonDecode(row['checkpoint'] as String)['manual'] != false
        }
    ];
  }

  /// Атомарная вставка входящего ciphertext до ACK; false = уже обработано.
  Future<bool> insertReceived({
    required String ref,
    required String peer,
    required String messageId,
    required int createdAt,
    required Map<String, dynamic> payload,
  }) async {
    final db = await chatDatabase;
    return db.transaction((txn) async {
      final existing = await txn.query('v2_messages',
          where: 'ref=?', whereArgs: [ref], limit: 1);
      if (existing.isNotEmpty) return false;
      await txn.insert('v2_messages', {
        'ref': ref,
        'peer': peer,
        'direction': 'in',
        'message_id': messageId,
        'created_at': createdAt,
        'payload': jsonEncode(payload),
        'status': 'received',
        'acked': 0
      });
      return true;
    });
  }

  Future<void> markAcked(List<String> refs) async {
    if (refs.isEmpty) return;
    final db = await chatDatabase;
    await db.transaction((txn) async {
      for (final ref in refs) {
        await txn.update('v2_messages', {'acked': 1},
            where: 'ref=?', whereArgs: [ref]);
      }
    });
  }

  Future<Map<String, dynamic>?> messageByRef(String ref) async {
    final rows = await (await chatDatabase)
        .query('v2_messages', where: 'ref=?', whereArgs: [ref], limit: 1);
    if (rows.isEmpty) return null;
    final row = rows.first;
    return {
      'ref': row['ref'],
      'peer': row['peer'],
      'direction': row['direction'],
      'messageId': row['message_id'],
      'createdAt': row['created_at'],
      'payload': row['payload'],
      'status': row['status'],
      'acked': row['acked'] == 1
    };
  }

  /// Локальное удаление («Удалить у себя»): другие устройства сохраняют копию.
  Future<void> deleteMessage(String ref) async {
    final db = await chatDatabase;
    await db.transaction((txn) async {
      await txn.delete('v2_messages', where: 'ref=?', whereArgs: [ref]);
      await txn.delete('v2_delivery', where: 'ref=?', whereArgs: [ref]);
    });
  }

  Future<void> insertSent({
    required String ref,
    required String peer,
    required String messageId,
    required int createdAt,
    required Map<String, dynamic> payload,
  }) async {
    await (await chatDatabase).insert(
        'v2_messages',
        {
          'ref': ref,
          'peer': peer,
          'direction': 'out',
          'message_id': messageId,
          'created_at': createdAt,
          'payload': jsonEncode(payload),
          'status': 'server',
          'acked': 1
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<bool> hasRef(String ref) async => (await (await chatDatabase)
          .query('v2_messages', where: 'ref=?', whereArgs: [ref], limit: 1))
      .isNotEmpty;

  Future<List<Map<String, dynamic>>> messagesByPeer(String peer) async {
    final rows = await (await chatDatabase).query('v2_messages',
        where: 'peer=?', whereArgs: [peer], orderBy: 'created_at, ref');
    return [
      for (final row in rows)
        {
          'ref': row['ref'],
          'peer': row['peer'],
          'direction': row['direction'],
          'messageId': row['message_id'],
          'createdAt': row['created_at'],
          'payload': row['payload'],
          'status': row['status'],
          'acked': row['acked'] == 1
        }
    ];
  }

  Future<List<Map<String, Object?>>> historyPage(String after) async =>
      (await chatDatabase).query('v2_messages',
          where: 'ref > ? AND ref NOT LIKE ?',
          whereArgs: [after, 'v1:%'],
          orderBy: 'ref',
          limit: 16);

  Future<bool> hasImportedPeer(String peer) async =>
      (await (await chatDatabase).query('v2_messages',
              columns: ['ref'],
              where: "peer=? AND status='imported'",
              whereArgs: [peer],
              limit: 1))
          .isNotEmpty;

  Future<bool> importHistoryRow(
      Map<String, dynamic> row, String payload) async {
    final db = await chatDatabase;
    return db.transaction((txn) async {
      final ref = row['ref'] as String;
      if ((await txn.query('v2_messages',
              columns: ['ref'], where: 'ref=?', whereArgs: [ref]))
          .isNotEmpty) return false;
      await txn.insert('v2_messages', {
        'ref': ref,
        'peer': row['peer'],
        'direction': row['direction'],
        'message_id': row['id'],
        'created_at': row['createdAt'],
        'status': row['status'] == 'retracted' ? 'retracted' : 'imported',
        'payload': payload,
        'acked': 1
      });
      return true;
    });
  }

  Future<Map<String, int>> unreadCounts() async {
    final db = await chatDatabase;
    await db.execute(
        'CREATE TABLE IF NOT EXISTS v2_chat_read(peer TEXT PRIMARY KEY, until_ms INTEGER NOT NULL)');
    final rows = await db.rawQuery(
        "SELECT m.peer, COUNT(*) AS unread FROM v2_messages m LEFT JOIN v2_chat_read r ON m.peer=r.peer WHERE m.direction='in' AND m.status!='retracted' AND m.created_at>COALESCE(r.until_ms,0) GROUP BY m.peer");
    return {for (final r in rows) r['peer'] as String: r['unread'] as int};
  }

  Future<List<String>> relayReadRefs(List<String> refs) async {
    final db = await chatDatabase;
    final rows = await db.query(
      'v2_messages',
      columns: ['ref'],
      where:
          "status != 'imported' AND ref IN (${List.filled(refs.length, '?').join(',')})",
      whereArgs: refs,
    );
    return rows.map((row) => row['ref'] as String).toList();
  }

  Future<void> rememberRead(List<String> refs) async {
    if (refs.isEmpty) return;
    final db = await chatDatabase;
    await db.execute(
        'CREATE TABLE IF NOT EXISTS v2_chat_read(peer TEXT PRIMARY KEY, until_ms INTEGER NOT NULL)');
    await db.rawInsert(
        "INSERT INTO v2_chat_read(peer,until_ms) SELECT peer,MAX(created_at) FROM v2_messages WHERE ref IN (${List.filled(refs.length, '?').join(',')}) AND direction='in' GROUP BY peer ON CONFLICT(peer) DO UPDATE SET until_ms=MAX(until_ms,excluded.until_ms)",
        refs);
  }

  Future<void> putMediaOutbox(
      String peer, List<Map<String, dynamic>> messages) async {
    final batch = (await chatDatabase).batch();
    for (final message in messages) {
      batch.insert('v2_outbox', {
        'id': message['id'],
        'peer': peer,
        'message': jsonEncode(message),
        'created_at': DateTime.now().millisecondsSinceEpoch
      });
    }
    await batch.commit(noResult: true);
  }

  Future<void> putOutbox(
      String id, String peer, Map<String, dynamic> message) async {
    await (await chatDatabase).insert(
        'v2_outbox',
        {
          'id': id,
          'peer': peer,
          'message': jsonEncode(message),
          'created_at': DateTime.now().millisecondsSinceEpoch
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> outboxAll() async {
    final rows =
        await (await chatDatabase).query('v2_outbox', orderBy: 'created_at');
    return [
      for (final row in rows)
        {
          'id': row['id'],
          'peer': row['peer'],
          'message': jsonDecode(row['message'] as String),
          'attempts': row['attempts'],
          'lastError': row['last_error']
        }
    ];
  }

  Future<void> removeOutbox(String id) async =>
      (await chatDatabase).delete('v2_outbox', where: 'id=?', whereArgs: [id]);

  Future<void> markOutboxAttempt(String id, String error) async =>
      (await chatDatabase).rawUpdate(
          'UPDATE v2_outbox SET attempts=attempts+1, last_error=? WHERE id=?',
          [error, id]);

  Future<void> markRetracted(String ref) async =>
      (await chatDatabase).rawUpdate(
          "UPDATE v2_messages SET status='retracted' WHERE ref=?", [ref]);

  Future<void> upsertDelivery(String ref, String deviceId, int? acknowledgedAt,
      {int? readAt}) async {
    await (await chatDatabase).insert(
        'v2_delivery',
        {
          'ref': ref,
          'device_id': deviceId,
          'acknowledged_at': acknowledgedAt,
          'read_at': readAt
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> deliveryFor(String ref) async {
    final rows = await (await chatDatabase)
        .query('v2_delivery', where: 'ref=?', whereArgs: [ref]);
    return [
      for (final row in rows)
        {
          'deviceId': row['device_id'],
          'acknowledgedAt': row['acknowledged_at'],
          'readAt': row['read_at']
        }
    ];
  }

  // ── Журнал legacy-enrollment (v10): crash-safe миграция ──────────────

  Future<void> saveEnrollmentJournal({
    required String account,
    required String root,
    required Map<String, dynamic> genesis,
    required Map<String, dynamic> manifest,
    required Map<String, dynamic> recoveryBackup,
    String phase = 'prepared',
    Map<String, dynamic>? rotation,
    String? anchorKey,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await (await _db).insert(
        'v2_enrollment_journal',
        {
          'account': account,
          'root': root,
          'genesis': jsonEncode(genesis),
          'manifest': jsonEncode(manifest),
          'recovery_backup': jsonEncode(recoveryBackup),
          'phase': phase,
          // Колонки появились в schema v11: на более старых схемах не пишем.
          if (rotation != null) 'rotation': jsonEncode(rotation),
          // Новый приватный якорь rotation ДО сетевого вызова: crash после
          // серверного коммита не теряет ключ (SQLCipher at-rest).
          if (anchorKey != null) 'anchor_key': anchorKey,
          'created_at': now,
          'updated_at': now
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> loadEnrollmentJournal(String account) async {
    final rows = await (await _db).query('v2_enrollment_journal',
        where: 'account=?', whereArgs: [account], limit: 1);
    if (rows.isEmpty) return null;
    final row = rows.first;
    return {
      'account': row['account'],
      'root': row['root'],
      'genesis': jsonDecode(row['genesis'] as String),
      'manifest': jsonDecode(row['manifest'] as String),
      'recoveryBackup': jsonDecode(row['recovery_backup'] as String),
      'phase': row['phase'],
      'rotation': row['rotation'] == null
          ? null
          : jsonDecode(row['rotation'] as String),
      'anchorKey': row['anchor_key']
    };
  }

  Future<void> deleteEnrollmentJournal(String account) async =>
      (await _db).delete('v2_enrollment_journal',
          where: 'account=?', whereArgs: [account]);

  // ── Журнал pairing (v12): crash-safe подключение второго устройства ────
  //
  // Образец enrollLegacy: долговечные артефакты пишутся ДО сетевых вызовов.
  // role 'new': ключи устройства создаются до offer и переживают любой сбой;
  // проверенное подтверждение журналируется до bootstrap device-сессии.
  // role 'trusted': подписанный манифест и proofs журналируются до install;
  // повтор после серверного коммита перенимает каталог, а не плодит манифесты.
  // Приватные ключи хранятся только в SQLCipher (at-rest), как anchor_key.

  Future<void> savePairingJournal(
      String account, Map<String, dynamic> entry) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    String? encode(Object? value) => value == null ? null : jsonEncode(value);
    await (await _db).insert(
        'v2_pairing_journal',
        {
          'account': account,
          'role': entry['role'],
          'phase': entry['phase'],
          'device_id': entry['deviceId'],
          'encryption_key': entry['encryptionKey'],
          'signing_key': entry['signingKey'],
          'encryption_private': entry['encryptionPrivate'],
          'signing_private': entry['signingPrivate'],
          'offer_text': entry['offerText'],
          'offer': encode(entry['offer']),
          'manifest': encode(entry['manifest']),
          'proofs': encode(entry['proofs']),
          'confirmation_text': entry['confirmationText'],
          'confirmation': encode(entry['confirmation']),
          'root': entry['root'],
          'genesis': encode(entry['genesis']),
          'created_at': entry['createdAt'] ?? now,
          'updated_at': now
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> loadPairingJournal(String account) async {
    final rows = await (await _db).query('v2_pairing_journal',
        where: 'account=?', whereArgs: [account], limit: 1);
    if (rows.isEmpty) return null;
    final row = rows.first;
    Object? decode(Object? value) =>
        value == null ? null : jsonDecode(value as String);
    return {
      'account': row['account'],
      'role': row['role'],
      'phase': row['phase'],
      'deviceId': row['device_id'],
      'encryptionKey': row['encryption_key'],
      'signingKey': row['signing_key'],
      'encryptionPrivate': row['encryption_private'],
      'signingPrivate': row['signing_private'],
      'offerText': row['offer_text'],
      'offer': decode(row['offer']),
      'manifest': decode(row['manifest']),
      'proofs': decode(row['proofs']),
      'confirmationText': row['confirmation_text'],
      'confirmation': decode(row['confirmation']),
      'root': row['root'],
      'genesis': decode(row['genesis']),
      'createdAt': row['created_at']
    };
  }

  Future<void> deletePairingJournal(String account) async => (await _db)
      .delete('v2_pairing_journal', where: 'account=?', whereArgs: [account]);

  /// Долговечные ключи подключённого вторичного устройства: без них сессия
  /// устройства не переживёт перезапуск приложения. Пишутся в completePairing
  /// до фиксации состояния аккаунта; журнал pairing удаляется последним.
  Future<void> saveDeviceKeys({
    required String account,
    required String deviceId,
    required String encryptionKey,
    required String signingKey,
    required String encryptionPrivate,
    required String signingPrivate,
  }) async {
    await (await _db).insert(
        'v2_device_keys',
        {
          'account': account,
          'device_id': deviceId,
          'encryption_key': encryptionKey,
          'signing_key': signingKey,
          'encryption_private': encryptionPrivate,
          'signing_private': signingPrivate,
          'created_at': DateTime.now().millisecondsSinceEpoch
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> loadDeviceKeys(String account) async {
    final rows = await (await _db).query('v2_device_keys',
        where: 'account=?', whereArgs: [account], limit: 1);
    if (rows.isEmpty) return null;
    final row = rows.first;
    return {
      'account': row['account'],
      'deviceId': row['device_id'],
      'encryptionKey': row['encryption_key'],
      'signingKey': row['signing_key'],
      'encryptionPrivate': row['encryption_private'],
      'signingPrivate': row['signing_private']
    };
  }
}

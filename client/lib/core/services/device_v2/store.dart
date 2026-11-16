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

  Future<Database> get _db => _service.database;

  Future<void> saveAccount({
    required String account,
    required String root,
    required Map<String, dynamic> genesis,
    required List<dynamic> history,
    required Map<String, dynamic> checkpoint,
    required String sessionId,
    Map<String, dynamic>? recovery,
  }) async {
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
          'created_at': DateTime.now().millisecondsSinceEpoch
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> loadAccount(String account) async {
    final rows = await (await _db).query('v2_accounts',
        where: 'account=?', whereArgs: [account], limit: 1);
    if (rows.isEmpty) return null;
    final row = rows.first;
    return {
      'account': row['account'],
      'root': row['root'],
      'genesis': jsonDecode(row['genesis'] as String),
      'history': jsonDecode(row['history'] as String),
      'checkpoint': jsonDecode(row['checkpoint'] as String),
      'recovery': row['recovery'] == null
          ? null
          : jsonDecode(row['recovery'] as String),
      'sessionId': row['session_id']
    };
  }

  Future<void> saveContact({
    required String account,
    required String root,
    required Map<String, dynamic> genesis,
    required Map<String, dynamic> checkpoint,
    required String genesisDigest,
    required bool confirmed,
  }) async {
    await (await _db).insert(
        'v2_contacts',
        {
          'account': account,
          'root': root,
          'genesis': jsonEncode(genesis),
          'checkpoint': jsonEncode(checkpoint),
          'genesis_digest': genesisDigest,
          'confirmed': confirmed ? 1 : 0,
          'updated_at': DateTime.now().millisecondsSinceEpoch
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> loadContact(String account) async {
    final rows = await (await _db).query('v2_contacts',
        where: 'account=?', whereArgs: [account], limit: 1);
    if (rows.isEmpty) return null;
    final row = rows.first;
    return {
      'account': row['account'],
      'root': row['root'],
      'genesis': jsonDecode(row['genesis'] as String),
      'checkpoint': jsonDecode(row['checkpoint'] as String),
      'genesisDigest': row['genesis_digest'],
      'confirmed': row['confirmed'] == 1
    };
  }

  Future<List<Map<String, dynamic>>> listContacts() async {
    final rows = await (await _db).query('v2_contacts', orderBy: 'account');
    return [
      for (final row in rows)
        {
          'account': row['account'],
          'genesisDigest': row['genesis_digest'],
          'confirmed': row['confirmed'] == 1
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
    final db = await _db;
    return db.transaction((txn) async {
      final existing = await txn
          .query('v2_messages', where: 'ref=?', whereArgs: [ref], limit: 1);
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
    final db = await _db;
    await db.transaction((txn) async {
      for (final ref in refs) {
        await txn.update('v2_messages', {'acked': 1},
            where: 'ref=?', whereArgs: [ref]);
      }
    });
  }

  Future<Map<String, dynamic>?> messageByRef(String ref) async {
    final rows = await (await _db)
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
    final db = await _db;
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
    await (await _db).insert(
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

  Future<bool> hasRef(String ref) async => (await (await _db)
          .query('v2_messages', where: 'ref=?', whereArgs: [ref], limit: 1))
      .isNotEmpty;

  Future<List<Map<String, dynamic>>> messagesByPeer(String peer) async {
    final rows = await (await _db).query('v2_messages',
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

  Future<void> putOutbox(
      String id, String peer, Map<String, dynamic> message) async {
    await (await _db).insert(
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
    final rows = await (await _db).query('v2_outbox', orderBy: 'created_at');
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
      (await _db).delete('v2_outbox', where: 'id=?', whereArgs: [id]);

  Future<void> markOutboxAttempt(String id, String error) async =>
      (await _db).rawUpdate(
          'UPDATE v2_outbox SET attempts=attempts+1, last_error=? WHERE id=?',
          [error, id]);

  Future<void> upsertDelivery(
      String ref, String deviceId, int? acknowledgedAt) async {
    await (await _db).insert(
        'v2_delivery',
        {'ref': ref, 'device_id': deviceId, 'acknowledged_at': acknowledgedAt},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> deliveryFor(String ref) async {
    final rows = await (await _db)
        .query('v2_delivery', where: 'ref=?', whereArgs: [ref]);
    return [
      for (final row in rows)
        {
          'deviceId': row['device_id'],
          'acknowledgedAt': row['acknowledged_at']
        }
    ];
  }
}
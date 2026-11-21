import 'package:sqflite_common_ffi/sqflite_ffi.dart' as sqflite_ffi;
import 'dart:convert';
import 'package:flutter/services.dart';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// Mobile: encrypted SQLite via SQLCipher
import 'package:sqflite_sqlcipher/sqflite.dart' as sqlcipher;
// Desktop: standard SQLite via FFI
// Common types (Database, ConflictAlgorithm)
import 'package:sqflite_common/sqflite.dart'
    show Database, ConflictAlgorithm, DatabaseFactory, OpenDatabaseOptions;
import 'package:pointycastle/export.dart' as pc;

// Keep the existing derivation parameters and stored-key format. Initial key
// generation is CPU-heavy and must not block the first frame or keyboard input.
String _deriveDatabaseKey(List<Uint8List> input) {
  final pbkdf2 = pc.PBKDF2KeyDerivator(pc.HMac(pc.SHA256Digest(), 64));
  pbkdf2.init(pc.Pbkdf2Parameters(input[1], 2100000, 32));
  return base64Url.encode(pbkdf2.process(input[0]));
}

/// Returns true when running on a mobile platform that supports SQLCipher.
bool get _isMobile => Platform.isAndroid || Platform.isIOS;

/// Unified database service.
///
/// Android/iOS use SQLCipher with a key in OS secure storage.
/// Desktop production storage is unsupported; tests inject their own factory.
class DatabaseService {
  static const String _dbName = 'shade.db';
  static const int _dbVersion = 12;
  static const String _dbKeyStorageKey = 'sqlcipher_db_key';

  final FlutterSecureStorage _secureStorage;

  /// Holds the database handle.
  Database? _db;
  Future<Database>? _opening;
  DatabaseFactory? _testFactory;
  final _chatDatabases = <String, Future<Database>>{};
  Future<Database> chatDatabase(String account) {
    if (!RegExp(r'^[a-z0-9_]{3,32}$').hasMatch(account))
      throw ArgumentError('Invalid chat account');
    return _chatDatabases.putIfAbsent(
        account,
        () => _openChats(account).catchError((Object error) {
              _chatDatabases.remove(account);
              throw error;
            }));
  }

  Future<Database> _openChats(String account) async {
    final base = await database;
    // Keep the original SQLCipher file for its existing account. Additional
    // accounts must never enumerate another account's contacts or outbox.
    final owner = await base.transaction((txn) async {
      await txn.execute(
          'CREATE TABLE IF NOT EXISTS v2_chat_owner(id INTEGER PRIMARY KEY, account TEXT NOT NULL)');
      final known = await txn.query('v2_chat_owner', limit: 1);
      if (known.isNotEmpty) return known.first['account'];
      final users =
          await txn.query('v2_accounts', columns: ['account'], limit: 2);
      final first = users.isEmpty
          ? account
          : users.length == 1
              ? users.first['account'] as String
              : '';
      await txn.insert('v2_chat_owner', {'id': 1, 'account': first});
      return first;
    });
    if (owner == account) return base;
    final path = p.join(p.dirname(base.path), 'shade-v2-$account.db');
    final factory = _testFactory;
    if (factory != null)
      return factory.openDatabase(path,
          options: OpenDatabaseOptions(
              version: _dbVersion, onCreate: _onCreate, onUpgrade: _onUpgrade));
    return _open(path);
  }

  DatabaseService({FlutterSecureStorage? secureStorage})
      : _secureStorage = secureStorage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  /// Opens the real schema on a test-provided SQLite factory; never used by
  /// production code (mobile still always opens SQLCipher with a key).
  static Future<DatabaseService> openForTest(
      DatabaseFactory factory, String path,
      {bool createVersion4 = false, int? schemaVersion}) async {
    final service = DatabaseService().._testFactory = factory;
    final version = schemaVersion ?? (createVersion4 ? 4 : _dbVersion);
    service._db = await factory.openDatabase(path,
        options: OpenDatabaseOptions(
            version: version,
            onCreate: (db, version) async {
              await service._createSchemaV1(db);
              await service._createSchemaV2(db);
              await service._createSchemaV3(db);
              if (version >= 5) await service._createSchemaV5(db);
              if (version >= 6) await service._createSchemaV6(db);
              if (version >= 7) await service._createSchemaV7(db);
              if (version >= 8) await service._createSchemaV8(db);
              if (version >= 9) await service._createSchemaV9(db);
            if (version >= 10) await service._createSchemaV10(db);
            if (version >= 11) await service._createSchemaV11(db);
            if (version >= 12) await service._createSchemaV12(db);
            },
            onUpgrade: service._onUpgrade));
    return service;
  }

  Future<bool> hasNetworkMessage(String id, {required String sender}) async =>
      (await (await database).query('messages',
              columns: ['id'],
              where: 'network_id = ? AND network_sender = ?',
              whereArgs: [id, sender],
              limit: 1))
          .isNotEmpty;

  // ── Lifecycle ───────────────────────────────────────────────

  Future<Database> get database async {
    _db ??= await (_opening ??= _open());
    return _db!;
  }

  Future<Database> _open([String? path]) async {
    if (!_isMobile) {
      throw UnsupportedError(
          'Shade currently supports encrypted production storage on Android/iOS only. Desktop SQLCipher is not configured.');
    }
    final dir = await sqlcipher.getDatabasesPath();
    final key = await _getOrCreateKey();
    final db = await sqlcipher.openDatabase(path ?? p.join(dir, _dbName),
        version: _dbVersion,
        password: key,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade);
    await _verifyDatabaseIntegrity(db);
    return db;
  }

  // MED-04: Parameterized queries — SQL injection safe
  Future<void> _verifyDatabaseIntegrity(Database db) async {
    try {
      // MED-04: No user input in this query - safe
      final result =
          await db.rawQuery('SELECT count(*) as cnt FROM sqlite_master');
      final count = result.first['cnt'] as int?;
      if (count != null) {
        debugPrint('[DatabaseService] Database integrity verified OK');
      } else {
        throw Exception('Unexpected integrity check result');
      }
    } catch (e) {
      throw Exception(
        'Database integrity check failed. Wrong key or corrupted database.',
      );
    }
  }

  // ── Key management (mobile only) ────────────────────────────

  /// Generates or retrieves the SQLCipher database encryption key.
  Future<String> _getOrCreateKey() async {
    const deviceIdKey = 'shade_device_id';

    try {
      final existing = await _secureStorage.read(key: _dbKeyStorageKey);
      if (existing != null && existing.isNotEmpty) return existing;
    } catch (_) {
      throw StateError(
          'Secure storage unavailable; retry without replacing the database key');
    }

// CRIT-01: Direct Random.secure() bytes generation
    final random = math.Random.secure();
    final masterKey =
        Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)));

    // Get or create device_id for PBKDF2 salt
    String? deviceId;
    try {
      deviceId = await _secureStorage.read(key: deviceIdKey);
      if (deviceId == null || deviceId.isEmpty) {
        deviceId = base64Url
            .encode(Uint8List(16).map((_) => random.nextInt(256)).toList());
        await _secureStorage.write(key: deviceIdKey, value: deviceId);
      }
    } catch (e) {
      deviceId = base64Url
          .encode(Uint8List(16).map((_) => random.nextInt(256)).toList());
    }

    final salt = Uint8List.fromList(utf8.encode(deviceId));
    final String key;
    try {
      if (Platform.isAndroid) {
        key = (await const MethodChannel('com.shade.app/security')
            .invokeMethod<String>(
                'deriveDatabaseKey', {'password': masterKey, 'salt': salt}))!;
      } else {
        key = await compute(_deriveDatabaseKey, [masterKey, salt],
            debugLabel: 'shade-database-key');
      }
    } finally {
      masterKey.fillRange(0, masterKey.length, 0);
    }

    await _secureStorage.write(key: _dbKeyStorageKey, value: key);
    debugPrint(
        '[DatabaseService] Generated new DB encryption key (PBKDF2 with device_id salt)');
    return key;
  }

  // ── Schema creation ─────────────────────────────────────────

  Future<void> _onCreate(Database db, int version) async {
    await _createSchemaV1(db);
    await _createSchemaV2(db);
    await _createSchemaV3(db);
    await _createSchemaV5(db);
    await _createSchemaV6(db);
    await _createSchemaV7(db);
    await _createSchemaV8(db);
    await _createSchemaV9(db);
    await _createSchemaV10(db);
    await _createSchemaV11(db);
    await _createSchemaV12(db);
  }

  Future<void> _createSchemaV1(Database db) async {
    await db.execute('''
      CREATE TABLE users (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        nickname    TEXT    NOT NULL UNIQUE,
        public_key  TEXT    NOT NULL,
        created_at  INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE conversations (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        name        TEXT    NOT NULL,
        public_key  TEXT,
        created_at  INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE contacts (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        nickname    TEXT    NOT NULL UNIQUE,
        public_key  TEXT    NOT NULL,
        signature   TEXT,
        created_at  INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE messages (
        id                INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id   INTEGER NOT NULL,
        sender_id         INTEGER NOT NULL,
        encrypted_content TEXT    NOT NULL,
        timestamp         INTEGER NOT NULL,
        is_read           INTEGER NOT NULL DEFAULT 0
      )
    ''');

    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('conversations', {
      'id': 1,
      'name': 'Избранное',
      'created_at': now,
    });
  }

  Future<void> _createSchemaV2(Database db) async {
    await db.execute(
      'CREATE INDEX idx_messages_conversation ON messages (conversation_id)',
    );
    await db.execute(
      'CREATE INDEX idx_messages_timestamp ON messages (timestamp)',
    );
  }

  Future<void> _createSchemaV3(Database db) async {
    await db.execute('''
      CREATE TABLE groups (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        name        TEXT    NOT NULL,
        created_by  TEXT    NOT NULL,
        created_at  INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE group_members (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        group_id    INTEGER NOT NULL,
        nickname    TEXT    NOT NULL,
        public_key  TEXT    NOT NULL,
        joined_at   INTEGER NOT NULL,
        FOREIGN KEY (group_id) REFERENCES groups (id) ON DELETE CASCADE,
        UNIQUE(group_id, nickname)
      )
    ''');

    await db.execute('''
      CREATE TABLE group_messages (
        id                INTEGER PRIMARY KEY AUTOINCREMENT,
        group_id          INTEGER NOT NULL,
        sender_nickname   TEXT    NOT NULL,
        encrypted_content TEXT    NOT NULL,
        timestamp         INTEGER NOT NULL,
        FOREIGN KEY (group_id) REFERENCES groups (id) ON DELETE CASCADE
      )
    ''');

    await db.execute(
      'CREATE INDEX idx_group_messages_group ON group_messages (group_id)',
    );
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _createSchemaV2(db);
    }
    if (oldVersion < 3) {
      await _createSchemaV3(db);
    }
    if (oldVersion < 4 &&
        !(await db.rawQuery('PRAGMA table_info(messages)'))
            .any((c) => c['name'] == 'is_read')) {
      // Older schema snapshots already included this column.
      await db.execute(
        'ALTER TABLE messages ADD COLUMN is_read INTEGER NOT NULL DEFAULT 0',
      );
    }
    if (oldVersion < 5) await _createSchemaV5(db);
    if (oldVersion < 6) await _createSchemaV6(db);
    if (oldVersion < 7 && newVersion >= 7) await _createSchemaV7(db);
    if (oldVersion < 8 && newVersion >= 8) await _createSchemaV8(db);
    if (oldVersion < 9 && newVersion >= 9) await _createSchemaV9(db);
    if (oldVersion < 10 && newVersion >= 10) await _createSchemaV10(db);
    if (oldVersion < 11 && newVersion >= 11) await _createSchemaV11(db);
    if (oldVersion < 12 && newVersion >= 12) await _createSchemaV12(db);
  }

  /// Аддитивная v12: pairing второго устройства. Журнал хранит долговечные
  /// ключи НОВОГО устройства и проверенные артефакты (offer/манифест/
  /// подтверждение) ДО сетевых вызовов — сбой после серверного коммита не
  /// теряет идентичность и не создаёт второй манифест (образец enrollLegacy).
  /// v2_device_keys — приватные ключи подключённого вторичного устройства
  /// (SQLCipher at-rest, тот же класс защиты, что anchor_key rotation).
  /// v2_contacts.history — последняя онлайн-проверенная цепочка каталога
  /// контакта для offline-seal; отсутствие (старые записи) = offline-seal
  /// недоступен до первой онлайн-верификации.
  /// Существующие таблицы, ключи и история не переписываются.
  Future<void> _createSchemaV12(Database db) async {
    final contactCols = await db.rawQuery('PRAGMA table_info(v2_contacts)');
    if (!contactCols.any((c) => c['name'] == 'history')) {
      await db.execute('ALTER TABLE v2_contacts ADD COLUMN history TEXT');
    }
    await db.execute('''
      CREATE TABLE v2_pairing_journal (
        account            TEXT PRIMARY KEY,
        role               TEXT NOT NULL,
        phase              TEXT NOT NULL,
        device_id          TEXT NOT NULL,
        encryption_key     TEXT,
        signing_key        TEXT,
        encryption_private TEXT,
        signing_private    TEXT,
        offer_text         TEXT,
        offer              TEXT,
        manifest           TEXT,
        proofs             TEXT,
        confirmation_text  TEXT,
        confirmation       TEXT,
        root               TEXT,
        genesis            TEXT,
        created_at         INTEGER NOT NULL,
        updated_at         INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE v2_device_keys (
        account            TEXT PRIMARY KEY,
        device_id          TEXT NOT NULL,
        encryption_key     TEXT NOT NULL,
        signing_key        TEXT NOT NULL,
        encryption_private TEXT NOT NULL,
        signing_private    TEXT NOT NULL,
        created_at         INTEGER NOT NULL
      )
    ''');
  }

  /// Аддитивная v11: RSA-rotation (v1 RSA-2048 → v2 RSA-4096).
  /// anchor_key — новый приватный якорь (SQLCipher at-rest), legacy_key —
  /// исходный v1-ключ для расшифровки старой истории/bridged-ciphertext.
  /// rotation в журнале — аттестация старого ключа (без приватных ключей).
  /// Существующие v1-таблицы, ключи и история не переписываются.
  Future<void> _createSchemaV11(Database db) async {
    final accountCols = await db.rawQuery('PRAGMA table_info(v2_accounts)');
    if (!accountCols.any((c) => c['name'] == 'anchor_key')) {
      await db.execute('ALTER TABLE v2_accounts ADD COLUMN anchor_key TEXT');
    }
    if (!accountCols.any((c) => c['name'] == 'legacy_key')) {
      await db.execute('ALTER TABLE v2_accounts ADD COLUMN legacy_key TEXT');
    }
    final journalCols =
        await db.rawQuery('PRAGMA table_info(v2_enrollment_journal)');
    if (!journalCols.any((c) => c['name'] == 'rotation')) {
      await db.execute(
          'ALTER TABLE v2_enrollment_journal ADD COLUMN rotation TEXT');
    }
    if (!journalCols.any((c) => c['name'] == 'anchor_key')) {
      await db.execute(
          'ALTER TABLE v2_enrollment_journal ADD COLUMN anchor_key TEXT');
    }
  }

  /// Аддитивные таблицы device-v2 (Android ↔ Web E2EE). Существующие v1
  /// таблицы, ключи и история не переписываются.
  Future<void> _createSchemaV9(Database db) async {
    await db.execute('''
      CREATE TABLE v2_accounts (
        account     TEXT PRIMARY KEY,
        root        TEXT NOT NULL,
        genesis     TEXT NOT NULL,
        history     TEXT NOT NULL,
        checkpoint  TEXT NOT NULL,
        recovery    TEXT,
        session_id  TEXT NOT NULL,
        created_at  INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE v2_contacts (
        account         TEXT PRIMARY KEY,
        root            TEXT NOT NULL,
        genesis         TEXT NOT NULL,
        checkpoint      TEXT NOT NULL,
        genesis_digest  TEXT NOT NULL,
        confirmed       INTEGER NOT NULL DEFAULT 0,
        updated_at      INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE v2_messages (
        ref         TEXT PRIMARY KEY,
        peer        TEXT NOT NULL,
        direction   TEXT NOT NULL,
        message_id  TEXT NOT NULL,
        created_at  INTEGER NOT NULL,
        payload     TEXT NOT NULL,
        status      TEXT NOT NULL DEFAULT 'received',
        acked       INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE v2_outbox (
        id          TEXT PRIMARY KEY,
        peer        TEXT NOT NULL,
        message     TEXT NOT NULL,
        created_at  INTEGER NOT NULL,
        attempts    INTEGER NOT NULL DEFAULT 0,
        last_error  TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE v2_delivery (
        ref             TEXT NOT NULL,
        device_id       TEXT NOT NULL,
        acknowledged_at INTEGER,
        read_at         INTEGER,
        PRIMARY KEY (ref, device_id)
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_v2_messages_peer ON v2_messages(peer, created_at)');
  }

  /// Аддитивная таблица v10: долговечный журнал legacy-enrollment.
  /// Genesis/manifest и зашифрованный recovery-пакет сохраняются ДО сетевого
  /// вызова, поэтому сбой/убийство процесса после коммита на сервере не
  /// теряет recovery-ключ и не создаёт второй genesis. Приватные ключи не
  /// хранятся здесь: recovery-пакет зашифрован фразой пользователя.
  Future<void> _createSchemaV10(Database db) async {
    await db.execute('''
      CREATE TABLE v2_enrollment_journal (
        account         TEXT PRIMARY KEY,
        root            TEXT NOT NULL,
        genesis         TEXT NOT NULL,
        manifest        TEXT NOT NULL,
        recovery_backup TEXT NOT NULL,
        phase           TEXT NOT NULL DEFAULT 'prepared',
        created_at      INTEGER NOT NULL,
        updated_at      INTEGER NOT NULL
      )
    ''');
  }

  Future<void> _createSchemaV8(Database db) => db.execute(
      'CREATE TABLE avatar_profiles(owner TEXT NOT NULL, server TEXT NOT NULL, username TEXT NOT NULL, body TEXT NOT NULL, updated_at INTEGER NOT NULL, PRIMARY KEY(owner,server,username))');

  Future<Map<String, dynamic>?> readAvatarProfile(
      String owner, String server, String username) async {
    final rows = await (await database).query('avatar_profiles',
        where: 'owner=? AND server=? AND username=?',
        whereArgs: [owner, server, username],
        limit: 1);
    return rows.isEmpty
        ? null
        : jsonDecode(rows.first['body'] as String) as Map<String, dynamic>;
  }

  Future<void> cacheAvatarProfile(String owner, String server, String username,
      Map<String, dynamic> profile) async {
    await (await database).transaction((txn) async {
      await txn.insert(
          'avatar_profiles',
          {
            'owner': owner,
            'server': server,
            'username': username,
            'body': jsonEncode(profile),
            'updated_at': DateTime.now().millisecondsSinceEpoch
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      // Bounded cache, inside the existing SQLCipher database on mobile.
      await txn.rawDelete(
          'DELETE FROM avatar_profiles WHERE owner=? AND server=? AND username NOT IN (SELECT username FROM avatar_profiles WHERE owner=? AND server=? ORDER BY updated_at DESC LIMIT 100)',
          [owner, server, owner, server]);
    });
  }

  Future<void> _createSchemaV7(Database db) => db.execute(
      'CREATE TABLE verified_keys(owner TEXT NOT NULL, peer TEXT NOT NULL, fingerprint TEXT NOT NULL, PRIMARY KEY(owner,peer))');

  Future<bool> checkFingerprint(
      String owner, String peer, String fingerprint, String? legacy) async {
    final db = await database;
    return db.transaction((txn) async {
      if (legacy != null) {
        await txn.insert('verified_keys',
            {'owner': owner, 'peer': peer, 'fingerprint': legacy},
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await txn.rawUpdate(
          "UPDATE verified_keys SET fingerprint='' WHERE owner=? AND peer=? AND fingerprint<>?",
          [owner, peer, fingerprint]);
      return (await txn.query('verified_keys',
              where: 'owner=? AND peer=? AND fingerprint=?',
              whereArgs: [owner, peer, fingerprint]))
          .isNotEmpty;
    });
  }

  Future<void> confirmFingerprint(
      String owner, String peer, String fingerprint) async {
    await (await database).insert('verified_keys',
        {'owner': owner, 'peer': peer, 'fingerprint': fingerprint},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> _createSchemaV5(Database db) async {
    await db.execute('ALTER TABLE messages ADD COLUMN network_id TEXT');
    await db.execute(
        "ALTER TABLE messages ADD COLUMN status TEXT NOT NULL DEFAULT 'sent'");
    await db.execute(
        'CREATE UNIQUE INDEX idx_messages_network_id ON messages(network_id)');
    await db.execute('ALTER TABLE users ADD COLUMN email TEXT');
    await db.execute('ALTER TABLE users ADD COLUMN display_name TEXT');
    await db.execute('ALTER TABLE users ADD COLUMN avatar_url TEXT');
    await db.execute(
        'CREATE TABLE outbox (network_id TEXT PRIMARY KEY, recipient TEXT NOT NULL, payload TEXT NOT NULL)');
  }

  Future<void> _createSchemaV6(Database db) async {
    await db.execute(
        "ALTER TABLE messages ADD COLUMN network_sender TEXT NOT NULL DEFAULT ''");
    await db.execute(
        'ALTER TABLE messages ADD COLUMN is_outgoing INTEGER NOT NULL DEFAULT 0');
    final profiles = await db.query('users', limit: 1);
    final nickname =
        profiles.isEmpty ? '' : profiles.first['nickname'] as String;
    // Preserve v5 history; old incoming identity can be recovered from its chat.
    await db.execute(
        "UPDATE messages SET network_sender = COALESCE((SELECT name FROM conversations WHERE id = messages.conversation_id), 'legacy:' || sender_id)");
    if (nickname.isNotEmpty) {
      await db.update(
          'messages', {'network_sender': nickname, 'is_outgoing': 1},
          where: 'sender_id = ?', whereArgs: [nickname.hashCode.abs()]);
    }
    await db.execute('DROP INDEX idx_messages_network_id');
    await db.execute(
        'CREATE UNIQUE INDEX idx_messages_network_id ON messages(network_sender, network_id)');
  }

  // ── Users ───────────────────────────────────────────────────

  Future<int> saveUserProfile(String nickname, String publicKey,
      {Map<String, dynamic> profile = const {}}) async {
    final db = await database;
    return db.insert(
      'users',
      {
        'nickname': nickname,
        'public_key': publicKey,
        'email': profile['email'],
        'display_name': profile['displayName'],
        'avatar_url': profile['avatarUrl'],
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, dynamic>?> getUserProfile(String nickname) async {
    final db = await database;
    final rows = await db.query(
      'users',
      where: 'nickname = ?',
      whereArgs: [nickname],
      limit: 1,
    );
    return rows.isNotEmpty ? rows.first : null;
  }

  Future<Map<String, dynamic>?> getCurrentUserProfile() async {
    final db = await database;
    final rows = await db.query('users', limit: 1);
    return rows.isNotEmpty ? rows.first : null;
  }

  // MED-04: Parameterized queries — SQL injection safe
  Future<bool> hasUserProfile() async {
    final db = await database;
    // MED-04: No user input - safe
    final result = await db.rawQuery('SELECT COUNT(*) AS cnt FROM users');
    return (result.first['cnt'] as int) > 0;
  }

  // ── Contacts ────────────────────────────────────────────────

  Future<void> saveContact({
    required String nickname,
    required String publicKey,
    String? signature,
  }) async {
    final db = await database;
    await db.insert(
      'contacts',
      {
        'nickname': nickname,
        'public_key': publicKey,
        'signature': signature,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, dynamic>?> getContact(String nickname) async {
    final db = await database;
    final rows = await db.query(
      'contacts',
      where: 'nickname = ?',
      whereArgs: [nickname],
      limit: 1,
    );
    return rows.isNotEmpty ? rows.first : null;
  }

  Future<List<Map<String, dynamic>>> searchContacts(String query) async {
    // MED-04: Escape LIKE special chars
    final escaped = query.replaceAll('%', r'\%').replaceAll('_', '_');
    final db = await database;
    return db.query(
      'contacts',
      where: 'nickname LIKE ? ESCAPE "\\"',
      whereArgs: ['%$escaped%'],
      orderBy: 'created_at DESC',
      limit: 20,
    );
  }

  // ── Conversations ───────────────────────────────────────────

  Future<int> createConversation(String name, {String? publicKey}) async {
    final db = await database;
    return db.transaction((txn) async {
      final existing = await txn.query('conversations',
          where: 'name = ?', whereArgs: [name], limit: 1);
      if (existing.isNotEmpty) return existing.first['id'] as int;
      return txn.insert('conversations', {
        'name': name,
        'public_key': publicKey,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
    });
  }

  Future<List<Map<String, dynamic>>> getConversations() async {
    final db = await database;
    return db.query('conversations', orderBy: 'created_at DESC');
  }

  Future<void> deleteConversation(int id) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.rawDelete(
          'DELETE FROM outbox WHERE network_id IN (SELECT network_id FROM messages WHERE conversation_id = ? AND is_outgoing = 1)',
          [id]);
      await txn
          .delete('messages', where: 'conversation_id = ?', whereArgs: [id]);
      await txn.delete('conversations', where: 'id = ?', whereArgs: [id]);
    });
  }

  // ── Messages ────────────────────────────────────────────────

  /// Inserts a message into the database.
  Future<int> insertMessage({
    required int conversationId,
    required int senderId,
    required String encryptedContent,
    String? networkId,
    String status = 'sent',
    int? timestamp,
    bool outgoing = false,
    String? networkSender,
    String? recipient,
    String? networkPayload,
  }) async {
    final db = await database;
    final sender = networkSender ?? (outgoing ? '@self' : 'legacy:$senderId');
    return db.transaction((txn) async {
      if (networkId != null) {
        final rows = await txn.query('messages',
            where: 'network_id = ? AND network_sender = ?',
            whereArgs: [networkId, sender],
            limit: 1);
        if (rows.isNotEmpty) return rows.first['id'] as int;
      }
      final id = await txn.insert('messages', {
        'conversation_id': conversationId,
        'sender_id': senderId,
        'encrypted_content': encryptedContent,
        'network_id': networkId,
        'network_sender': sender,
        'is_outgoing': outgoing ? 1 : 0,
        'status': status,
        'timestamp': timestamp ?? DateTime.now().millisecondsSinceEpoch,
        'is_read': outgoing ? 1 : 0,
      });
      // The display copy and the recipient-encrypted outbox commit together.
      if (networkPayload != null && recipient != null && networkId != null) {
        await txn.insert('outbox', {
          'network_id': networkId,
          'recipient': recipient,
          'payload': networkPayload
        });
      }
      return id;
    });
  }

  Future<List<Map<String, dynamic>>> getOutbox() async =>
      (await database).query('outbox');

  Future<void> updateMessageStatus(String networkId, String status) async {
    const ranks = {'queued': 0, 'sent': 1, 'delivered': 2, 'read': 3};
    if (!ranks.containsKey(status)) return;
    final db = await database;
    await db.transaction((txn) async {
      final rows = await txn.query('messages',
          where: 'network_id = ? AND is_outgoing = 1', whereArgs: [networkId]);
      if (rows.isEmpty) return;
      final old = rows.first['status'] as String;
      if ((ranks[status] ?? 0) > (ranks[old] ?? 0)) {
        await txn.update('messages', {'status': status},
            where: 'network_id = ? AND is_outgoing = 1',
            whereArgs: [networkId]);
      }
      if (status != 'queued') {
        await txn
            .delete('outbox', where: 'network_id = ?', whereArgs: [networkId]);
      }
    });
  }

  /// Only the displayed and server-confirmed incoming IDs become read.
  Future<void> markMessagesAsRead(int conversationId,
      {required List<int> messageIds}) async {
    if (messageIds.isEmpty) return;
    final db = await database;
    final placeholders = List.filled(messageIds.length, '?').join(',');
    await db.update('messages', {'is_read': 1},
        where:
            'conversation_id = ? AND is_outgoing = 0 AND id IN ($placeholders)',
        whereArgs: [conversationId, ...messageIds]);
  }

  Future<bool> isPendingMessage(String networkId) async =>
      (await (await database).query('outbox',
              where: 'network_id = ?', whereArgs: [networkId], limit: 1))
          .isNotEmpty;

  Future<void> deleteIncomingMessage(String sender, String networkId) async {
    await (await database).delete('messages',
        where: 'network_sender = ? AND network_id = ? AND is_outgoing = 0',
        whereArgs: [sender, networkId]);
  }

  /// Returns count of unread messages in a conversation.
  // MED-04: Parameterized queries — SQL injection safe
  Future<int> getUnreadCount(int conversationId) async {
    final db = await database;
    // MED-04: Using parameterized query with whereArgs - safe
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS cnt FROM messages WHERE conversation_id = ? AND is_read = 0',
      [conversationId],
    );
    return result.first['cnt'] as int;
  }

  /// Returns messages with pagination support.
  ///
  /// [conversationId] - ID беседы
  /// [limit] - количество сообщений для загрузки (по умолчанию 20)
  /// [offset] - смещение от конца истории (0 = последние сообщения)
  Future<List<Map<String, dynamic>>> getMessages(
    int conversationId, {
    int limit = 20,
    int offset = 0,
  }) async {
    final db = await database;
    // Загружаем сообщения в обратном порядке (сначала новые), затем реверсируем
    final rawMessages = await db.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'timestamp DESC, id DESC',
      limit: limit,
      offset: offset,
    );
    // Реверсируем чтобы вернуть в правильном порядке (старые -> новые)
    return rawMessages.reversed.toList();
  }

  /// Returns total message count for a conversation (for pagination calculation).
  Future<int> getMessageCount(int conversationId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS cnt FROM messages WHERE conversation_id = ?',
      [conversationId],
    );
    return result.first['cnt'] as int;
  }

  /// Checks if there are more messages to load.
  Future<bool> hasMoreMessages(int conversationId, int loadedCount) async {
    final totalCount = await getMessageCount(conversationId);
    return loadedCount < totalCount;
  }

  /// Returns the last message for a conversation.
  Future<Map<String, dynamic>?> getLastMessage(int conversationId) async {
    final db = await database;
    final result = await db.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'timestamp DESC, id DESC',
      limit: 1,
    );
    return result.isEmpty ? null : result.first;
  }

  // ── Cleanup ─────────────────────────────────────────────────

  Future<void> close() async {
    final db = _db;
    for (final future in _chatDatabases.values.toList()) {
      final scoped = await future;
      if (!identical(scoped, db)) await scoped.close();
    }
    _chatDatabases.clear();
    if (db != null) {
      await db.close();
    }
    _db = null;
    _opening = null;
  }

  // ── Groups ──────────────────────────────────────────────────

  Future<int> createGroup({
    required String name,
    required String createdBy,
    required List<Map<String, String>> members, // [{nickname, publicKey}]
  }) async {
    final db = await database;
    final groupId = await db.insert('groups', {
      'name': name,
      'created_by': createdBy,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });

    // Add members
    for (final member in members) {
      await db.insert('group_members', {
        'group_id': groupId,
        'nickname': member['nickname'],
        'public_key': member['publicKey'],
        'joined_at': DateTime.now().millisecondsSinceEpoch,
      });
    }

    return groupId;
  }

  Future<List<Map<String, dynamic>>> getGroups() async {
    final db = await database;
    return db.query('groups', orderBy: 'created_at DESC');
  }

  Future<List<Map<String, dynamic>>> getGroupMembers(int groupId) async {
    final db = await database;
    return db.query(
      'group_members',
      where: 'group_id = ?',
      whereArgs: [groupId],
    );
  }

  Future<void> addGroupMember({
    required int groupId,
    required String nickname,
    required String publicKey,
  }) async {
    final db = await database;
    await db.insert('group_members', {
      'group_id': groupId,
      'nickname': nickname,
      'public_key': publicKey,
      'joined_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> deleteGroup(int groupId) async {
    final db = await database;
    await db.delete(
      'group_messages',
      where: 'group_id = ?',
      whereArgs: [groupId],
    );
    await db.delete(
      'group_members',
      where: 'group_id = ?',
      whereArgs: [groupId],
    );
    await db.delete('groups', where: 'id = ?', whereArgs: [groupId]);
  }

  Future<int> insertGroupMessage({
    required int groupId,
    required String senderNickname,
    required String encryptedContent,
  }) async {
    final db = await database;
    return db.insert('group_messages', {
      'group_id': groupId,
      'sender_nickname': senderNickname,
      'encrypted_content': encryptedContent,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<List<Map<String, dynamic>>> getGroupMessages(int groupId) async {
    final db = await database;
    return db.query(
      'group_messages',
      where: 'group_id = ?',
      whereArgs: [groupId],
      orderBy: 'timestamp ASC',
    );
  }

  /// Deletes the entire database and all its data.
  ///
  /// This should be called during logout to remove all local message history
  /// and cryptographic material from the device.
  Future<void> deleteDatabase() async {
    await nuke();
  }

  Future<void> nuke() async {
    await close();

    String dir;
    if (_isMobile) {
      dir = await sqlcipher.getDatabasesPath();
      await sqlcipher.deleteDatabase(p.join(dir, _dbName));
    } else {
      dir = await sqflite_ffi.getDatabasesPath();
      await sqflite_ffi.deleteDatabase(p.join(dir, _dbName));
    }

    if (_isMobile) {
      await _secureStorage.delete(key: _dbKeyStorageKey);
    }
    debugPrint('[DatabaseService] Database destroyed');
  }
}

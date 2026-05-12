import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// Mobile: encrypted SQLite via SQLCipher
import 'package:sqflite_sqlcipher/sqflite.dart' as sqlcipher;
// Desktop: standard SQLite via FFI
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as sqflite_ffi;
// Common types (Database, ConflictAlgorithm)
import 'package:sqflite_common/sqflite.dart' show Database, ConflictAlgorithm;
import 'package:pointycastle/export.dart' as pc;

/// Returns true when running on a mobile platform that supports SQLCipher.
bool get _isMobile => Platform.isAndroid || Platform.isIOS;

/// Unified database service.
///
/// - **All platforms (Android/iOS/Desktop):** Uses SQLCipher with a key stored in
///   flutter_secure_storage.
/// - **Desktop (Windows/Mac/Linux):** Uses sqflite_common_ffi with SQLCipher support.
/// - **MED-03:** SQLCipher now enabled for all platforms via sqflite_sqlcipher
class DatabaseService {
  static const String _dbName = 'shade.db';
  static const int _dbVersion = 4;
  static const String _dbKeyStorageKey = 'sqlcipher_db_key';

  final FlutterSecureStorage _secureStorage;

  /// Holds the database handle.
  Database? _db;

  bool _ffiInitialised = false;

  DatabaseService({FlutterSecureStorage? secureStorage})
      : _secureStorage = secureStorage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  // ── Lifecycle ───────────────────────────────────────────────

  Future<Database> get database async {
    _db ??= await _open();
    return _db!;
  }

  Future<Database> _open() async {
    String dir;

    if (_isMobile) {
      // ── Mobile: use sqflite_sqlcipher path ──────────────────
      dir = await sqlcipher.getDatabasesPath();
    } else {
      // ── Desktop: init FFI first, then get path ─────────────
      await _initFfi();
      dir = await sqflite_ffi.getDatabasesPath();
    }

    final filePath = p.join(dir, _dbName);

    if (_isMobile) {
      final key = await _getOrCreateKey();
      final db = await sqlcipher.openDatabase(
        filePath,
        version: _dbVersion,
        password: key,
        onConfigure: (db) async {},
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      );
      await _verifyDatabaseIntegrity(db);
      return db;
    } else {
      try {
        final key = await _getOrCreateKey();
        final db = await sqlcipher.openDatabase(
          filePath,
          version: _dbVersion,
          password: key,
          onConfigure: (db) async {},
          onCreate: _onCreate,
          onUpgrade: _onUpgrade,
        );
        await _verifyDatabaseIntegrity(db);
        return db;
      } catch (e) {
        debugPrint('[DatabaseService] SQLCipher failed: $e');
        // HIGH-05: No unencrypted fallback on desktop
        throw Exception('FATAL: SQLCipher required on desktop. Database unavailable. $e');
      }
    }
  }

  // MED-04: Parameterized queries — SQL injection safe
  Future<void> _verifyDatabaseIntegrity(Database db) async {
    try {
      // MED-04: No user input in this query - safe
      final result = await db.rawQuery('SELECT count(*) as cnt FROM sqlite_master');
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

  /// One-time initialisation of the FFI database factory (desktop only).
  Future<void> _initFfi() async {
    if (_ffiInitialised) return;
    sqflite_ffi.sqfliteFfiInit();
    sqflite_ffi.databaseFactory = sqflite_ffi.databaseFactoryFfi;
    _ffiInitialised = true;
    debugPrint('[DatabaseService] sqflite FFI initialised (desktop mode)');
  }

  // ── Key management (mobile only) ────────────────────────────

  /// Generates or retrieves the SQLCipher database encryption key.
  Future<String> _getOrCreateKey() async {
    const deviceIdKey = 'shade_device_id';
    
    try {
      final existing = await _secureStorage.read(key: _dbKeyStorageKey);
      if (existing != null && existing.isNotEmpty) return existing;
    } catch (e) {
      debugPrint('[DatabaseService] secure storage read failed: $e');
    }

// CRIT-01: Direct Random.secure().nextBytes(32)
     final random = math.Random.secure();
     final masterKey = random.nextBytes(32);

    // Get or create device_id for PBKDF2 salt
    String? deviceId;
    try {
      deviceId = await _secureStorage.read(key: deviceIdKey);
      if (deviceId == null || deviceId.isEmpty) {
        deviceId = base64Url.encode(Uint8List(16).map((_) => random.nextInt(256)).toList());
        await _secureStorage.write(key: deviceIdKey, value: deviceId);
      }
    } catch (e) {
      deviceId = base64Url.encode(Uint8List(16).map((_) => random.nextInt(256)).toList());
    }

    // MED-01: PBKDF2 (now 2.1M+ for all platforms per HIGH-08)
    final salt = utf8.encode(deviceId);
    const iterations = 2100000; // HIGH-08: PBKDF2 2.1M+ iterations
    final pbkdf2 = pc.PBKDF2KeyDerivator(pc.HMac(pc.SHA256Digest(), 64));
    pbkdf2.init(pc.Pbkdf2Parameters(Uint8List.fromList(salt), iterations, 32));
    final derivedKey = pbkdf2.process(masterKey);
    final key = base64Url.encode(derivedKey);

    await _secureStorage.write(key: _dbKeyStorageKey, value: key);
    debugPrint('[DatabaseService] Generated new DB encryption key (PBKDF2 with device_id salt)');
    return key;
  }

  // ── Schema creation ─────────────────────────────────────────

  Future<void> _onCreate(Database db, int version) async {
    await _createSchemaV1(db);
    if (version >= 2) {
      await _createSchemaV2(db);
    }
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
    if (oldVersion < 4) {
      // Add is_read column to messages
      await db.execute(
        'ALTER TABLE messages ADD COLUMN is_read INTEGER NOT NULL DEFAULT 0',
      );
    }
  }

  // ── Users ───────────────────────────────────────────────────

  Future<int> saveUserProfile(String nickname, String publicKey) async {
    final db = await database;
    return db.insert(
      'users',
      {
        'nickname': nickname,
        'public_key': publicKey,
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
    final escaped = query.replaceAll('%', r'\%').replaceAll('_', '\_');
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
    return db.insert('conversations', {
      'name': name,
      'public_key': publicKey,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<List<Map<String, dynamic>>> getConversations() async {
    final db = await database;
    return db.query('conversations', orderBy: 'created_at DESC');
  }

  Future<void> deleteConversation(int id) async {
    final db = await database;
    await db.delete('messages', where: 'conversation_id = ?', whereArgs: [id]);
    await db.delete('conversations', where: 'id = ?', whereArgs: [id]);
  }

  // ── Messages ────────────────────────────────────────────────

  /// Inserts a message into the database.
  Future<int> insertMessage({
    required int conversationId,
    required int senderId,
    required String encryptedContent,
  }) async {
    final db = await database;
    return db.insert('messages', {
      'conversation_id': conversationId,
      'sender_id': senderId,
      'encrypted_content': encryptedContent,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'is_read': 0,
    });
  }

  /// Marks all messages in a conversation as read (for received messages).
  Future<void> markMessagesAsRead(int conversationId) async {
    final db = await database;
    await db.update(
      'messages',
      {'is_read': 1},
      where: 'conversation_id = ? AND is_read = 0',
      whereArgs: [conversationId],
    );
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
      orderBy: 'timestamp DESC',
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

  // ── Cleanup ─────────────────────────────────────────────────

  Future<void> close() async {
    final db = _db;
    if (db != null) {
      await db.close();
    }
    _db = null;
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

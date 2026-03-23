import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// Mobile: encrypted SQLite via SQLCipher
import 'package:sqflite_sqlcipher/sqflite.dart' as sqlcipher;
// Desktop: standard SQLite via FFI
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as sqflite_ffi;
// Common types (Database, ConflictAlgorithm)
import 'package:sqflite_common/sqflite.dart' show Database, ConflictAlgorithm;

/// Returns true when running on a mobile platform that supports SQLCipher.
bool get _isMobile => Platform.isAndroid || Platform.isIOS;

/// Unified database service.
///
/// - **Mobile (Android/iOS):** Uses SQLCipher with a key stored in
///   flutter_secure_storage.
/// - **Desktop (Windows/Mac/Linux):** Uses sqflite_common_ffi (no encryption,
///   but fully functional for development and testing).
class DatabaseService {
  static const String _dbName = 'shade.db';
  static const int _dbVersion = 2;
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
      // ── Mobile: SQLCipher ────────────────────────────────────
      final key = await _getOrCreateKey();
      return sqlcipher.openDatabase(
        filePath,
        version: _dbVersion,
        password: key,
        onConfigure: (db) async {
          // Foreign keys managed in application code
        },
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      );
    } else {
      // ── Desktop: sqflite_common_ffi ──────────────────────────
      return sqflite_ffi.openDatabase(
        filePath,
        version: _dbVersion,
        onConfigure: (db) async {
          // Foreign keys managed in application code
        },
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
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

  Future<String> _getOrCreateKey() async {
    try {
      final existing = await _secureStorage.read(key: _dbKeyStorageKey);
      if (existing != null && existing.isNotEmpty) return existing;
    } catch (e) {
      debugPrint('[DatabaseService] secure storage read failed: $e');
    }

    final bytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    final key = base64Url.encode(bytes);

    await _secureStorage.write(key: _dbKeyStorageKey, value: key);
    debugPrint('[DatabaseService] Generated new DB encryption key');
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
        timestamp         INTEGER NOT NULL
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

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await _createSchemaV2(db);
    }
  }

  // ── Users ───────────────────────────────────────────────────

  Future<void> saveUserProfile(String nickname, String publicKey) async {
    final db = await database;
    await db.insert(
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

  Future<bool> hasUserProfile() async {
    final db = await database;
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
    final db = await database;
    return db.query(
      'contacts',
      where: 'nickname LIKE ?',
      whereArgs: ['%$query%'],
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

  /// Inserts a message. Skips if duplicate exists within 5 seconds.
  Future<int> insertMessage({
    required int conversationId,
    required int senderId,
    required String encryptedContent,
  }) async {
    final db = await database;

    // Check for duplicates within 5 seconds
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = await db.query(
      'messages',
      where:
          'conversation_id = ? AND sender_id = ? AND encrypted_content = ? AND timestamp > ?',
      whereArgs: [conversationId, senderId, encryptedContent, now - 5000],
      limit: 1,
    );

    if (existing.isNotEmpty) {
      debugPrint('[DatabaseService] Duplicate message skipped');
      return existing.first['id'] as int;
    }

    return db.insert('messages', {
      'conversation_id': conversationId,
      'sender_id': senderId,
      'encrypted_content': encryptedContent,
      'timestamp': now,
    });
  }

  Future<List<Map<String, dynamic>>> getMessages(
    int conversationId, {
    int limit = 500,
    int offset = 0,
  }) async {
    final db = await database;
    return db.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'timestamp ASC',
      limit: limit,
      offset: offset,
    );
  }

  Future<Map<String, dynamic>?> getLastMessage(int conversationId) async {
    final db = await database;
    final rows = await db.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'timestamp DESC',
      limit: 1,
    );
    return rows.isNotEmpty ? rows.first : null;
  }

  Future<int> getMessageCount(int conversationId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS cnt FROM messages WHERE conversation_id = ?',
      [conversationId],
    );
    return result.first['cnt'] as int;
  }

  // ── Cleanup ─────────────────────────────────────────────────

  Future<void> close() async {
    final db = _db;
    if (db != null) {
      await db.close();
    }
    _db = null;
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

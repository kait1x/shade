import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Encrypted SQLite database service using SQLCipher.
///
/// The encryption key is a 32-byte random value generated once on first open
/// and persisted in [FlutterSecureStorage] (Android Keystore / iOS Keychain).
/// The key never leaves the device's secure enclave.
///
/// Schema:
///   users         — local identity profile
///   conversations — chat threads
///   messages      — encrypted message payloads
class DatabaseService {
  static const String _dbName = 'shade_encrypted.db';
  static const int _dbVersion = 2;
  static const String _dbKeyStorageKey = 'sqlcipher_db_key';

  final FlutterSecureStorage _secureStorage;

  Database? _db;

  DatabaseService({FlutterSecureStorage? secureStorage})
      : _secureStorage =
            secureStorage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  // ── Lifecycle ───────────────────────────────────────────────

  /// Returns the open database, initialising it on first access.
  Future<Database> get database async {
    _db ??= await _open();
    return _db!;
  }

  /// Opens (or creates) the SQLCipher-encrypted database.
  Future<Database> _open() async {
    final dir = await getDatabasesPath();
    final filePath = p.join(dir, _dbName);
    final key = await _getOrCreateKey();

    return openDatabase(
      filePath,
      version: _dbVersion,
      password: key,
      onConfigure: (db) async {
        // Enforce foreign keys
        await db.rawQuery('PRAGMA foreign_keys = ON');
      },
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  /// Retrieves the DB key from secure storage, generating a new one on first run.
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
        FOREIGN KEY (conversation_id) REFERENCES conversations (id) ON DELETE CASCADE,
        FOREIGN KEY (sender_id)       REFERENCES users (id)
      )
    ''');

    // Seed default self-chat conversation so the FK never fails.
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

  // ── Schema migration ────────────────────────────────────────

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

  // ── Conversations ───────────────────────────────────────────

  Future<int> createConversation(String name) async {
    final db = await database;
    return db.insert('conversations', {
      'name': name,
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
    if (db != null && db.isOpen) {
      await db.close();
    }
    _db = null;
  }

  /// Wipes the database and removes the encryption key.
  /// Use with caution — this is irreversible.
  Future<void> nuke() async {
    await close();
    final dir = await getDatabasesPath();
    await deleteDatabase(p.join(dir, _dbName));
    await _secureStorage.delete(key: _dbKeyStorageKey);
    debugPrint('[DatabaseService] Database destroyed');
  }
}

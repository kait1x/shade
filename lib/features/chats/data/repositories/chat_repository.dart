import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:shade/features/auth/data/repositories/auth_notifier.dart';
import 'package:shade/core/database/database_service.dart';

/// Domain model for a conversation.
class Conversation {
  final int id;
  final String name;
  final DateTime createdAt;
  final Message? lastMessage;

  const Conversation({
    required this.id,
    required this.name,
    required this.createdAt,
    this.lastMessage,
  });

  factory Conversation.fromRow(
    Map<String, dynamic> row, {
    Message? lastMessage,
  }) {
    return Conversation(
      id: row['id'] as int,
      name: row['name'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      lastMessage: lastMessage,
    );
  }
}

/// Domain model for a message.
class Message {
  final int id;
  final int conversationId;
  final int senderId;
  final String encryptedContent;
  final DateTime timestamp;

  const Message({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.encryptedContent,
    required this.timestamp,
  });

  factory Message.fromRow(Map<String, dynamic> row) {
    return Message(
      id: row['id'] as int,
      conversationId: row['conversation_id'] as int,
      senderId: row['sender_id'] as int,
      encryptedContent: row['encrypted_content'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(row['timestamp'] as int),
    );
  }
}

/// Repository for conversation and message persistence.
///
/// Delegates all raw SQL to [DatabaseService].
/// Message content is stored encrypted — decryption happens in the
/// presentation layer.
class ChatRepository {
  final DatabaseService _db;

  const ChatRepository(this._db);

  // ── Conversations ───────────────────────────────────────────

  Future<int> createConversation(String name) =>
      _db.createConversation(name);

  /// Ensures a conversation with [id] exists. Creates it if missing.
  Future<void> ensureConversation(int id, String name) async {
    final db = await _db.database;
    final rows = await db.query(
      'conversations',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) {
      try {
        await db.insert('conversations', {
          'id': id,
          'name': name,
          'created_at': DateTime.now().millisecondsSinceEpoch,
        });
      } catch (_) {
        // If explicit ID insert fails (e.g. autoincrement conflict),
        // create without specifying ID and update the caller's reference.
        await db.insert('conversations', {
          'name': name,
          'created_at': DateTime.now().millisecondsSinceEpoch,
        });
      }
    }
  }

  Future<List<Conversation>> getConversations() async {
    final rows = await _db.getConversations();
    return Future.wait(
      rows.map((row) async {
        final last = await _getLastMessage(row['id'] as int);
        return Conversation.fromRow(row, lastMessage: last);
      }),
    );
  }

  Future<void> deleteConversation(int id) => _db.deleteConversation(id);

  // ── Messages ────────────────────────────────────────────────

  /// Persists a message. Auto-creates the conversation if it's missing.
  Future<int> sendMessage({
    required int conversationId,
    required int senderId,
    required String encryptedContent,
    String conversationName = 'Чат',
  }) async {
    await ensureConversation(conversationId, conversationName);
    return _db.insertMessage(
      conversationId: conversationId,
      senderId: senderId,
      encryptedContent: encryptedContent,
    );
  }

  Future<List<Message>> getMessages(int conversationId) async {
    final rows = await _db.getMessages(conversationId);
    return rows.map(Message.fromRow).toList();
  }

  Future<int> getMessageCount(int conversationId) =>
      _db.getMessageCount(conversationId);

  // ── Helpers ─────────────────────────────────────────────────

  Future<Message?> _getLastMessage(int conversationId) async {
    final row = await _db.getLastMessage(conversationId);
    return row != null ? Message.fromRow(row) : null;
  }
}

/// Provider for [ChatRepository].
final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  return ChatRepository(ref.watch(databaseServiceProvider));
});

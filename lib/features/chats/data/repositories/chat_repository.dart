import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:shade/features/auth/data/repositories/auth_notifier.dart';
import 'package:shade/core/database/database_service.dart';
import 'package:shade/core/services/crypto_service.dart';

/// Domain model for a conversation.
class Conversation {
  final int id;
  final String name;
  final String? publicKey;
  final DateTime createdAt;
  final Message? lastMessage;

  const Conversation({
    required this.id,
    required this.name,
    this.publicKey,
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
      publicKey: row['public_key'] as String?,
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

/// A decrypted message ready for display.
class DecryptedMessage {
  final int id;
  final String text;
  final DateTime timestamp;
  final bool isMine;
  final bool decryptSuccess;
  final bool isImage;
  final Uint8List? imageData;

  const DecryptedMessage({
    required this.id,
    required this.text,
    required this.timestamp,
    required this.isMine,
    this.decryptSuccess = true,
    this.isImage = false,
    this.imageData,
  });
}

/// Repository for conversation and message persistence.
///
/// Delegates all raw SQL to [DatabaseService].
/// Message content is stored encrypted — decryption happens in the
/// presentation layer.
class ChatRepository {
  final DatabaseService _db;
  final CryptoService _crypto;

  const ChatRepository(this._db, this._crypto);

  // ── Conversations ───────────────────────────────────────────

  Future<int> createConversation(String name, {String? publicKey}) =>
      _db.createConversation(name, publicKey: publicKey);

  /// Ensures a conversation with [id] exists. Creates it if missing.
  Future<void> ensureConversation(int id, String name,
      {String? publicKey}) async {
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
          'public_key': publicKey,
          'created_at': DateTime.now().millisecondsSinceEpoch,
        });
      } catch (_) {
        await db.insert('conversations', {
          'name': name,
          'public_key': publicKey,
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
    String? publicKey,
  }) async {
    await ensureConversation(conversationId, conversationName,
        publicKey: publicKey);
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

  // ── Decryption ──────────────────────────────────────────────

  /// Returns conversations with last message preview decrypted.
  Future<List<Conversation>> getDecryptedConversations() async {
    final rows = await _db.getConversations();
    final result = <Conversation>[];

    for (final row in rows) {
      Message? preview;
      final last = await _getLastMessage(row['id'] as int);
      if (last != null) {
        try {
          final plain = await _crypto.decryptMessage(last.encryptedContent);
          preview = Message(
            id: last.id,
            conversationId: last.conversationId,
            senderId: last.senderId,
            encryptedContent: plain,
            timestamp: last.timestamp,
          );
        } catch (e) {
          debugPrint('[ChatRepository] decrypt preview error');
          preview = last;
        }
      }
      result.add(Conversation.fromRow(row, lastMessage: preview));
    }
    return result;
  }

  /// Decrypts a list of messages. Returns plain text with metadata.
  Future<List<DecryptedMessage>> decryptMessages(
    List<Message> messages, {
    required int mySenderId,
  }) async {
    final result = <DecryptedMessage>[];
    for (final msg in messages) {
      try {
        final plain = await _crypto.decryptMessage(msg.encryptedContent);

        // Detect image messages: "IMG:<base64>"
        if (plain.startsWith('IMG:')) {
          final b64 = plain.substring(4);
          result.add(DecryptedMessage(
            id: msg.id,
            text: '',
            timestamp: msg.timestamp,
            isMine: msg.senderId == mySenderId,
            decryptSuccess: true,
            isImage: true,
            imageData: base64Decode(b64),
          ));
        } else {
          result.add(DecryptedMessage(
            id: msg.id,
            text: plain,
            timestamp: msg.timestamp,
            isMine: msg.senderId == mySenderId,
            decryptSuccess: true,
          ));
        }
      } catch (e) {
        debugPrint('[ChatRepository] decrypt error');
        result.add(DecryptedMessage(
          id: msg.id,
          text: '[Не удалось расшифровать]',
          timestamp: msg.timestamp,
          isMine: msg.senderId == mySenderId,
          decryptSuccess: false,
        ));
      }
    }
    return result;
  }
}

/// Provider for [ChatRepository].
final chatRepositoryProvider = Provider<ChatRepository>((ref) {
  return ChatRepository(
    ref.watch(databaseServiceProvider),
    ref.watch(cryptoServiceProvider),
  );
});

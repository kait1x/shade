import 'dart:convert';

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
  final int unreadCount;

  const Conversation({
    required this.id,
    required this.name,
    this.publicKey,
    required this.createdAt,
    this.lastMessage,
    this.unreadCount = 0,
  });

  factory Conversation.fromRow(
    Map<String, dynamic> row, {
    Message? lastMessage,
    int unreadCount = 0,
  }) {
    return Conversation(
      id: row['id'] as int,
      name: row['name'] as String,
      publicKey: row['public_key'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      lastMessage: lastMessage,
      unreadCount: unreadCount,
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
  final String? networkId;
  final String status;
  final bool isRead;
  final bool? isOutgoing;

  const Message({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.encryptedContent,
    required this.timestamp,
    this.networkId,
    this.status = 'sent',
    this.isRead = false,
    this.isOutgoing,
  });

  factory Message.fromRow(Map<String, dynamic> row) {
    return Message(
      isRead: row['is_read'] == 1,
      isOutgoing: row['is_outgoing'] == 1,
      networkId: row['network_id'] as String?,
      status: row['status'] as String? ?? 'sent',
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
  final String? networkId;
  final String status;
  final int id;
  final String text;
  final DateTime timestamp;
  final bool isMine;
  final bool decryptSuccess;
  final bool isImage;
  final Uint8List? imageData;
  final String? replyText;
  final String? replySender;

  const DecryptedMessage({
    this.networkId,
    this.status = 'sent',
    required this.id,
    required this.text,
    required this.timestamp,
    required this.isMine,
    this.decryptSuccess = true,
    this.isImage = false,
    this.imageData,
    this.replyText,
    this.replySender,
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
    String? networkId,
    String? networkSender,
    String status = 'sent',
    String? networkPayload,
    String? recipient,
  }) async {
    await ensureConversation(conversationId, conversationName,
        publicKey: publicKey);
    return _db.insertMessage(
      conversationId: conversationId,
      senderId: senderId,
      encryptedContent: encryptedContent,
      networkId: networkId,
      networkSender: networkSender,
      status: status,
      outgoing: true,
      networkPayload: networkPayload,
      recipient: recipient,
    );
  }

  Future<List<Message>> getMessages(int conversationId,
      {int limit = 20, int offset = 0}) async {
    final rows =
        await _db.getMessages(conversationId, limit: limit, offset: offset);
    return rows.map(Message.fromRow).toList();
  }

  /// Deletes a message by ID.
  Future<void> deleteMessage(int msgId) async {
    final db = await _db.database;
    await db.transaction((txn) async {
      final rows =
          await txn.query('messages', where: 'id = ?', whereArgs: [msgId]);
      if (rows.isNotEmpty &&
          rows.first['network_id'] != null &&
          rows.first['is_outgoing'] == 1) {
        await txn.delete('outbox',
            where: 'network_id = ?', whereArgs: [rows.first['network_id']]);
      }
      await txn.delete('messages', where: 'id = ?', whereArgs: [msgId]);
    });
  }

  Future<void> markRead(int conversationId, List<int> messageIds) =>
      _db.markMessagesAsRead(conversationId, messageIds: messageIds);

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
    final database = await _db.database;
    final unreadRows = await database
        .rawQuery('SELECT conversation_id, COUNT(*) AS count FROM messages '
            'WHERE is_read = 0 AND is_outgoing = 0 GROUP BY conversation_id');
    final unread = {
      for (final row in unreadRows)
        row['conversation_id'] as int: row['count'] as int
    };
    final result = <Conversation>[];

    for (final row in rows) {
      Message? preview;
      final last = await _getLastMessage(row['id'] as int);
      if (last != null) {
        try {
          final content = await _crypto.decryptMessage(last.encryptedContent);
          var plain = content.startsWith('IMG:') ? '📷 Фото' : content;
          try {
            final decoded = jsonDecode(content);
            if (decoded is Map && decoded['t'] is String) {
              plain = decoded['t'] as String;
            }
          } catch (_) {}
          preview = Message(
            id: last.id,
            conversationId: last.conversationId,
            senderId: last.senderId,
            encryptedContent: plain,
            timestamp: last.timestamp,
            networkId: last.networkId,
            status: last.status,
            isRead: last.isRead,
            isOutgoing: last.isOutgoing,
          );
        } catch (e) {
          debugPrint('[ChatRepository] decrypt preview error');
          preview = Message(
              id: last.id,
              conversationId: last.conversationId,
              senderId: last.senderId,
              encryptedContent: 'Не удалось расшифровать',
              timestamp: last.timestamp,
              status: last.status,
              isRead: last.isRead,
              isOutgoing: last.isOutgoing);
        }
      }
      result.add(Conversation.fromRow(row,
          lastMessage: preview, unreadCount: unread[row['id']] ?? 0));
    }
    result.sort((a, b) => (b.lastMessage?.timestamp ?? b.createdAt)
        .compareTo(a.lastMessage?.timestamp ?? a.createdAt));
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
            networkId: msg.networkId,
            status: msg.status,
            text: '',
            timestamp: msg.timestamp,
            isMine: msg.isOutgoing ?? (msg.senderId == mySenderId),
            decryptSuccess: true,
            isImage: true,
            imageData: base64Decode(b64),
          ));
        } else {
          // Try to parse JSON (for reply format)
          String text = plain;
          String? replyText;
          String? replySender;

          try {
            final json = jsonDecode(plain);
            if (json is Map && json.containsKey('t')) {
              text = json['t'] as String;
              if (json.containsKey('r')) {
                final r = json['r'] as Map;
                replyText = r['t'] as String?;
                replySender = r['s'] as String?;
              }
            }
          } catch (_) {
            // Not JSON — plain text message
          }

          result.add(DecryptedMessage(
            id: msg.id,
            networkId: msg.networkId,
            status: msg.status,
            text: text,
            timestamp: msg.timestamp,
            isMine: msg.isOutgoing ?? (msg.senderId == mySenderId),
            decryptSuccess: true,
            replyText: replyText,
            replySender: replySender,
          ));
        }
      } catch (e) {
        debugPrint('[ChatRepository] decrypt error');
        result.add(DecryptedMessage(
          id: msg.id,
          networkId: msg.networkId,
          status: msg.status,
          text: '[Не удалось расшифровать]',
          timestamp: msg.timestamp,
          isMine: msg.isOutgoing ?? (msg.senderId == mySenderId),
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

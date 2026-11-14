import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shade/core/database/database_service.dart';

// Regression expectations for the defects reproduced in the audit.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test('v5 upgrade preserves outgoing history, ciphertext and pending payload',
      () async {
    final folder = await Directory.systemTemp.createTemp('shade-v5-upgrade-');
    final path = '${folder.path}/history.db';
    var service = await DatabaseService.openForTest(databaseFactoryFfi, path,
        schemaVersion: 5);
    await service.saveUserProfile('alice', 'fixture-public-key');
    final chat =
        await service.createConversation('bob', publicKey: 'fixture-peer-key');
    final raw = await service.database;
    await raw.insert('messages', {
      'conversation_id': chat,
      'sender_id': 'alice'.hashCode.abs(),
      'encrypted_content': 'preserved-ciphertext',
      'timestamp': 100,
      'is_read': 1,
      'network_id': 'old-queued-id',
      'status': 'queued'
    });
    await raw.insert('outbox', {
      'network_id': 'old-queued-id',
      'recipient': 'bob',
      'payload': 'preserved-network-payload'
    });
    await service.close();
    service = await DatabaseService.openForTest(databaseFactoryFfi, path);
    final message = (await service.getMessages(chat)).single;
    expect(message['network_sender'], 'alice');
    expect(message['is_outgoing'], 1);
    expect(message['encrypted_content'], 'preserved-ciphertext');
    expect((await service.getOutbox()).single['payload'],
        'preserved-network-payload');
    await service.close();
  });
  test(
      'incoming ID collision cannot alter an outgoing status or delete another sender',
      () async {
    final db = await DatabaseService.openForTest(
        databaseFactoryFfi, inMemoryDatabasePath);
    await db.insertMessage(
        conversationId: 1,
        senderId: 1,
        networkSender: 'alice',
        outgoing: true,
        encryptedContent: 'mine',
        networkId: 'shared-id',
        status: 'queued',
        recipient: 'bob',
        networkPayload: 'ciphertext');
    await db.insertMessage(
        conversationId: 1,
        senderId: 2,
        networkSender: 'bob',
        encryptedContent: 'theirs',
        networkId: 'shared-id');
    await db.updateMessageStatus('shared-id', 'read');
    final incoming = (await db.getMessages(1))
        .firstWhere((m) => m['network_sender'] == 'bob');
    expect(incoming['status'], 'sent');
    await db.deleteIncomingMessage('bob', 'shared-id');
    final remaining = (await db.getMessages(1)).single;
    expect(remaining['network_sender'], 'alice');
    expect(remaining['status'], 'read');
    await db.close();
  });
  test('deleting a conversation cancels its pending outbox transactionally',
      () async {
    final db = await DatabaseService.openForTest(
        databaseFactoryFfi, inMemoryDatabasePath);
    final conversation = await db.createConversation('bob');
    await db.insertMessage(
        conversationId: conversation,
        senderId: 1,
        encryptedContent: 'local',
        networkId: 'audit-queued-000001',
        status: 'queued',
        outgoing: true,
        recipient: 'bob',
        networkPayload: 'still-sent-after-delete');
    await db.deleteConversation(conversation);
    expect(await db.getMessageCount(conversation), 0);
    expect(await db.getOutbox(), isEmpty);
    await db.close();
  });
  test('different senders can reuse a network ID without dropping messages',
      () async {
    final db = await DatabaseService.openForTest(
        databaseFactoryFfi, inMemoryDatabasePath);
    final bob = await db.createConversation('bob');
    final carol = await db.createConversation('carol');
    final first = await db.insertMessage(
        conversationId: bob,
        senderId: 2,
        encryptedContent: 'bob-message',
        networkId: 'audit-same-network-id');
    final second = await db.insertMessage(
        conversationId: carol,
        senderId: 3,
        encryptedContent: 'carol-message',
        networkId: 'audit-same-network-id');
    expect(second, isNot(first));
    expect(await db.getMessageCount(carol), 1);
    await db.close();
  });
  test('read marking only touches the loaded incoming page', () async {
    final db = await DatabaseService.openForTest(
        databaseFactoryFfi, inMemoryDatabasePath);
    for (var i = 0; i < 25; i++) {
      await db.insertMessage(
          conversationId: 1,
          senderId: 2,
          encryptedContent: 'fixture-$i',
          networkId: 'audit-unread-$i');
    }
    expect((await db.getMessages(1, limit: 20)).length, 20);
    final page = await db.getMessages(1, limit: 20);
    await db.markMessagesAsRead(1,
        messageIds: page.map((m) => m['id'] as int).toList());
    final older = await db.getMessages(1, limit: 20, offset: 20);
    expect(older.length, 5);
    expect(older.every((m) => m['is_read'] == 0), isTrue);
    await db.close();
  });
}

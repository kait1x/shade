import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shade/core/database/database_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  test('real SQLite migration preserves v4 history and supports durable outbox',
      () async {
    final folder = await Directory.systemTemp.createTemp('shade-db-test-');
    final path = '${folder.path}/history.db';
    var db = await DatabaseService.openForTest(databaseFactoryFfi, path,
        createVersion4: true);
    final raw = await db.database;
    await raw.insert('messages', {
      'conversation_id': 1,
      'sender_id': 7,
      'encrypted_content': 'legacy-ciphertext',
      'timestamp': 100
    });
    await db.close();
    db = await DatabaseService.openForTest(databaseFactoryFfi, path);
    expect((await db.getMessages(1)).single['encrypted_content'],
        'legacy-ciphertext');
    final id = await db.insertMessage(
        conversationId: 1,
        senderId: 7,
        encryptedContent: 'local-ciphertext',
        networkId: 'unique-network-id',
        status: 'queued',
        outgoing: true,
        recipient: 'bob',
        networkPayload: 'recipient-ciphertext');
    expect((await db.getOutbox()).single['payload'], 'recipient-ciphertext');
    await db.close();
    db = await DatabaseService.openForTest(databaseFactoryFfi, path);
    expect((await db.getOutbox()).length, 1,
        reason: 'survives app restart while offline');
    final duplicate = await db.insertMessage(
        conversationId: 1,
        senderId: 7,
        encryptedContent: 'duplicate',
        networkId: 'unique-network-id',
        outgoing: true);
    expect(duplicate, id);
    expect(await db.getMessageCount(1), 2);
    await db.updateMessageStatus('unique-network-id', 'read');
    await db.updateMessageStatus('unique-network-id', 'delivered');
    expect((await db.getMessages(1)).last['status'], 'read',
        reason: 'late delivered event must not regress read');
    expect(await db.getOutbox(), isEmpty);
    await db.close();
    // Test-only files are deliberately retained for inspection in OS temp.
  });

  test(
      'concurrent conversation creation and duplicate deliveries do not duplicate history',
      () async {
    final db = await DatabaseService.openForTest(
        databaseFactoryFfi, inMemoryDatabasePath);
    final ids = await Future.wait(
        List.generate(4, (_) => db.createConversation('bob')));
    expect(ids.toSet().length, 1);
    await Future.wait(List.generate(
        4,
        (_) => db.insertMessage(
            conversationId: ids.first,
            senderId: 2,
            encryptedContent: 'ciphertext',
            networkId: 'same-incoming-id')));
    expect(await db.getMessageCount(ids.first), 1);
    expect(await db.getUnreadCount(ids.first), 1);
    await db.markMessagesAsRead(ids.first,
        messageIds: (await db.getMessages(ids.first))
            .map((m) => m['id'] as int)
            .toList());
    expect(await db.getUnreadCount(ids.first), 0);
    await db.close();
  });
}

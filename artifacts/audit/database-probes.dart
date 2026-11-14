import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shade/core/database/database_service.dart';

// These probes assert CURRENT DEFECTIVE behavior to make findings reproducible.
// Passing means the defect was reproduced, not that the product is correct.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test('AUDIT: deleting conversation leaves queued payload available for sending', () async {
    final db = await DatabaseService.openForTest(databaseFactoryFfi, inMemoryDatabasePath);
    final conversation = await db.createConversation('bob');
    await db.insertMessage(conversationId: conversation, senderId: 1,
      encryptedContent: 'local', networkId: 'audit-queued-000001', status: 'queued',
      outgoing: true, recipient: 'bob', networkPayload: 'still-sent-after-delete');
    await db.deleteConversation(conversation);
    expect(await db.getMessageCount(conversation), 0);
    expect((await db.getOutbox()).single['payload'], 'still-sent-after-delete');
    await db.close();
  });
  test('AUDIT: IDs from different senders incorrectly deduplicate globally', () async {
    final db = await DatabaseService.openForTest(databaseFactoryFfi, inMemoryDatabasePath);
    final bob = await db.createConversation('bob');
    final carol = await db.createConversation('carol');
    final first = await db.insertMessage(conversationId: bob, senderId: 2,
      encryptedContent: 'bob-message', networkId: 'audit-same-network-id');
    final second = await db.insertMessage(conversationId: carol, senderId: 3,
      encryptedContent: 'carol-message', networkId: 'audit-same-network-id');
    expect(second, first);
    expect(await db.getMessageCount(carol), 0);
    await db.close();
  });
  test('AUDIT: marking latest page read also consumes older unseen receipts', () async {
    final db = await DatabaseService.openForTest(databaseFactoryFfi, inMemoryDatabasePath);
    for (var i = 0; i < 25; i++) {
      await db.insertMessage(conversationId: 1, senderId: 2,
        encryptedContent: 'fixture-$i', networkId: 'audit-unread-$i');
    }
    expect((await db.getMessages(1, limit: 20)).length, 20);
    await db.markMessagesAsRead(1);
    final older = await db.getMessages(1, limit: 20, offset: 20);
    expect(older.length, 5);
    expect(older.every((m) => m['is_read'] == 1), isTrue);
    await db.close();
  });
}

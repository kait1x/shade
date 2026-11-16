import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shade/core/database/database_service.dart';
import 'package:shade/core/services/crypto_service.dart';
import 'package:shade/features/chats/data/repositories/chat_repository.dart';

class _PreviewCrypto extends CryptoService {
  @override
  Future<String> decryptMessage(String encryptedPayload,
      {String? myPrivateKey}) async {
    if (encryptedPayload == 'broken-ciphertext') throw StateError('fixture');
    return encryptedPayload;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  test(
      'home counts incoming unread, sorts by activity and preserves delivery metadata',
      () async {
    final db = await DatabaseService.openForTest(
        databaseFactoryFfi, inMemoryDatabasePath);
    addTearDown(db.close);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final older = await db.createConversation('older');
    final newer = await db.createConversation('newer');
    await db.insertMessage(
        conversationId: older,
        senderId: 1,
        encryptedContent: 'received',
        timestamp: stamp + 100);
    await db.insertMessage(
        conversationId: older,
        senderId: 1,
        encryptedContent: 'received again',
        timestamp: stamp + 200);
    await db.insertMessage(
        conversationId: newer,
        senderId: 2,
        encryptedContent: 'outgoing',
        outgoing: true,
        networkId: 'sent-id',
        status: 'delivered',
        timestamp: stamp + 300);
    final repository = ChatRepository(db, _PreviewCrypto());
    var chats = await repository.getDecryptedConversations();
    expect(chats.first.id, newer);
    expect(chats.first.unreadCount, 0);
    expect(chats.first.lastMessage!.isOutgoing, true);
    expect(chats.first.lastMessage!.status, 'delivered');
    expect(chats.first.lastMessage!.networkId, 'sent-id');
    expect(chats.singleWhere((c) => c.id == older).unreadCount, 2);
    await db.markMessagesAsRead(older,
        messageIds: (await db.getMessages(older))
            .map((row) => row['id'] as int)
            .toList());
    chats = await repository.getDecryptedConversations();
    expect(chats.singleWhere((c) => c.id == older).unreadCount, 0);
    await db.insertMessage(
        conversationId: older,
        senderId: 1,
        encryptedContent: 'broken-ciphertext',
        timestamp: stamp + 400);
    chats = await repository.getDecryptedConversations();
    expect(chats.first.id, older);
    expect(
        chats.first.lastMessage!.encryptedContent, 'Не удалось расшифровать');
    expect(await db.getMessageCount(older), 3);
  });
}

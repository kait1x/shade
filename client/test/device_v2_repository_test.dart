import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fast_rsa/fast_rsa.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shade/core/database/database_service.dart';
import 'package:shade/core/services/crypto_service.dart';
import 'package:shade/core/services/device_v2/crypto.dart';
import 'package:shade/core/services/device_v2/protocol.dart';
import 'package:shade/core/services/device_v2/repository.dart';
import 'package:shade/core/services/device_v2/store.dart';
import 'package:shade/core/services/device_v2/transport.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Полный цикл native-репозитория против реального alpha.mjs: enrollment,
/// сверка genesis, E2EE в обе стороны, replay-дедупликация, доставка, lease.
class _RealNetworkBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

void main() {
  _RealNetworkBinding();
  sqfliteFfiInit();

  test('V2ChatRepository completes Android↔Web E2EE cycle with durable storage',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    final crypto = CryptoService();
    final kp = await RSA.generate(4096);
    final root = await publicSpki(kp.publicKey);
    final folder = await Directory.systemTemp.createTemp('shade-v2-repo-');
    final db = await DatabaseService.openForTest(
        databaseFactoryFfi, '${folder.path}/db');
    final store = V2Store(db);

    final process = await Process.start(
        'node', ['../server/tools/alpha-native-transport.mjs']);
    final lines = StreamIterator(process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter()));
    final stderr = process.stderr.transform(utf8.decoder).join();
    addTearDown(() async {
      await process.stdin.close();
      final exit = await process.exitCode.timeout(const Duration(seconds: 20),
          onTimeout: () {
        process.kill();
        return -1;
      });
      await lines.cancel();
      expect(exit, 0, reason: await stderr);
      await db.close();
      await folder.delete(recursive: true);
    });
    Future<Map<String, dynamic>> next() async {
      expect(await lines.moveNext().timeout(const Duration(seconds: 90)), true);
      return jsonDecode(lines.current) as Map<String, dynamic>;
    }

    Future<Map<String, dynamic>> request(Map<String, dynamic> value) async {
      process.stdin.writeln(jsonEncode(value));
      final result = await next();
      expect(result['ok'], true, reason: result['error']?.toString());
      return result['result'] as Map<String, dynamic>;
    }

    expect((await next())['ready'], true);
    final init = await request({'action': 'init', 'publicKey': kp.publicKey});
    final web = init['web'] as Map<String, dynamic>;

    final transport = AlphaTransport(init['origin'] as String, crypto);
    transport.sessionCookie = init['nativeCookie'] as String;
    addTearDown(transport.dispose);

    final repo = V2ChatRepository(
        transport: transport,
        crypto: crypto,
        store: store,
        account: 'native_android',
        root: root,
        privateKey: kp.privateKey);
    await repo.load();
    expect(repo.enrolled, false);

    final enrolled = await repo.enrollLegacy(
        recoveryPassphrase: 'synthetic native offline recovery phrase');
    expect(enrolled['revision'], 1);
    expect(repo.enrolled, true);
    final acc = await store.loadAccount('native_android');
    await request({
      'action': 'accept-native',
      'genesis': acc!['genesis'],
      'manifest': (acc['history'] as List).first
    });

    // Сверка genesis digest: верный подтверждает, подменённый отклоняется.
    final webDigest =
        sha256Hex(genesisText(web['genesis'] as Map<String, dynamic>));
    expect(() => repo.confirmContact('native_web', 'ab' * 32),
        throwsA(predicate((e) => e.toString().contains('Genesis digest mismatch'))));
    await repo.confirmContact('native_web', webDigest);

    // Исходящее: outbox → сервер → Web расшифровывает и ACK-ает.
    const toWeb = 'Android → Web через репозиторий 🌍';
    await repo.sendMessage('native_web', toWeb);
    final opened = await request({'action': 'web-fetch-open'});
    expect(opened['plaintext'], toWeb);
    expect(await store.outboxAll(), isEmpty);
    final outMessages = await repo.getMessages('native_web');
    expect(outMessages.single['direction'], 'out');
    expect(outMessages.single['text'], toWeb);

    // Доставка: подписанный ACK Web-устройства виден через status.
    final delivery = await repo.refreshDelivery([opened['ref'] as String]);
    final devices = delivery.single['devices'] as List;
    expect(devices.single['acknowledgedAt'], isA<int>());

    // Входящее: Web → Android, атомарное сохранение до ACK.
    const toNative = 'Web → Android через репозиторий 🔐';
    await request({'action': 'web-send', 'text': toNative});
    expect(await repo.syncInbox(), 1);
    final all = await repo.getMessages('native_web');
    expect(all.length, 2);
    expect(all.last['text'], toNative);
    expect(all.last['direction'], 'in');
    // Повторный fetch не дублирует историю (replay ID сохранён).
    expect(await repo.syncInbox(), 0);
    expect((await repo.getMessages('native_web')).length, 2);

    // Reply-совместимость с PWA (контракт zcode/pwa-parity).
    final replyRef = opened['ref'] as String;
    await repo.sendMessage('native_web', 'ответ с Android',
        reply: {'ref': replyRef, 'from': 'native_web', 'text': toWeb});
    final openedReply = await request({'action': 'web-fetch-open'});
    expect(openedReply['plaintext'], 'ответ с Android');
    expect((openedReply['reply'] as Map)['ref'], replyRef);
    expect((openedReply['reply'] as Map)['text'], toWeb);
    await request({
      'action': 'web-send',
      'text': 'ответ с Web',
      'reply': {'ref': replyRef, 'from': 'native_android', 'text': toWeb}
    });
    expect(await repo.syncInbox(), 1);
    final withReply = await repo.getMessages('native_web');
    final lastMsg = withReply.last;
    expect(lastMsg['text'], 'ответ с Web');
    expect((lastMsg['reply'] as Map)['from'], 'native_android');
    expect((lastMsg['reply'] as Map)['text'], toWeb);

    // «Удалить у себя»: входящее и исходящее исчезают локально.
    final incomingRef = lastMsg['ref'] as String;
    await repo.deleteLocal(incomingRef);
    expect(
        (await repo.getMessages('native_web'))
            .any((m) => m['ref'] == incomingRef),
        false);
    await repo.deleteLocal(replyRef);
    expect(
        (await repo.getMessages('native_web')).any((m) => m['ref'] == replyRef),
        false);

    // Self-chat («Избранное») против реального сервера: fanout на свои
    // устройства, копия уже сохранена outbox-ом, очередь ACK-ается.
    await repo.sendMessage('native_android', 'заметка себе');
    expect(await repo.syncInbox(), 0);
    final selfMsgs = await repo.getMessages('native_android');
    expect(selfMsgs.single['text'], 'заметка себе');
    expect(selfMsgs.single['direction'], 'out');
    expect(await repo.syncInbox(), 0);

    // Продление lease и отправка после него.
    await repo.renewLease(force: true);
    final renewed = await store.loadAccount('native_android');
    expect((renewed!['history'] as List).length, 2);
    expect((renewed['checkpoint'] as Map)['revision'], 2);
    await repo.sendMessage('native_web', 'после продления lease');
    final opened2 = await request({'action': 'web-fetch-open'});
    expect(opened2['plaintext'], 'после продления lease');

    // Recovery-пакет сохранён и разблокируется той же фразой.
    final recovery = renewed['recovery'] as Map<String, dynamic>;
    final v2 = DeviceV2Crypto(crypto);
    final pem = await v2.unlockRecoveryBackup(recovery,
        'synthetic native offline recovery phrase',
        renewed['genesis'] as Map<String, dynamic>);
    expect(pem, contains('BEGIN PRIVATE KEY'));
  }, timeout: const Timeout(Duration(minutes: 6)));
}
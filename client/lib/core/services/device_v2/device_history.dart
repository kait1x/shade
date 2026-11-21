import 'dart:convert';
import 'protocol.dart';
import 'repository.dart';

/// Device-to-device copies never enter the live delivery queue. The signed
/// record binds sender, recipient and account before the target writes a row.
extension DeviceHistory on V2ChatRepository {
  Future<List<dynamic>> _historyRoster() async {
    final dir = await transport.directory(account,
        account: account,
        id: session.id,
        privateKey: session.signingPrivateKey);
    final chain = dir['history'] as List;
    final own = accountSnapshot!;
    await v2.verifier.verifyHistory(
        chain, root, own['checkpoint'] as Map<String, dynamic>,
        genesis: own['genesis'] as Map<String, dynamic>);
    return chain.last['devices'] as List;
  }

  Future<dynamic> _historyOp(String op, Object body) =>
      transport.operation(op, body,
          account: account,
          id: session.id,
          privateKey: session.signingPrivateKey);

  Future<int> transferDeviceHistory(String to) async {
    check(to != session.id, 'Выберите другое устройство');
    final roster = await _historyRoster();
    final target = roster.where((d) => d['id'] == to).firstOrNull;
    check(target != null, 'Устройство не найдено');
    var cursor = '', count = 0;
    while (true) {
      final rows = await store.historyPage(cursor);
      if (rows.isEmpty) break;
      final packages = <Map<String, dynamic>>[];
      for (final row in rows) {
        cursor = row['ref'] as String;
        final deleted = row['status'] == 'retracted';
        final plain = deleted
            ? ''
            : await crypto.decryptData(
                row['payload'] as String, session.encryptionPrivateKey);
        final record = jsonEncode({
          'account': account,
          'fromDevice': session.id,
          'toDevice': to,
          'ref': cursor,
          'peer': row['peer'],
          'direction': row['direction'],
          'id': row['message_id'],
          'createdAt': row['created_at'],
          'status': row['status'],
          'plain': plain
        });
        final signature = await crypto.signData(
            'shade-history-v2:$record', session.signingPrivateKey);
        final payload = await crypto.encryptData(
            jsonEncode([record, signature]),
            spkiToPem(target['encryptionKey'] as String));
        check(payload.length <= 87384,
            'Сообщение превышает лимит переноса сервера');
        packages.add({
          'id': sha256Hex(jsonEncode([account, to, cursor, row['status']])),
          'seq': ++count,
          'payload': payload
        });
      }
      await _historyOp('history.transfer', {'to': to, 'packages': packages});
    }
    return count;
  }

  Future<int> receiveDeviceHistory() async {
    final roster = await _historyRoster();
    final target = roster.firstWhere((d) => d['id'] == session.id);
    var count = 0;
    while (true) {
      final response = await _historyOp('history.fetch', {'since': 0});
      final packages = response['packages'] as List;
      if (packages.isEmpty) return count;
      final ids = <String>[];
      for (final p in packages) {
        final envelope = jsonDecode(await crypto.decryptData(
            p['payload'] as String, session.encryptionPrivateKey)) as List;
        final record = envelope[0] as String;
        final row = jsonDecode(record) as Map<String, dynamic>;
        final source =
            roster.where((d) => d['id'] == row['fromDevice']).firstOrNull;
        check(
            source != null &&
                row['account'] == account &&
                row['toDevice'] == session.id,
            'Чужой пакет истории');
        check(
            await crypto.verifySignature(
                'shade-history-v2:$record',
                envelope[1] as String,
                spkiToPem(source['signingKey'] as String)),
            'Подпись истории не совпала');
        final ref = (row['ref'] as String).split(':');
        check(
            ref.length == 3 &&
                accountPattern.hasMatch(row['peer'] as String) &&
                devicePattern.hasMatch(ref[1]) &&
                hex64Pattern.hasMatch(ref[2]) &&
                ref[2] == row['id'] &&
                row['createdAt'] is int &&
                (row['direction'] == 'in' && ref[0] == row['peer'] ||
                    row['direction'] == 'out' && ref[0] == account),
            'Неверная запись истории');
        final local = await crypto.encryptData(row['plain'] as String,
            spkiToPem(target['encryptionKey'] as String));
        if (await store.importHistoryRow(row, local)) count++;
        if (row['status'] == 'retracted')
          await store.markRetracted(row['ref'] as String);
        ids.add(p['id'] as String);
      }
      await _historyOp('history.ack', {'ids': ids});
    }
  }
}

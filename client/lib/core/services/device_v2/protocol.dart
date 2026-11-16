/// Dart-порт протокола device-v2 (client/web/protocol/device-v2.mjs).
///
/// Канонические тексты, хеши и проверки должны совпадать с JS байт-в-байт:
/// кросс-векторы в client/test/assets/device_v2_vectors.json генерируются
/// client/tools/generate_v2_vectors.mjs из самого JS-протокола.
///
/// Криптография переиспользует существующий CryptoService (fast_rsa):
/// RSA-4096 OAEP-SHA256 / PSS-SHA256 (salt 32) с base64-прекодированием UTF-8,
/// AES-256-GCM конверт `2 || key32 || nonce12`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/asn1.dart' as asn1;

import '../crypto_service.dart';

const int maxDevices = 8;
const int maxLeaseMs = 24 * 60 * 60 * 1000;
const int maxMessageAgeMs = 7 * 24 * 60 * 60 * 1000;
const int clockSkewMs = 30000;

final RegExp accountPattern = RegExp(r'^[a-z0-9_]{3,32}$');
final RegExp devicePattern = RegExp(r'^(primary|[a-f0-9]{64})$');
final RegExp hex64Pattern = RegExp(r'^[a-f0-9]{64}$');
final RegExp _b64Pattern = RegExp(
    r'^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$');

class ProtocolException implements Exception {
  final String reason;
  ProtocolException(this.reason);
  @override
  String toString() => 'ProtocolException: $reason';
}

void check(bool value, [String reason = 'Invalid protocol data']) {
  if (!value) throw ProtocolException(reason);
}

bool _isSafeInteger(Object? value) =>
    value is int && value.abs() <= 9007199254740991;

/// SHA-256 hex (lowercase) от UTF-8 строки — аналог hash() в JS.
String sha256Hex(String value) =>
    crypto.sha256.convert(utf8.encode(value)).toString();

/// SHA-256 hex от сырых DER SPKI байт — аналог fingerprint() в JS.
String spkiFingerprint(String spki) =>
    crypto.sha256.convert(unb64(spki, 2048)).toString();

String deviceIdOf(String encryptionKey, String signingKey) =>
    sha256Hex(jsonEncode([encryptionKey, signingKey]));

/// base64-декодирование со строгой проверкой формы и лимита (аналог unb64).
Uint8List unb64(String value, [int max = 1024 * 1024]) {
  check(value.isNotEmpty && value.length <= max && _b64Pattern.hasMatch(value),
      'Invalid protocol data');
  return base64.decode(value);
}

String spkiToPem(String spki) =>
    '-----BEGIN PUBLIC KEY-----\n$spki\n-----END PUBLIC KEY-----';

/// Проверяет DER SPKI: RSA-4096, e=65537 (аналог publicKey() в JS).
void validateRsaSpki(String spki) {
  final der = unb64(spki, 2048);
  try {
    final outer = asn1.ASN1Parser(der).nextObject() as asn1.ASN1Sequence;
    final algorithm = outer.elements![0] as asn1.ASN1Sequence;
    final oid =
        (algorithm.elements![0] as asn1.ASN1ObjectIdentifier).objectIdentifierAsString;
    check(oid == '1.2.840.113549.1.1.1', 'Unsupported RSA key');
    final bits = outer.elements![1] as asn1.ASN1BitString;
    check(bits.unusedbits == 0, 'Unsupported RSA key');
    final inner = asn1.ASN1Parser(Uint8List.fromList(bits.stringValues!))
        .nextObject() as asn1.ASN1Sequence;
    final modulus = (inner.elements![0] as asn1.ASN1Integer).integer;
    final exponent = (inner.elements![1] as asn1.ASN1Integer).integer;
    check(modulus != null && modulus.bitLength == 4096, 'Unsupported RSA key');
    check(exponent == BigInt.from(65537), 'Unsupported RSA key');
  } on ProtocolException {
    rethrow;
  } catch (_) {
    throw ProtocolException('Unsupported RSA key');
  }
}

void _fields(Map<String, dynamic> value, List<String> names) {
  final actual = value.keys.toList()..sort();
  final expected = [...names]..sort();
  check(actual.join(',') == expected.join(','), 'Unexpected fields');
}

void _devicesShape(List<dynamic> devices) {
  check(devices.isNotEmpty && devices.length <= maxDevices,
      'Invalid protocol data');
  var previous = '';
  for (final d in devices) {
    check(d is Map<String, dynamic>, 'Invalid protocol data');
    final device = d as Map<String, dynamic>;
    _fields(device, ['id', 'encryptionKey', 'signingKey']);
    final id = device['id'];
    check(id is String && devicePattern.hasMatch(id) && id.compareTo(previous) > 0,
        'Duplicate or unordered devices');
    unb64(device['encryptionKey'] as String, 2048);
    unb64(device['signingKey'] as String, 2048);
    previous = id;
  }
}

String genesisText(Map<String, dynamic> g) {
  _fields(g, [
    'version', 'account', 'nonce', 'createdAt', 'legacy', 'firstDevice',
    'recoveryKey', 'signature'
  ]);
  check(g['version'] == 2 &&
      g['account'] is String &&
      accountPattern.hasMatch(g['account'] as String) &&
      g['nonce'] is String &&
      hex64Pattern.hasMatch(g['nonce'] as String) &&
      _isSafeInteger(g['createdAt']) &&
      g['legacy'] is bool);
  final firstDevice = g['firstDevice'];
  check(firstDevice is Map<String, dynamic>, 'Invalid protocol data');
  _devicesShape([firstDevice]);
  unb64(g['recoveryKey'] as String, 2048);
  final d = firstDevice as Map<String, dynamic>;
  return jsonEncode([
    'shade-account:v2', g['account'], g['nonce'], g['createdAt'], g['legacy'],
    [d['id'], d['encryptionKey'], d['signingKey']], g['recoveryKey']
  ]);
}

String manifestText(Map<String, dynamic> m) {
  _fields(m, [
    'account', 'rootFingerprint', 'revision', 'previous', 'issuedAt', 'expiresAt',
    'devices', 'signer', 'signature'
  ]);
  check(m['account'] is String && accountPattern.hasMatch(m['account'] as String) &&
      m['rootFingerprint'] is String &&
      hex64Pattern.hasMatch(m['rootFingerprint'] as String));
  check(_isSafeInteger(m['revision']) && (m['revision'] as int) >= 1);
  final previous = m['previous'];
  check(previous == '' ||
      (previous is String && hex64Pattern.hasMatch(previous)));
  check(_isSafeInteger(m['issuedAt']) && _isSafeInteger(m['expiresAt']));
  final signer = m['signer'];
  check(signer is String &&
      (devicePattern.hasMatch(signer) || signer == 'recovery'));
  final devicesValue = m['devices'];
  check(devicesValue is List, 'Invalid protocol data');
  final devices = devicesValue as List;
  _devicesShape(devices);
  return jsonEncode([
    'shade-devices:v2', m['account'], m['rootFingerprint'], m['revision'],
    m['previous'], m['issuedAt'], m['expiresAt'], m['signer'],
    devices.map((d) => [d['id'], d['encryptionKey'], d['signingKey']]).toList()
  ]);
}

String pairingText(String account, Map<String, dynamic> d, String nonce, int expiresAt) {
  check(accountPattern.hasMatch(account) &&
      hex64Pattern.hasMatch(nonce) && _isSafeInteger(expiresAt));
  final id = d['id'];
  check(id is String && devicePattern.hasMatch(id) && id != 'primary');
  return jsonEncode([
    'shade-pair:v2', account, id, d['encryptionKey'], d['signingKey'], nonce,
    expiresAt
  ]);
}

String requestText(String account, String id, String nonce, String operation) {
  check(accountPattern.hasMatch(account) &&
      devicePattern.hasMatch(id) &&
      hex64Pattern.hasMatch(nonce) &&
      hex64Pattern.hasMatch(operation));
  return jsonEncode(['shade-request:v2', account, id, nonce, operation]);
}

String messageText(Map<String, dynamic> m) {
  _fields(m, [
    'version', 'id', 'from', 'deviceId', 'to', 'fromRevision', 'toRevision',
    'fromDigest', 'toDigest', 'createdAt', 'envelopes', 'signature'
  ]);
  check(m['version'] == 2 &&
      m['id'] is String && hex64Pattern.hasMatch(m['id'] as String) &&
      m['from'] is String && m['to'] is String &&
      accountPattern.hasMatch(m['from'] as String) &&
      accountPattern.hasMatch(m['to'] as String) &&
      m['from'] != m['to'] &&
      m['deviceId'] is String && devicePattern.hasMatch(m['deviceId'] as String));
  check([m['fromRevision'], m['toRevision']]
          .every((n) => _isSafeInteger(n) && (n as int) >= 1) &&
      _isSafeInteger(m['createdAt']));
  check(hex64Pattern.hasMatch(m['fromDigest'] as String) &&
      hex64Pattern.hasMatch(m['toDigest'] as String));
  final envelopesValue = m['envelopes'];
  check(envelopesValue is List, 'Invalid protocol data');
  final envelopes = envelopesValue as List;
  check(envelopes.length >= 2 && envelopes.length <= maxDevices * 2,
      'Invalid protocol data');
  var previous = '';
  for (final e in envelopes) {
    check(e is Map<String, dynamic>, 'Invalid protocol data');
    final envelope = e as Map<String, dynamic>;
    _fields(envelope, ['account', 'deviceId', 'payload']);
    final payloadValue = envelope['payload'];
    check(payloadValue is Map<String, dynamic>, 'Invalid protocol data');
    final payload = payloadValue as Map<String, dynamic>;
    _fields(payload, ['k', 'd']);
    final account = envelope['account'];
    final deviceId = envelope['deviceId'];
    final target = '$account:$deviceId';
    check(account is String && accountPattern.hasMatch(account) &&
        deviceId is String && devicePattern.hasMatch(deviceId) &&
        target.compareTo(previous) > 0, 'Duplicate or unordered recipients');
    check(unb64(payload['k'] as String, 1024).length == 512);
    check(unb64(payload['d'] as String, 100000).length >= 16);
    previous = target;
  }
  return jsonEncode([
    'shade-message:v2', m['id'], m['from'], m['deviceId'], m['to'],
    m['fromRevision'], m['toRevision'], m['fromDigest'], m['toDigest'],
    m['createdAt'],
    envelopes
        .map((e) => [e['account'], e['deviceId'], e['payload']['k'], e['payload']['d']])
        .toList()
  ]);
}

/// operationDigest из registry.mjs: hash(JSON.stringify([op, body])).
String operationDigest(String op, Object? body) =>
    sha256Hex(jsonEncode([op, body]));

String messageRef(Map<String, dynamic> m) =>
    '${m['from']}:${m['deviceId']}:${m['id']}';

/// Верификация подписанных структур протокола поверх CryptoService.
class DeviceV2Verifier {
  final CryptoService crypto;
  DeviceV2Verifier(this.crypto);

  Future<bool> verify(String text, String signature, String spki) async {
    try {
      unb64(signature, 1024);
      validateRsaSpki(spki);
      return await crypto.verifySignature(text, signature, spkiToPem(spki));
    } catch (_) {
      return false;
    }
  }

  Future<String> verifyGenesis(Map<String, dynamic> g, String trustedRoot) async {
    final text = genesisText(g);
    final d = g['firstDevice'] as Map<String, dynamic>;
    check(d['signingKey'] == trustedRoot, 'Genesis anchor substitution');
    if (g['legacy'] == true) {
      check(d['id'] == 'primary' && d['encryptionKey'] == trustedRoot,
          'Legacy identity changed');
    } else {
      check(
          d['id'] == deviceIdOf(d['encryptionKey'] as String, d['signingKey'] as String) &&
              d['encryptionKey'] != d['signingKey'],
          'Invalid first device');
    }
    check(g['recoveryKey'] != d['encryptionKey'] && g['recoveryKey'] != d['signingKey'],
        'Recovery must use an independent key');
    validateRsaSpki(d['encryptionKey'] as String);
    validateRsaSpki(g['recoveryKey'] as String);
    check(await verify(text, g['signature'] as String, trustedRoot),
        'Invalid genesis signature');
    return sha256Hex(text);
  }

  Future<String> verifyManifest(Map<String, dynamic> m, String trustedRoot,
      {int? now, String? authority}) async {
    now ??= DateTime.now().millisecondsSinceEpoch;
    authority ??= trustedRoot;
    final text = manifestText(m);
    check(m['rootFingerprint'] == spkiFingerprint(trustedRoot),
        'Root identity changed');
    final issuedAt = m['issuedAt'] as int, expiresAt = m['expiresAt'] as int;
    check(issuedAt <= now + clockSkewMs &&
        expiresAt > now &&
        expiresAt > issuedAt &&
        expiresAt - issuedAt <= maxLeaseMs, 'Expired or invalid directory lease');
    final devices = (m['devices'] as List).cast<Map<String, dynamic>>();
    final primary = devices.where((d) => d['id'] == 'primary').firstOrNull;
    if (primary != null) {
      check(primary['encryptionKey'] == trustedRoot && primary['signingKey'] == trustedRoot,
          'Primary identity changed');
    }
    final usedKeys = <String>{if (primary != null) trustedRoot};
    for (final d in devices) {
      if (d['id'] != 'primary') {
        check(
            d['id'] == deviceIdOf(d['encryptionKey'] as String, d['signingKey'] as String),
            'Device ID/key mismatch');
        check(d['encryptionKey'] != d['signingKey'] &&
            !usedKeys.contains(d['encryptionKey']) &&
            !usedKeys.contains(d['signingKey']), 'Device key reuse');
        usedKeys.add(d['encryptionKey'] as String);
        usedKeys.add(d['signingKey'] as String);
      }
      validateRsaSpki(d['encryptionKey'] as String);
      validateRsaSpki(d['signingKey'] as String);
    }
    check(await verify(text, m['signature'] as String, authority),
        'Invalid root approval');
    return sha256Hex(text);
  }

  /// acceptManifest: проверка + checkpoint против rollback/fork.
  Future<Map<String, dynamic>> acceptManifest(Map<String, dynamic> m,
      String trustedRoot, Map<String, dynamic>? checkpoint,
      {int? now}) async {
    final digest = await verifyManifest(m, trustedRoot, now: now);
    if (checkpoint != null) {
      check(m['account'] == checkpoint['account'] &&
          m['rootFingerprint'] == checkpoint['rootFingerprint'],
          'Wrong directory identity');
      final revision = m['revision'] as int;
      final checkpointRevision = checkpoint['revision'] as int;
      check(revision >= checkpointRevision, 'Directory rollback');
      if (revision == checkpointRevision) {
        check(digest == checkpoint['digest'], 'Directory fork');
      } else {
        check(revision == checkpointRevision + 1 && m['previous'] == checkpoint['digest'],
            'Missing directory history');
      }
    }
    return {
      'account': m['account'],
      'rootFingerprint': m['rootFingerprint'],
      'revision': m['revision'],
      'digest': digest
    };
  }

  /// verifyHistory: полная цепочка каталогов с genesis и checkpoint.
  Future<Map<String, dynamic>> verifyHistory(List<dynamic> history,
      String trustedRoot, Map<String, dynamic>? checkpoint,
      {int? now, Map<String, dynamic>? genesis}) async {
    now ??= DateTime.now().millisecondsSinceEpoch;
    final genesisDigest =
        genesis != null ? await verifyGenesis(genesis, trustedRoot) : null;
    check(history.isNotEmpty && history.length <= 4096,
        'Invalid directory history');
    var previous = '';
    var issuedAt = 0;
    String? pinned;
    final retired = <String>{};
    final retiredKeys = <String>{};
    List<Map<String, dynamic>> oldDevices = [];
    final firstAccount = (history.first as Map<String, dynamic>)['account'];
    for (var index = 0; index < history.length; index++) {
      final m = history[index] as Map<String, dynamic>;
      check(m['revision'] == index + 1 &&
          m['previous'] == previous &&
          (m['issuedAt'] as int) >= issuedAt &&
          m['account'] == firstAccount, 'Broken directory chain');
      var authority = trustedRoot;
      if (genesis != null) {
        check(m['account'] == genesis['account'], 'Wrong genesis account');
        final signer = m['signer'] as String;
        final firstDevice = genesis['firstDevice'] as Map<String, dynamic>;
        if (index == 0) {
          check(signer == firstDevice['id'], 'Genesis signer must be the first device');
        }
        Map<String, dynamic>? device;
        if (index == 0) {
          device = firstDevice;
        } else {
          final previousDevices =
              (history[index - 1] as Map<String, dynamic>)['devices'] as List;
          device = previousDevices
              .cast<Map<String, dynamic>>()
              .where((d) => d['id'] == signer)
              .firstOrNull;
        }
        authority = (signer == 'recovery' && index > 0)
            ? genesis['recoveryKey'] as String
            : device?['signingKey'] as String? ?? '';
        check(authority.isNotEmpty && (signer == 'recovery' || device?['id'] == signer),
            'Revoked or unauthorized directory signer');
        if (index == 0) {
          final devices = (m['devices'] as List).cast<Map<String, dynamic>>();
          check(devices.any((d) => d['id'] == firstDevice['id']) &&
              (m['issuedAt'] as int) >= (genesis['createdAt'] as int),
              'First device missing or invalid genesis time');
        }
      } else {
        check((m['signer'] ?? 'primary') == 'primary',
            'Genesis required for delegated signer');
      }
      previous = await verifyManifest(m, trustedRoot,
          now: m['issuedAt'] as int, authority: authority);
      final devices = (m['devices'] as List).cast<Map<String, dynamic>>();
      for (final d in oldDevices) {
        if (!devices.any((next) => next['id'] == d['id'])) {
          retired.add(d['id'] as String);
          retiredKeys.add(d['encryptionKey'] as String);
          retiredKeys.add(d['signingKey'] as String);
        }
      }
      for (final d in devices) {
        check(!retired.contains(d['id']) &&
            !retiredKeys.contains(d['encryptionKey']) &&
            !retiredKeys.contains(d['signingKey']), 'Revoked device resurrected');
        if (genesis != null) {
          check(d['encryptionKey'] != genesis['recoveryKey'] &&
              d['signingKey'] != genesis['recoveryKey'],
              'Recovery key cannot be a device key');
        }
      }
      oldDevices = devices;
      issuedAt = m['issuedAt'] as int;
      if (checkpoint != null && m['revision'] == checkpoint['revision']) {
        pinned = previous;
      }
    }
    final latest = history.last as Map<String, dynamic>;
    check((latest['issuedAt'] as int) <= now + clockSkewMs &&
        (latest['expiresAt'] as int) > now, 'Expired directory lease');
    if (checkpoint != null) {
      check(checkpoint['account'] == latest['account'] &&
          checkpoint['rootFingerprint'] == latest['rootFingerprint'] &&
          (latest['revision'] as int) >= (checkpoint['revision'] as int) &&
          pinned == checkpoint['digest'] &&
          (genesis == null || checkpoint['genesisDigest'] == genesisDigest),
          'Directory rollback or fork');
    }
    return {
      'account': latest['account'],
      'rootFingerprint': latest['rootFingerprint'],
      'revision': latest['revision'],
      'digest': previous,
      'genesisDigest': genesisDigest
    };
  }

  Future<String> verifyMessage(Map<String, dynamic> m,
      Map<String, dynamic> sender, Map<String, dynamic> recipient,
      {int? now}) async {
    now ??= DateTime.now().millisecondsSinceEpoch;
    final text = messageText(m);
    check(m['from'] == sender['account'] && m['to'] == recipient['account'],
        'Wrong accounts');
    check(m['fromRevision'] == sender['revision'] &&
        m['toRevision'] == recipient['revision'] &&
        m['fromDigest'] == sha256Hex(manifestText(sender)) &&
        m['toDigest'] == sha256Hex(manifestText(recipient)), 'Stale device directory');
    final createdAt = m['createdAt'] as int;
    check(createdAt <= now + clockSkewMs && createdAt >= now - maxMessageAgeMs,
        'Expired message');
    final senderDevices = (sender['devices'] as List).cast<Map<String, dynamic>>();
    final device = senderDevices.where((d) => d['id'] == m['deviceId']).firstOrNull;
    check(device != null, 'Revoked or unknown sender device');
    final expected = [sender, recipient]
        .expand((roster) => (roster['devices'] as List)
            .cast<Map<String, dynamic>>()
            .map((d) => '${roster['account']}:${d['id']}'))
        .toList()
      ..sort();
    final actual = (m['envelopes'] as List)
        .map((e) => '${e['account']}:${e['deviceId']}')
        .toList();
    check(jsonEncode(actual) == jsonEncode(expected), 'Incomplete recipient fanout');
    check(await verify(text, m['signature'] as String, device!['signingKey'] as String),
        'Invalid device message signature');
    return sha256Hex(text);
  }
}
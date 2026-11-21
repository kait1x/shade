/// Dart-зеркало pairing-контракта второго устройства (client/web/pairing.mjs).
///
/// Байт-в-байт совместимость с JS: канонические тексты (pairingTextV2 /
/// pairingText), порядок полей JSON, base64url без padding, префиксы кодов,
/// подписи RSA-PSS SHA-256 salt 32 через существующий CryptoService.
/// Форматы и протокол не изменяются: golden-векторы генерируются из самого
/// pairing.mjs (client/tools/generate_pairing_vectors.mjs) и сверяются в
/// client/test/device_v2_pairing_test.dart.
///
/// Транспорт между устройствами — обычный буфер обмена, поэтому каждый блок
/// самодостаточен, версионирован и проверяется криптографией, а не доверием
/// к каналу: offer несёт challenge-bound proof (v2), confirmation — только
/// подсказку маршрута (genesis + tip), полная проверка каталога выполняется
/// против сервера после открытия device-сессии.
library;

import 'dart:convert';

import 'package:fast_rsa/fast_rsa.dart';

import '../crypto_service.dart';
import 'crypto.dart';
import 'protocol.dart';

/// Сервер принимает proof с expiresAt в (now, now + 300000]; четыре минуты
/// оставляют реалистичный круг через буфер обмена.
const int offerTtlMs = 240000;

/// Одноразовый код на доверенном устройстве; offer обязан его эхом подтвердить.
const int challengeTtlMs = 5 * 60000;

const int _challengeBytes = 15; // 120 бит -> ровно 24 символа Crockford base32.
const String _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'; // Без I/L/O/U.

const String offerPrefixV1 = 'shade-pair-v1:';
const String offerPrefixV2 = 'shade-pair-v2:';
const String confirmPrefix = 'shade-pair-confirm-v1:';

final RegExp _challengePattern = RegExp(r'^[a-f0-9]{30}$');

bool _isSafeInt(Object? value) =>
    value is int && value.abs() <= 9007199254740991;

String _bytesToHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// base64url без padding — точно как b64url в pairing.mjs.
String _b64url(String value) => base64
    .encode(utf8.encode(value))
    .replaceAll('+', '-')
    .replaceAll('/', '_')
    .replaceAll(RegExp(r'=+$'), '');

String _fromB64url(String value, String prefix) {
  check(value.startsWith(prefix), 'Неверный формат кода подключения');
  final body = value
      .substring(prefix.length)
      .replaceAll('-', '+')
      .replaceAll('_', '/');
  final padded = body + '=' * ((4 - body.length % 4) % 4);
  final bytes = unb64(padded, 64 * 1024);
  try {
    // Строгий UTF-8, как fatal TextDecoder в JS.
    return utf8.decode(bytes);
  } on FormatException {
    throw ProtocolException('Неверный формат кода подключения');
  }
}

String _encodeChallengeBytes(List<int> bytes) {
  var bits = 0, value = 0;
  final chars = StringBuffer();
  for (final byte in bytes) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      chars.write(_alphabet[(value >>> (bits - 5)) & 31]);
      bits -= 5;
    }
  }
  return RegExp(r'.{6}')
      .allMatches(chars.toString())
      .map((m) => m.group(0))
      .join('-');
}

/// Одноразовый challenge доверенного устройства: код показывается только на
/// его экране и живёт 5 минут. Возвращает {nonce, expiresAt, code}.
Map<String, dynamic> createPairingChallenge({int? now}) {
  now ??= DateTime.now().millisecondsSinceEpoch;
  final bytes = randomBytes(_challengeBytes);
  return {
    'nonce': _bytesToHex(bytes),
    'expiresAt': now + challengeTtlMs,
    'code': _encodeChallengeBytes(bytes)
  };
}

/// Код, введённый пользователем, -> nonce (hex). Нормализация регистра,
/// пробелов/дефисов и неоднозначных I/L/O — как decodeChallenge в JS.
String decodeChallenge(String text) {
  final normalized = text
      .toUpperCase()
      .replaceAll(RegExp(r'[^0-9A-Z]'), '')
      .replaceAll('I', '1')
      .replaceAll('L', '1')
      .replaceAll('O', '0');
  check(normalized.length == 24, 'Код подключения состоит из 24 символов');
  final bytes = <int>[];
  var bits = 0, value = 0;
  for (final char in normalized.split('')) {
    final index = _alphabet.indexOf(char);
    check(index >= 0, 'В коде подключения недопустимый символ');
    value = (value << 5) | index;
    bits += 5;
    if (bits >= 8) {
      bytes.add((value >>> (bits - 8)) & 255);
      bits -= 8;
    }
  }
  check(bytes.length == _challengeBytes && bits < 8,
      'Некорректный код подключения');
  return _bytesToHex(bytes);
}

/// Канонический код challenge из nonce — для визуального эха на новом
/// устройстве (сверка с экраном доверенного устройства).
String challengeCodeOf(String nonce) {
  check(_challengePattern.hasMatch(nonce), 'Invalid pairing challenge');
  final bytes = <int>[
    for (var i = 0; i < nonce.length; i += 2)
      int.parse(nonce.substring(i, i + 2), radix: 16)
  ];
  return _encodeChallengeBytes(bytes);
}

/// Канонический challenge-bound текст pairing-proof (pairingTextV2 в JS).
/// Доменный тег 'shade-pair:v3' отделяет его от legacy-текста 'shade-pair:v2':
/// подмена challenge или ключей устройства ломает подпись.
String pairingTextV2(String account, Map<String, dynamic> d, String nonce,
    int expiresAt, String challenge) {
  check(_challengePattern.hasMatch(challenge), 'Invalid pairing challenge');
  check(accountPattern.hasMatch(account) &&
      hex64Pattern.hasMatch(nonce) &&
      _isSafeInt(expiresAt));
  final id = d['id'];
  check(id is String && devicePattern.hasMatch(id) && id != 'primary');
  return jsonEncode([
    'shade-pair:v3', account, id, d['encryptionKey'], d['signingKey'], nonce,
    expiresAt, challenge
  ]);
}

/// Строгая форма offer: ровно ожидаемый набор полей (лишние запрещены).
Map<String, dynamic> _offerFields(Map<String, dynamic> offer) {
  final keys = offer.keys.toList()..sort();
  check(keys.join(',') == 'account,challenge,device,expiresAt,nonce,signature,v',
      'Неверный формат запроса подключения');
  final v = offer['v'];
  check((v == 1 || v == 2) &&
      offer['account'] is String &&
      accountPattern.hasMatch(offer['account'] as String) &&
      offer['challenge'] is String &&
      _challengePattern.hasMatch(offer['challenge'] as String) &&
      offer['nonce'] is String &&
      hex64Pattern.hasMatch(offer['nonce'] as String) &&
      _isSafeInt(offer['expiresAt']) &&
      offer['signature'] is String, 'Неверный формат запроса подключения');
  final d = offer['device'];
  check(d is Map<String, dynamic>, 'Неверный дескриптор устройства');
  final device = d as Map<String, dynamic>;
  final deviceKeys = device.keys.toList()..sort();
  check(deviceKeys.join(',') == 'encryptionKey,id,signingKey' &&
      device['id'] is String &&
      devicePattern.hasMatch(device['id'] as String) &&
      device['id'] != 'primary', 'Неверный дескриптор устройства');
  unb64(device['encryptionKey'] as String, 2048);
  unb64(device['signingKey'] as String, 2048);
  unb64(offer['signature'] as String, 1024);
  return offer;
}

/// Строгая форма tip каталога в подтверждении (tipFields в JS).
void _tipFields(Map<String, dynamic> tip) {
  final keys = tip.keys.toList()..sort();
  check(keys.join(',') ==
      'account,devices,expiresAt,issuedAt,previous,revision,rootFingerprint,signature,signer',
      'Неверный формат подтверждения');
  final devices = tip['devices'];
  check(devices is List && devices.isNotEmpty && devices.length <= maxDevices,
      'Неверный ростер подтверждения');
  for (final d in devices as List) {
    check(d is Map<String, dynamic>, 'Неверный ростер подтверждения');
    final device = d as Map<String, dynamic>;
    final deviceKeys = device.keys.toList()..sort();
    check(deviceKeys.join(',') == 'encryptionKey,id,signingKey' &&
        device['id'] is String &&
        devicePattern.hasMatch(device['id'] as String),
        'Неверный ростер подтверждения');
    unb64(device['encryptionKey'] as String, 2048);
    unb64(device['signingKey'] as String, 2048);
  }
}

String encodeOffer(Map<String, dynamic> offer) {
  _offerFields(offer);
  return (offer['v'] == 2 ? offerPrefixV2 : offerPrefixV1) +
      _b64url(jsonEncode(offer));
}

Map<String, dynamic> decodeOffer(String text) {
  final v2 = text.startsWith(offerPrefixV2);
  final dynamic parsed;
  try {
    parsed = jsonDecode(_fromB64url(text, v2 ? offerPrefixV2 : offerPrefixV1));
  } on FormatException {
    throw ProtocolException('Неверный формат кода подключения');
  }
  check(parsed is Map<String, dynamic>, 'Неверный формат запроса подключения');
  final offer = _offerFields(parsed as Map<String, dynamic>);
  check((offer['v'] == 2) == v2, 'Неверный формат кода подключения');
  return offer;
}

/// Подтверждение доверенного устройства: закреплённый genesis (само-
/// аутентифицируемый) и свежий tip ростера как подсказка маршрута.
Map<String, dynamic> buildPairingConfirmation({
  required String account,
  required Map<String, dynamic> genesis,
  required Map<String, dynamic> tip,
}) {
  _tipFields(tip);
  check(accountPattern.hasMatch(account) &&
      genesis['account'] == account &&
      genesis['recoveryKey'] is String, 'Неверные данные аккаунта');
  return {'v': 1, 'account': account, 'genesis': genesis, 'tip': tip};
}

String encodeConfirmation(Map<String, dynamic> confirmation) =>
    confirmPrefix + _b64url(jsonEncode(confirmation));

Map<String, dynamic> decodeConfirmation(String text) {
  final dynamic parsed;
  try {
    parsed = jsonDecode(_fromB64url(text, confirmPrefix));
  } on FormatException {
    throw ProtocolException('Неверный формат подтверждения');
  }
  check(parsed is Map<String, dynamic>, 'Неверный формат подтверждения');
  final value = parsed as Map<String, dynamic>;
  final keys = value.keys.toList()..sort();
  check(keys.join(',') == 'account,genesis,tip,v' && value['v'] == 1,
      'Неверный формат подтверждения');
  final tip = value['tip'];
  check(tip is Map<String, dynamic>, 'Неверный формат подтверждения');
  _tipFields(tip as Map<String, dynamic>);
  return value;
}

/// Криптографические операции pairing поверх существующего CryptoService:
/// подписи RSA-PSS SHA-256 (salt 32) с base64-прекодированием UTF-8 —
/// параметры совпадают с sign/verify в device-v2.mjs.
class DeviceV2Pairing {
  final CryptoService crypto;
  final DeviceV2Verifier verifier;

  DeviceV2Pairing(this.crypto) : verifier = DeviceV2Verifier(crypto);

  /// Новая пара независимых RSA-4096 ключей устройства (шифрование/подпись).
  /// Приватные части никогда не покидают устройство; долговечное хранение
  /// обеспечивает вызывающий (журнал pairing в SQLCipher).
  Future<DeviceV2Session> generateDeviceSession(String account) async {
    check(accountPattern.hasMatch(account), 'Некорректный аккаунт');
    final encryption = await RSA.generate(4096);
    final signing = await RSA.generate(4096);
    final encryptionKey = await publicSpki(encryption.publicKey);
    final signingKey = await publicSpki(signing.publicKey);
    return DeviceV2Session(
        account: account,
        id: deviceIdOf(encryptionKey, signingKey),
        encryptionKey: encryptionKey,
        signingKey: signingKey,
        encryptionPrivateKey: encryption.privateKey,
        signingPrivateKey: signing.privateKey);
  }

  /// Новое устройство: подписанный offer. Ключи устройства уже существуют
  /// локально; на relay в этот момент ничего не отправляется.
  Future<Map<String, dynamic>> buildPairingOffer({
    required String account,
    required Map<String, dynamic> device,
    required String signingPrivateKey,
    required String challenge,
    int? now,
    int ttlMs = offerTtlMs,
    int version = 2,
  }) async {
    now ??= DateTime.now().millisecondsSinceEpoch;
    check(accountPattern.hasMatch(account), 'Некорректный аккаунт');
    check(_challengePattern.hasMatch(challenge),
        'Введите действующий код подключения');
    check(version == 1 || version == 2, 'Неверная версия запроса подключения');
    final nonce = randomHex(32);
    final expiresAt = now + ttlMs;
    check(expiresAt <= now + 300000,
        'Срок запроса подключения превышает допустимый');
    // Порядок полей фиксирован: JSON подписывается и кодируется байт-в-байт
    // в том же виде, что JSON.stringify в pairing.mjs.
    final offer = <String, dynamic>{
      'v': version,
      'account': account,
      'device': device,
      'challenge': challenge,
      'nonce': nonce,
      'expiresAt': expiresAt,
      'signature': ''
    };
    offer['signature'] = await crypto.signData(
        version == 2
            ? pairingTextV2(account, device, nonce, expiresAt, challenge)
            : pairingText(account, device, nonce, expiresAt),
        signingPrivateKey);
    return offer;
  }

  /// Доверенное устройство: полная проверка offer до экрана подтверждения.
  /// Любое несовпадение — исключение с конкретной причиной для UI.
  Future<Map<String, dynamic>> verifyPairingOffer(
      Map<String, dynamic> offer,
      {required String account,
      required String challenge,
      int? now}) async {
    now ??= DateTime.now().millisecondsSinceEpoch;
    _offerFields(offer);
    check(offer['account'] == account, 'Запрос привязан к другому аккаунту');
    check(offer['challenge'] == challenge,
        'Код подключения не совпадает. Сгенерируйте новый на этом устройстве.');
    final expiresAt = offer['expiresAt'] as int;
    check(expiresAt > now,
        'Срок запроса истёк. Создайте запрос на новом устройстве заново.');
    check(expiresAt <= now + 300000, 'Срок запроса превышает допустимый');
    final d = offer['device'] as Map<String, dynamic>;
    check(d['id'] == deviceIdOf(d['encryptionKey'] as String, d['signingKey'] as String),
        'Идентификатор устройства не совпадает с ключами');
    // RSA-4096, e=65537 — слабые ключи не попадают в ростер через offer.
    validateRsaSpki(d['encryptionKey'] as String);
    validateRsaSpki(d['signingKey'] as String);
    // v2: challenge ВНУТРИ подписанного текста — подменённое эхо или ключи
    // ломают подпись здесь, а не только при локальном сравнении эха.
    final text = offer['v'] == 2
        ? pairingTextV2(account, d, offer['nonce'] as String, expiresAt,
            offer['challenge'] as String)
        : pairingText(account, d, offer['nonce'] as String, expiresAt);
    check(await verifier.verify(text, offer['signature'] as String, d['signingKey'] as String),
        'Подпись устройства недействительна');
    return d;
  }

  /// Новое устройство: проверка genesis подтверждения и того, что tip хотя бы
  /// заявляет это устройство в ростере. Авторитетная проверка цепочки —
  /// против каталога сервера ПОСЛЕ открытия device-сессии (completePairing).
  Future<Map<String, dynamic>> verifyPairingConfirmation(
      Map<String, dynamic> confirmation,
      {required String account,
      required String deviceId,
      int? now}) async {
    now ??= DateTime.now().millisecondsSinceEpoch;
    check(confirmation['account'] == account,
        'Подтверждение привязано к другому аккаунту');
    final genesis = confirmation['genesis'];
    check(genesis is Map<String, dynamic> && genesis['account'] == account,
        'Неверный формат подтверждения');
    final g = genesis as Map<String, dynamic>;
    final firstDevice = g['firstDevice'];
    check(firstDevice is Map<String, dynamic> &&
        firstDevice['signingKey'] is String,
        'Неверный формат подтверждения');
    final root = (firstDevice as Map<String, dynamic>)['signingKey'] as String;
    final genesisDigest = await verifier.verifyGenesis(g, root);
    final tip = confirmation['tip'];
    check(tip is Map<String, dynamic>, 'Неверный формат подтверждения');
    final t = tip as Map<String, dynamic>;
    check(t['account'] == account && t['rootFingerprint'] == spkiFingerprint(root),
        'Каталог подтверждения не совпадает с genesis');
    check((t['expiresAt'] as int) > now,
        'Срок каталога подтверждения истёк. Запросите подтверждение заново.');
    check((t['devices'] as List).any((d) => d['id'] == deviceId),
        'Устройство отсутствует в подтверждённом ростере');
    return {'genesis': g, 'tip': t, 'root': root, 'genesisDigest': genesisDigest};
  }
}
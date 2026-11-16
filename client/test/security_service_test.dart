import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shade/services/security_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.shade.app/security');
  final List<MethodCall> log = <MethodCall>[];

  setUp(() {
    log.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      log.add(methodCall);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('disableSecureMode invokes disableSecureMode on channel', () async {
    await SecurityService.disableSecureMode();
    expect(log, hasLength(1));
    expect(log.first.method, 'disableSecureMode');
  });

  test('enableSecureMode invokes disableSecureMode to ensure restrictions remain removed', () async {
    await SecurityService.enableSecureMode();
    expect(log, hasLength(1));
    expect(log.first.method, 'disableSecureMode');
  });

  test('setSecureMode invokes setSecureMode on channel', () async {
    await SecurityService.setSecureMode(true);
    expect(log, hasLength(1));
    expect(log.first.method, 'setSecureMode');
    expect(log.first.arguments, {'enabled': true});
  });

  test('excludeFromRecents invokes excludeFromRecents on channel', () async {
    await SecurityService.excludeFromRecents();
    expect(log, hasLength(1));
    expect(log.first.method, 'excludeFromRecents');
  });
}

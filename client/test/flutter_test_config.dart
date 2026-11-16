import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// flutter clean removes fast_rsa's Windows test host library. Stage the real
/// library shipped by the locked dependency, without building a desktop app or
/// replacing cryptographic operations with mocks.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  if (Platform.isWindows) {
    final config = File('.dart_tool/package_config.json').absolute;
    final packages =
        (jsonDecode(await config.readAsString()) as Map)['packages'] as List;
    final package =
        packages.cast<Map>().firstWhere((p) => p['name'] == 'fast_rsa');
    final root = (package['rootUri'] as String).replaceFirst(RegExp(r'/$'), '');
    final source = File.fromUri(
        config.uri.resolve('$root/windows/shared/librsa_bridge.dll'));
    final target = File('build/windows/x64/runner/Debug/librsa_bridge.dll');
    if (!await target.exists()) {
      await target.parent.create(recursive: true);
      final staged = File(
          '${target.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp');
      await source.copy(staged.path);
      try {
        // Test suites run in parallel; publish the completed DLL atomically.
        if (!await target.exists()) {
          await staged.rename(target.path);
        }
      } on FileSystemException {
        if (!await target.exists()) {
          rethrow;
        }
      } finally {
        if (await staged.exists()) {
          await staged.delete();
        }
      }
    }
  }
  await testMain();
}

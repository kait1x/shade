import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shade/core/services/device_v2/repository.dart';
import 'package:shade/core/services/device_v2/transport.dart';
import 'v2_providers.dart';

final androidPushProvider = ChangeNotifierProvider<AndroidPush?>((ref) {
  if (ref.watch(v2SyncProvider) == null) return null;
  final service = ref.read(v2SyncProvider);
  final repo = ref.read(v2SessionProvider.notifier).repository;
  return repo == null ? null : AndroidPush(repo, sync: service?.syncNow);
});

class AndroidPush extends ChangeNotifier {
  final V2ChatRepository repo;
  bool enabled = false, busy = true, _closed = false;
  StreamSubscription<String>? _tokens;
  StreamSubscription<RemoteMessage>? _messages;
  final Future<void> Function()? sync;
  AndroidPush(this.repo, {this.sync}) {
    unawaited(_restore());
  }
  String get _key =>
      'v2.push.${repo.transport.origin}.${repo.account}.${repo.session.id}';
  Future<void> _restore() async {
    try {
      enabled = (await SharedPreferences.getInstance()).getBool(_key) == true;
      if (enabled && !_closed) {
        _listen();
        final token = await FirebaseMessaging.instance.getToken();
        if (token != null && !_closed) await _subscribe(token);
      }
    } catch (_) {/* Offline startup retains the device preference. */} finally {
      busy = false;
      if (!_closed) notifyListeners();
    }
  }

  void _listen() {
    _tokens ??= FirebaseMessaging.instance.onTokenRefresh.listen((token) async {
      if (!enabled || _closed) return;
      try {
        await _subscribe(token);
      } catch (_) {/* Retried on next launch. */}
    });
    _messages ??= FirebaseMessaging.onMessage.listen((_) {
      if (!_closed) sync?.call();
    });
  }

  Future<void> _operation(String name, Object? body) async {
    await repo.transport.operation(name, body,
        account: repo.account,
        id: repo.session.id,
        privateKey: repo.session.signingPrivateKey);
  }

  Future<void> _subscribe(String token) =>
      _operation('push.android.subscribe', {'token': token});
  Future<void> setEnabled(bool value) async {
    if (busy || _closed) return;
    busy = true;
    notifyListeners();
    try {
      if (value) {
        final messaging = FirebaseMessaging.instance;
        final permission = await messaging.requestPermission();
        if (permission.authorizationStatus == AuthorizationStatus.denied)
          throw StateError(
              'Разрешите уведомления Shade в настройках телефона.');
        final token = await messaging.getToken();
        if (token == null)
          throw StateError('Телефон пока не получил токен уведомлений.');
        await _subscribe(token);
        if (!_closed) _listen();
      } else {
        try {
          await _operation('push.android.unsubscribe', null);
        } on AlphaTransportException catch (error) {
          if (error.code != 'login_required') rethrow;
          await FirebaseMessaging.instance.deleteToken();
        }
        await _tokens?.cancel();
        _tokens = null;
        await _messages?.cancel();
        _messages = null;
      }
      enabled = value;
      await (await SharedPreferences.getInstance()).setBool(_key, value);
    } finally {
      busy = false;
      if (!_closed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _closed = true;
    _tokens?.cancel();
    _messages?.cancel();
    super.dispose();
  }
}

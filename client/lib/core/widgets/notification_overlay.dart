import 'package:shade/core/routing/navigation_keys.dart';
import 'package:shade/core/services/crypto_service.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shade/core/services/connection_service.dart';
import 'package:shade/main.dart';

/// Shows in-app notification SnackBars when messages arrive.
///
/// Wraps the app and listens to [ConnectionService.notifications].
/// Decryption happens on the DB side — this widget only shows
/// "New message from X".
class NotificationOverlay extends ConsumerStatefulWidget {
  final Widget child;

  const NotificationOverlay({super.key, required this.child});

  @override
  ConsumerState<NotificationOverlay> createState() =>
      _NotificationOverlayState();
}

class _NotificationOverlayState extends ConsumerState<NotificationOverlay> {
  StreamSubscription<IncomingMessage>? _sub;
  ConnectionService? _connection;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _listen());
  }

  void _listen() {
    if (!mounted) return;
    final conn = ref.read(connectionServiceProvider);
    _connection = conn;
    conn.onServerKeyConfirmation = (trust) async {
      final dialogContext = shadeNavigatorKey.currentState?.overlay?.context;
      if (!mounted || dialogContext == null) return false;
      final firstUse =
          trust.status == ServerKeyTrustStatus.newKeyRequiresConfirmation;
      return await showDialog<bool>(
              context: dialogContext,
              barrierDismissible: false,
              builder: (context) => AlertDialog(
                    title: Text(firstUse
                        ? 'Первое подключение к серверу'
                        : 'Ключ сервера не подтверждён'),
                    content: SingleChildScrollView(
                        child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text(firstUse
                              ? 'Сверьте отпечаток с владельцем сервера. Подтверждайте только знакомый сервер.'
                              : 'Отпечаток отличается от доверенного или release-сборка не содержит pin. Подключение к ключам пользователей заблокировано.'),
                          const SizedBox(height: 12),
                          Text(conn.serverUrl),
                          const SizedBox(height: 12),
                          SelectableText(trust.fingerprint),
                        ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Закрыть')),
                      if (firstUse)
                        FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Доверять серверу'))
                    ],
                  )) ??
          false;
    };
    _sub = conn.notifications.listen((msg) {
      if (!mounted) return;

      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;
      messenger.clearSnackBars();
      messenger.showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.lock_rounded,
                  size: 16, color: ShadeColors.greenAccent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Новое сообщение от ${msg.from}',
                  style: const TextStyle(color: ShadeColors.textPrimary),
                ),
              ),
            ],
          ),
          backgroundColor: ShadeColors.surfaceElevated,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          duration: const Duration(seconds: 3),
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 80),
        ),
      );
    });
  }

  @override
  void dispose() {
    _connection?.onServerKeyConfirmation = null;
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

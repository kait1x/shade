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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _listen());
  }

  void _listen() {
    final conn = ref.read(connectionServiceProvider);
    _sub = conn.notifications.listen((msg) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.lock_rounded, size: 16, color: ShadeColors.greenAccent),
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
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

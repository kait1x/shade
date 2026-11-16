import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shade/core/services/connection_service.dart';
import 'package:shade/features/auth/data/repositories/auth_notifier.dart';
import 'package:shade/main.dart';
import 'home_style.dart';

class HomeConnectionStatus extends ConsumerStatefulWidget {
  const HomeConnectionStatus({super.key});
  @override
  ConsumerState<HomeConnectionStatus> createState() =>
      _HomeConnectionStatusState();
}

class _HomeConnectionStatusState extends ConsumerState<HomeConnectionStatus> {
  StreamSubscription<bool>? _subscription;
  Timer? _timer;
  late bool _online;
  bool _connecting = true;
  @override
  void initState() {
    super.initState();
    final connection = ref.read(connectionServiceProvider);
    _online = connection.isConnected;
    _subscription = connection.connectionChanges.listen((online) {
      if (!mounted) return;
      setState(() {
        _online = online;
        _connecting = !online;
      });
      if (!online) _wait();
      if (online) _timer?.cancel();
    });
    if (!_online) _wait();
  }

  void _wait() {
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _connecting = false);
    });
  }

  void _retry() {
    final name = ref.read(authNotifierProvider).nickname;
    if (name == null) return;
    setState(() => _connecting = true);
    _wait();
    ref.read(connectionServiceProvider).connect(name);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedSize(
      duration: HomeStyle.duration(context),
      alignment: Alignment.centerLeft,
      child: Row(children: [
        Icon(_online ? Icons.lock_outline_rounded : Icons.cloud_off_outlined,
            size: 14, color: ShadeColors.textMuted),
        const SizedBox(width: 6),
        Expanded(
            child: Text(
                _online
                    ? 'Личное остаётся личным'
                    : _connecting
                        ? 'Подключаемся… История доступна'
                        : 'Нет связи · история на устройстве',
                style: const TextStyle(
                    fontSize: 12, height: 1.4, color: ShadeColors.textMuted))),
        if (!_online && !_connecting)
          IconButton(
              tooltip: 'Повторить подключение',
              onPressed: _retry,
              icon: const Icon(Icons.refresh_rounded, size: 20)),
      ]));
}

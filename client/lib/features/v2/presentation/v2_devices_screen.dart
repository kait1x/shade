/// Экран устройств native v2: ростер из проверенного каталога аккаунта
/// (локальный снимок + read-only сверка с сервером по кнопке).
///
/// Pairing-экраны существуют (их ведёт отдельная задача) — здесь только
/// навигационные точки с передачей загруженного репозитория. Recovery-экрана
/// пока нет, поэтому он не упоминается.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'package:shade/core/services/device_v2/repository.dart';
import 'package:shade/core/services/device_v2/device_history.dart';
import 'package:shade/core/theme/shade_theme.dart';
import 'package:shade/core/widgets/shade_motion.dart';
import 'package:shade/core/widgets/shade_ui.dart';
import 'package:shade/features/devices/presentation/pairing_approve_screen.dart';
import 'package:shade/features/devices/presentation/recovery_screen.dart'
    show saveNativeRecoveryFile;

import 'v2_providers.dart';

class V2DevicesScreen extends ConsumerStatefulWidget {
  const V2DevicesScreen({super.key});

  @override
  ConsumerState<V2DevicesScreen> createState() => _V2DevicesScreenState();
}

class _V2DevicesScreenState extends ConsumerState<V2DevicesScreen> {
  bool _serverRefresh = false;
  bool _copying = false;
  Future<void> _history([String? target]) async {
    final repo = ref.read(v2SessionProvider.notifier).repository;
    if (repo == null || _copying) return;
    setState(() => _copying = true);
    try {
      final count = target == null
          ? await repo.receiveDeviceHistory()
          : await repo.transferDeviceHistory(target);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(target == null
              ? 'Добавлено записей: $count'
              : 'Подготовлено записей: $count. На втором Android откройте «Получить переписку».')));
      if (target == null) await ref.read(v2SyncProvider)?.syncNow();
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Перенос прерван. Проверьте подключение и повторите — сохранённые сообщения останутся на месте.')));
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

  void _refreshFromServer() {
    setState(() => _serverRefresh = true);
    ref.invalidate(v2DevicesProvider(true));
  }

  /// Навигационная точка в существующий pairing-экран; после возврата
  /// ростер сверяется с сервером (pairing меняет каталог).
  Future<void> _openPairing(
      Widget Function(V2ChatRepository repository) builder) async {
    final repository = ref.read(v2SessionProvider.notifier).repository;
    if (repository == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Сессия v2 не готова — повторите после подключения.')));
      return;
    }
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => builder(repository)));
    if (!mounted) return;
    ref.invalidate(v2DevicesProvider(true));
    setState(() => _serverRefresh = true);
  }

  @override
  Widget build(BuildContext context) {
    final devices = ref.watch(v2DevicesProvider(_serverRefresh));
    final snapshot =
        ref.read(v2SessionProvider.notifier).repository?.accountSnapshot;
    final backup = snapshot?['recovery'];
    final genesis = snapshot?['genesis'];
    return Scaffold(
        appBar: AppBar(title: const Text('Устройства'), actions: [
          IconButton(
              tooltip: 'Сверить с сервером',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: _refreshFromServer),
          const SizedBox(width: 4),
        ]),
        body: devices.when(
            loading: () => const Center(child: ShadeLoadingIndicator()),
            error: (error, _) => SingleChildScrollView(
                child: ShadeEmptyState(
                    icon: Icons.cloud_off_rounded,
                    title: 'Не удалось открыть каталог',
                    description:
                        'Проверенный снимок каталога остаётся на устройстве. Попробуйте ещё раз.',
                    action: OutlinedButton.icon(
                        onPressed: () =>
                            ref.invalidate(v2DevicesProvider(_serverRefresh)),
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Повторить')))),
            data: (list) => ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                    children: [
                      if (list.isEmpty)
                        const ShadeEmptyState(
                            icon: Icons.devices_outlined,
                            title: 'Каталог пуст',
                            description:
                                'Устройство не зарегистрировано в device-v2.')
                      else
                        for (final device in list)
                          Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _deviceTile(context, device)),
                      const SizedBox(height: 12),
                      _pairingTile(
                          icon: Icons.add_link_rounded,
                          title: 'Подключить другое устройство',
                          subtitle:
                              'Покажем одноразовый код для входа на новом устройстве',
                          onTap: () => _openPairing((repository) =>
                              PairingApproveScreen(repository: repository))),
                      ListTile(
                          leading: const Icon(Icons.move_to_inbox_outlined),
                          title: const Text('Получить переписку'),
                          subtitle:
                              const Text('Со связанного Android-устройства'),
                          onTap: _copying ? null : () => _history()),
                      if (_copying) const LinearProgressIndicator(),
                      if (backup != null && genesis != null) ...[
                        const SizedBox(height: 10),
                        _pairingTile(
                          icon: Icons.download_outlined,
                          title: 'Сохранить файл восстановления',
                          subtitle:
                              'Поможет вернуть доступ вместе с вашей фразой',
                          onTap: () async {
                            final json = jsonEncode(
                                {'backup': backup, 'genesis': genesis});
                            String? message;
                            try {
                              if (await saveNativeRecoveryFile(json)) {
                                message = 'Файл восстановления сохранён';
                              }
                            } on PlatformException {
                              message =
                                  'Не удалось сохранить файл. Попробуйте снова.';
                            } on MissingPluginException {
                              await Clipboard.setData(
                                  ClipboardData(text: json));
                              message = 'Файл восстановления скопирован';
                            }
                            if (context.mounted && message != null) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(message)));
                            }
                          },
                        ),
                      ],
                    ])));
  }

  Future<void> _revoke(V2DeviceView device) async {
    final repo = ref.read(v2SessionProvider.notifier).repository;
    if (repo == null) return;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: const Text('Отозвать устройство?'),
                content: Text(
                    'Устройство с ключом ${device.fingerprint.substring(0, 16)}… перестанет получать новые сообщения.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Отмена')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Отозвать'))
                ]));
    if (confirmed != true || !mounted) return;
    try {
      await repo.revokeDevice(device.id);
      if (mounted) _refreshFromServer();
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Не удалось отозвать устройство. Обновите каталог и повторите.')));
    }
  }

  Widget _deviceTile(BuildContext context, V2DeviceView device) {
    final title = device.primary
        ? 'Основное устройство'
        : 'Устройство ${device.id.substring(0, device.id.length < 8 ? device.id.length : 8)}…';
    return Semantics(
        label:
            '$title${device.current ? ', это устройство' : ''}, ключ ${device.fingerprint}',
        child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
                color: ShadeColors.surfaceCard,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                    color: device.current
                        ? ShadeColors.textMuted
                        : ShadeColors.greyBorder,
                    width: device.current ? 1 : 0.5)),
            child: Row(children: [
              Icon(
                  device.primary
                      ? Icons.phone_android_rounded
                      : Icons.devices_other_rounded,
                  size: 24,
                  color: ShadeColors.textSecondary),
              const SizedBox(width: 14),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Row(children: [
                      Flexible(
                          child: Text(title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w600))),
                      if (device.current) ...[
                        const SizedBox(width: 8),
                        Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                                color: ShadeColors.surfaceElevated,
                                borderRadius: BorderRadius.circular(8)),
                            child: const Text('Это устройство',
                                style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w600,
                                    color: ShadeColors.textSecondary))),
                      ],
                    ]),
                    const SizedBox(height: 4),
                    Text('Ключ: ${device.fingerprint.substring(0, 16)}…',
                        style: const TextStyle(
                            fontSize: 12,
                            color: ShadeColors.textSecondary,
                            letterSpacing: 0.3)),
                  ])),
              if (!device.current)
                PopupMenuButton<String>(
                    tooltip: 'Действия с устройством',
                    enabled: !_copying,
                    onSelected: (action) {
                      if (action == 'history') {
                        _history(device.id);
                      } else {
                        _revoke(device);
                      }
                    },
                    itemBuilder: (_) => const [
                          PopupMenuItem(
                              value: 'history',
                              child: Text('Передать переписку на Android')),
                          PopupMenuItem(
                              value: 'revoke',
                              child: Text('Отозвать устройство'))
                        ]),
            ])));
  }

  Widget _pairingTile(
      {required IconData icon,
      required String title,
      required String subtitle,
      required VoidCallback onTap}) {
    return Material(
        color: ShadeColors.surfaceCard,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border:
                        Border.all(color: ShadeColors.greyBorder, width: 0.5)),
                child: Row(children: [
                  Icon(icon, size: 22, color: ShadeColors.violetLight),
                  const SizedBox(width: 14),
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(title,
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 3),
                        Text(subtitle,
                            style: const TextStyle(
                                fontSize: 12,
                                height: 1.4,
                                color: ShadeColors.textSecondary)),
                      ])),
                  const Icon(Icons.chevron_right_rounded,
                      color: ShadeColors.textMuted),
                ]))));
  }
}

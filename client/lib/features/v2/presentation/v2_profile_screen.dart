/// Профиль native v2: имя аккаунта, якорь (SHA-256 SPKI), genesis digest,
/// ревизия/lease каталога и устройства.
///
/// Profile API (displayName/avatar, адаптер B1/B2) в native-транспорте пока
/// отсутствует — экран честно показывает имя+ключ+устройства, без мёртвых
/// кнопок редактирования. AvatarView/тема/empty-states — импортом.
library;

import 'dart:math' show min;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:shade/core/theme/shade_theme.dart';
import 'package:shade/core/widgets/avatar_view.dart';
import 'package:shade/core/widgets/shade_motion.dart';
import 'package:shade/core/widgets/shade_ui.dart';

import 'v2_providers.dart';

class V2ProfileScreen extends ConsumerWidget {
  const V2ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(v2ProfileProvider);
    return Scaffold(
        appBar: AppBar(title: const Text('Профиль')),
        body: profile.when(
            loading: () =>
                const Center(child: ShadeLoadingIndicator()),
            error: (error, _) => SingleChildScrollView(
                child: ShadeEmptyState(
                    icon: Icons.cloud_off_rounded,
                    title: 'Не удалось открыть профиль',
                    description: 'Ключи остаются на устройстве. Попробуйте ещё раз.',
                    action: OutlinedButton.icon(
                        onPressed: () => ref.invalidate(v2ProfileProvider),
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Повторить')))),
            data: (data) {
              if (data == null) {
                return const ShadeEmptyState(
                    icon: Icons.person_off_outlined,
                    title: 'Профиль недоступен',
                    description: 'Устройство не зарегистрировано в device-v2.');
              }
              final lease =
                  DateTime.fromMillisecondsSinceEpoch(data.leaseExpiresAt);
              return ListView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                  children: [
                    Center(
                        child: AvatarView(name: data.account, size: 96)),
                    const SizedBox(height: 16),
                    Center(
                        child: Text('@${data.account}',
                            style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w700))),
                    const SizedBox(height: 28),
                    _infoCard(
                        context,
                        title: 'Ключ аккаунта (SHA-256)',
                        value: data.rootFingerprint,
                        copyLabel: 'Скопировать отпечаток ключа'),
                    const SizedBox(height: 12),
                    _infoCard(
                        context,
                        title: 'Genesis digest',
                        value: data.genesisDigest,
                        copyLabel: 'Скопировать genesis digest',
                        hint:
                            'Сверьте это значение с собеседником вне relay перед подтверждением контакта.'),
                    const SizedBox(height: 12),
                    _rowCard(
                        icon: Icons.folder_shared_outlined,
                        title: 'Каталог устройств',
                        value:
                            'Ревизия ${data.revision} · lease до ${_date(lease)}',
                        onTap: null),
                    const SizedBox(height: 12),
                    _rowCard(
                        icon: Icons.devices_outlined,
                        title: 'Устройства',
                        value: '${data.deviceCount} в каталоге',
                        onTap: () => context.push('/devices')),
                    const SizedBox(height: 12),
                    _rowCard(
                        icon: Icons.phone_android_rounded,
                        title: 'Сессия этого устройства',
                        value: data.sessionId == 'primary'
                            ? 'Основное устройство (primary)'
                            : 'Вторичное · ${data.sessionId.substring(0, min(8, data.sessionId.length))}…',
                        onTap: null),
                  ]);
            }));
  }

  static String _date(DateTime time) =>
      '${time.day.toString().padLeft(2, '0')}.${time.month.toString().padLeft(2, '0')}.${time.year} '
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

  Widget _infoCard(BuildContext context,
      {required String title,
      required String value,
      required String copyLabel,
      String? hint}) {
    return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: ShadeColors.surfaceCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: ShadeColors.greyBorder, width: 0.5)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: ShadeColors.textSecondary))),
            IconButton(
                tooltip: copyLabel,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.copy_rounded,
                    size: 18, color: ShadeColors.textSecondary),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: value));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Скопировано')));
                  }
                }),
          ]),
          SelectableText(value,
              style: const TextStyle(
                  fontSize: 13,
                  height: 1.6,
                  letterSpacing: 0.4,
                  color: ShadeColors.textPrimary)),
          if (hint != null) ...[
            const SizedBox(height: 8),
            Text(hint,
                style: const TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: ShadeColors.textMuted)),
          ],
        ]));
  }

  Widget _rowCard(
      {required IconData icon,
      required String title,
      required String value,
      VoidCallback? onTap}) {
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
                  Icon(icon, size: 22, color: ShadeColors.textSecondary),
                  const SizedBox(width: 14),
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(title,
                            style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 3),
                        Text(value,
                            style: const TextStyle(
                                fontSize: 12.5,
                                color: ShadeColors.textSecondary)),
                      ])),
                  if (onTap != null)
                    const Icon(Icons.chevron_right_rounded,
                        color: ShadeColors.textMuted),
                ]))));
  }
}
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:shade/core/services/device_v2/sync.dart';
import 'package:shade/core/theme/shade_theme.dart';
import 'package:shade/core/widgets/avatar_view.dart';
import 'package:shade/core/widgets/shade_key_identicon.dart';
import 'package:shade/core/widgets/shade_motion.dart';
import 'package:shade/core/widgets/shade_ui.dart';

import 'package:shade/features/stickers/collection.dart';
import 'v2_social.dart';
import 'v2_push.dart';
import 'v2_providers.dart';

class V2ProfileScreen extends ConsumerWidget {
  const V2ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Профиль')),
      body: ref.watch(v2ProfileProvider).when(
            loading: () => const Center(child: ShadeLoadingIndicator()),
            error: (_, __) => SingleChildScrollView(
              child: ShadeEmptyState(
                icon: Icons.cloud_off_rounded,
                title: 'Не удалось открыть профиль',
                description: 'Попробуйте ещё раз.',
                action: OutlinedButton(
                  onPressed: () => ref.invalidate(v2ProfileProvider),
                  child: const Text('Повторить'),
                ),
              ),
            ),
            data: (profile) => profile == null
                ? const ShadeEmptyState(
                    icon: Icons.person_off_outlined,
                    title: 'Профиль пока недоступен',
                    description: 'Войдите в Shade на этом устройстве.',
                  )
                : _ProfileBody(profile: profile),
          ),
    );
  }
}

class _ProfileBody extends ConsumerWidget {
  const _ProfileBody({required this.profile});

  final V2ProfileView profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final social = ref.watch(v2SocialProvider);
    final push = ref.watch(androidPushProvider);
    final remote =
        ref.watch(publicProfileProvider(profile.account)).asData?.value;
    final handle = '@${profile.account}';
    final name = profile.account;
    final visibleName = remote?.name.isNotEmpty == true
        ? remote!.name
        : name.isEmpty
            ? 'Shade'
            : name[0].toUpperCase() + name.substring(1);
    final fingerprint = profile.genesisDigest;
    final pairs = RegExp(r'[0-9a-fA-F]{2}').allMatches(fingerprint);
    final bytes =
        pairs.map((pair) => int.parse(pair.group(0)!, radix: 16)).toList();
    final preview = RegExp(r'.{1,4}')
        .allMatches(fingerprint.toUpperCase())
        .take(4)
        .map((part) => part.group(0)!)
        .join(' ');
    final lease = DateTime.fromMillisecondsSinceEpoch(profile.leaseExpiresAt);
    final localizations = MaterialLocalizations.of(context);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: [
            Center(
                child: AvatarView(
                    name: visibleName,
                    size: 108,
                    image: remote?.image,
                    frame: remote?.frame ?? AvatarFrame.none)),
            const SizedBox(height: 12),
            Text(
              visibleName,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 29,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.6),
            ),
            const SizedBox(height: 4),
            Text(handle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: ShadeColors.textSecondary, fontSize: 15)),
            ProfileEditorActions(profile.account),
            const SizedBox(height: 16),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                  child: _action(Icons.devices_outlined, 'Устройства',
                      () => context.push('/devices'),
                      primary: true)),
              const SizedBox(width: 8),
              Expanded(
                  child: _action(Icons.content_copy_rounded, 'Скопировать',
                      () => _copy(context, handle, 'Никнейм скопирован'))),
              const SizedBox(width: 8),
              Expanded(
                  child: _action(
                      Icons.key_rounded, 'Мой ключ', () => _showKey(context))),
            ]),
            const SizedBox(height: 24),
            const _SectionLabel('Информация'),
            const SizedBox(height: 6),
            ListTile(
              leading: const Icon(Icons.alternate_email_rounded),
              title: Text(handle),
              subtitle: const Text('Имя пользователя'),
              onTap: () => _copy(context, handle, 'Никнейм скопирован'),
            ),
            const Divider(height: 1, indent: 56),
            ListTile(
              leading: const Icon(Icons.phone_android_rounded),
              title: const Text('Это устройство'),
              subtitle: Text(profile.sessionId == 'primary'
                  ? 'Основное устройство'
                  : 'Подключено к аккаунту'),
            ),
            const SizedBox(height: 24),
            if (push != null)
              SwitchListTile(
                  title: const Text('Уведомления о сообщениях'),
                  value: push.enabled,
                  onChanged: push.busy
                      ? null
                      : (value) async {
                          try {
                            await push.setEnabled(value);
                          } catch (e) {
                            if (context.mounted)
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                  content: Text(e is StateError
                                      ? e.message
                                      : 'Не удалось изменить уведомления. Проверьте разрешение и доступность сервера.')));
                          }
                        }),
            const _SectionLabel('Безопасность'),
            const SizedBox(height: 10),
            Material(
              color: ShadeColors.surfaceCard,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: const BorderSide(color: ShadeColors.greyBorder),
              ),
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                contentPadding: const EdgeInsets.all(14),
                leading: bytes.isEmpty
                    ? const Icon(Icons.shield_outlined)
                    : ShadeKeyIdenticon(bytes: bytes, size: 48),
                title: const Text('Код безопасности',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(preview.isEmpty ? 'Посмотреть код' : '$preview…',
                    style: const TextStyle(
                        color: ShadeColors.textSecondary, letterSpacing: .6)),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _showKey(context),
              ),
            ),
            const SizedBox(height: 12),
            if (social != null)
              StickerCollection(
                  username: profile.account, owner: true, backend: social),
            ExpansionTile(
              title: const Text('Сведения об устройствах'),
              leading: const Icon(Icons.info_outline_rounded),
              shape: const Border(),
              collapsedShape: const Border(),
              children: [
                ListTile(
                  title: const Text('Подключённые устройства'),
                  subtitle: Text('${profile.deviceCount} в каталоге'),
                  onTap: () => context.push('/devices'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                ),
                ListTile(
                  title: Text('Ревизия ${profile.revision}'),
                  subtitle: Text(
                      'Проверено до ${localizations.formatCompactDate(lease)} · ${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(lease))}'),
                ),
              ],
            ),
            TextButton(
                onPressed: () async {
                  final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                              title: const Text('Выйти из Shade?'),
                              content: const Text(
                                  'История останется на этом телефоне. Откройте её при следующем входе в тот же аккаунт.'),
                              actions: [
                                TextButton(
                                    onPressed: () => Navigator.pop(ctx, false),
                                    child: const Text('Отмена')),
                                FilledButton(
                                    onPressed: () => Navigator.pop(ctx, true),
                                    child: const Text('Выйти'))
                              ]));
                  if (ok != true || !context.mounted) return;
                  final session = ref.read(v2SessionProvider.notifier);
                  try {
                    if (push?.enabled == true) await push!.setEnabled(false);
                    await session.logout();
                  } catch (_) {
                    if (context.mounted)
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text(
                              'Не удалось завершить сессию. Проверьте подключение.')));
                  }
                },
                child: const Text('Выйти из аккаунта')),
          ],
        ),
      ),
    );
  }

  Widget _action(IconData icon, String label, VoidCallback onPressed,
      {bool primary = false}) {
    final foreground = primary ? ShadeColors.black : ShadeColors.textPrimary;
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        foregroundColor: foreground,
        backgroundColor:
            primary ? ShadeColors.textPrimary : ShadeColors.surfaceCard,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(17),
          side: primary
              ? BorderSide.none
              : const BorderSide(color: ShadeColors.greyBorder),
        ),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 20),
        const SizedBox(height: 6),
        Text(label,
            textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
      ]),
    );
  }

  Future<void> _showKey(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheet) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Код безопасности', style: Theme.of(sheet).textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text(
              'Передайте этот код другу, чтобы он мог открыть чат с вами.'),
          const SizedBox(height: 16),
          SelectableText(profile.genesisDigest),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () =>
                _copy(sheet, profile.genesisDigest, 'Код скопирован'),
            icon: const Icon(Icons.content_copy_rounded),
            label: const Text('Скопировать код'),
          ),
          ExpansionTile(
            title: const Text('Отпечаток ключа аккаунта'),
            tilePadding: EdgeInsets.zero,
            children: [
              SelectableText(profile.rootFingerprint),
              TextButton(
                onPressed: () => _copy(
                    sheet, profile.rootFingerprint, 'Отпечаток скопирован'),
                child: const Text('Скопировать отпечаток'),
              ),
            ],
          ),
        ]),
      ),
    );
  }

  Future<void> _copy(BuildContext context, String value, String message) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text(label,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: ShadeColors.textSecondary)),
      );
}

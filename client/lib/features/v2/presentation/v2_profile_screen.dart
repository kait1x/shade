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
    final result = ref.watch(v2ProfileProvider);
    final profile = result.valueOrNull;
    return Scaffold(
      backgroundColor: ShadeColors.black,
      appBar: profile == null ? AppBar(title: const Text('Профиль')) : null,
      body: profile != null
          ? _ProfileBody(profile: profile)
          : result.when(
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
              data: (_) => const ShadeEmptyState(
                icon: Icons.person_off_outlined,
                title: 'Профиль пока недоступен',
                description: 'Войдите в Shade на этом устройстве.',
              ),
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
    final email = ref.watch(v2EmailProvider).asData?.value;
    final remote =
        ref.watch(publicProfileProvider(profile.account)).valueOrNull;
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

    final frame = remote?.frame ?? AvatarFrame.none;
    final topInset = MediaQuery.paddingOf(context).top;
    final textScaler = MediaQuery.textScalerOf(context);

    return CustomScrollView(
      slivers: [
        SliverAppBar(
          pinned: true,
          stretch: true,
          backgroundColor: ShadeColors.black,
          surfaceTintColor: Colors.transparent,
          expandedHeight:
              270 + (textScaler.scale(27) - 27) + (textScaler.scale(14) - 14),
          flexibleSpace: LayoutBuilder(builder: (context, constraints) {
            final collapsed =
                constraints.maxHeight <= topInset + kToolbarHeight + 18;
            return FlexibleSpaceBar(
              collapseMode: CollapseMode.pin,
              titlePadding: const EdgeInsetsDirectional.only(
                  start: 56, end: 16, bottom: 11),
              expandedTitleScale: 1,
              title: collapsed
                  ? Row(children: [
                      AvatarView(
                          name: visibleName,
                          size: 34,
                          image: remote?.image,
                          frame: frame),
                      const SizedBox(width: 10),
                      Expanded(
                          child: Text(visibleName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w700))),
                    ])
                  : null,
              background: ExcludeSemantics(
                excluding: collapsed,
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(24, topInset + 52, 24, 20),
                    child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          ProfileEditorControl(profile.account,
                              avatar: AvatarView(
                                  name: visibleName,
                                  size: 108,
                                  image: remote?.image,
                                  frame: frame)),
                          const SizedBox(height: 12),
                          Text(visibleName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 27,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -.6)),
                          const SizedBox(height: 6),
                          Text(handle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: ShadeColors.textSecondary,
                                  fontSize: 14)),
                        ]),
                  ),
                ),
              ),
            );
          }),
        ),
        SliverToBoxAdapter(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                    20, 4, 20, 32 + MediaQuery.paddingOf(context).bottom),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                                child: ProfileEditorControl(profile.account)),
                            const SizedBox(width: 10),
                            Expanded(
                                child: V2ProfileAction(
                                    Icons.copy_outlined,
                                    'Скопировать',
                                    () => _copy(context, handle,
                                        'Никнейм скопирован'))),
                            const SizedBox(width: 10),
                            Expanded(
                                child: V2ProfileAction(Icons.qr_code_2_rounded,
                                    'Мой ключ', () => _showKey(context))),
                          ]),
                      const SizedBox(height: 22),
                      const _SectionLabel('Информация'),
                      const SizedBox(height: 8),
                      _ProfileCard(children: [
                        if (social != null)
                          ProfileEditorControl(profile.account,
                              avatarShortcut: true),
                        ListTile(
                          leading: const Icon(Icons.alternate_email_rounded),
                          title: Text(handle),
                          subtitle: const Text('Имя пользователя'),
                          onTap: () =>
                              _copy(context, handle, 'Никнейм скопирован'),
                        ),
                        if (email != null && email.isNotEmpty)
                          ListTile(
                              leading: const Icon(Icons.mail_outline),
                              title: Text(email),
                              subtitle: const Text('Google-аккаунт')),
                        ListTile(
                          leading: const Icon(Icons.phone_android_rounded),
                          title: const Text('Это устройство'),
                          subtitle: Text(profile.sessionId == 'primary'
                              ? 'Основное устройство'
                              : 'Подключено к аккаунту'),
                        ),
                      ]),
                      const SizedBox(height: 22),
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
                          subtitle: Text(
                              preview.isEmpty ? 'Посмотреть код' : '$preview…',
                              style: const TextStyle(
                                  color: ShadeColors.textSecondary,
                                  letterSpacing: .6)),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => _showKey(context),
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (social != null)
                        StickerCollection(
                            username: profile.account,
                            owner: true,
                            backend: social),
                      const SizedBox(height: 22),
                      const _SectionLabel('Устройства и доступ'),
                      const SizedBox(height: 8),
                      _ProfileCard(children: [
                        ListTile(
                          leading: const Icon(Icons.devices_outlined),
                          title: const Text('Устройства'),
                          subtitle: const Text(
                              'Подключение, переписка и файл восстановления'),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => context.push('/devices'),
                        ),
                        ExpansionTile(
                          title: const Text('Сведения об устройствах'),
                          leading: const Icon(Icons.info_outline_rounded),
                          shape: const Border(),
                          collapsedShape: const Border(),
                          children: [
                            ListTile(
                              title: const Text('Подключённые устройства'),
                              subtitle:
                                  Text('${profile.deviceCount} в каталоге'),
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
                      ]),
                      const SizedBox(height: 16),
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
                                              onPressed: () =>
                                                  Navigator.pop(ctx, false),
                                              child: const Text('Отмена')),
                                          FilledButton(
                                              onPressed: () =>
                                                  Navigator.pop(ctx, true),
                                              child: const Text('Выйти'))
                                        ]));
                            if (ok != true || !context.mounted) return;
                            final session =
                                ref.read(v2SessionProvider.notifier);
                            try {
                              if (push?.enabled == true)
                                await push!.setEnabled(false);
                              await session.logout();
                            } catch (_) {
                              if (context.mounted)
                                ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                        content: Text(
                                            'Не удалось завершить сессию. Проверьте подключение.')));
                            }
                          },
                          child: const Text('Выйти из аккаунта')),
                    ]),
              ),
            ),
          ),
        ),
      ],
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
          Center(
              child: ShadeKeyIdenticon(
            size: 100,
            bytes: [
              for (final pair in RegExp(r'[0-9a-fA-F]{2}')
                  .allMatches(profile.genesisDigest))
                int.parse(pair.group(0)!, radix: 16)
            ],
          )),
          const SizedBox(height: 16),
          SelectableText(profile.genesisDigest,
              textAlign: TextAlign.center,
              style:
                  const TextStyle(fontFamily: 'monospace', letterSpacing: .6)),
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

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Material(
        color: ShadeColors.surfaceCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: ShadeColors.greyBorder),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              const Divider(
                  height: 1, indent: 56, color: ShadeColors.greyBorder),
            children[i],
          ],
        ]),
      );
}

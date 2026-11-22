/// Список чатов native v2: локальный поиск, «Избранное» (self-chat),
/// последние сообщения со статусами веб-контракта. AMOLED-токены темы,
/// loading/error/empty-состояния, semantics. Переиспользует AvatarView,
/// ShadeEmptyState и ShadeLoadingIndicator импортом.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:shade/core/services/device_v2/protocol.dart';
import 'package:shade/core/theme/shade_theme.dart';
import 'package:shade/core/widgets/avatar_view.dart';
import 'package:shade/core/widgets/shade_motion.dart';
import 'package:shade/core/widgets/shade_logo.dart';
import 'package:shade/features/home/presentation/widgets/home_style.dart';
import 'package:shade/core/widgets/shade_ui.dart';

import 'v2_social.dart';
import 'v2_providers.dart';

class V2ChatsScreen extends ConsumerWidget {
  const V2ChatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(v2ChatListProvider);
    final notifier = ref.read(v2ChatListProvider.notifier);
    final sync = ref.watch(v2SyncProvider);
    final account = sync?.account ?? '';

    final syncError = sync?.lastError;

    return Scaffold(
      backgroundColor: HomeStyle.background,
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: NestedScrollView(
              headerSliverBuilder: (context, scrolled) => [
                SliverAppBar(
                  pinned: true,
                  backgroundColor: HomeStyle.background,
                  toolbarHeight: 64,
                  titleSpacing: 24,
                  title: const Row(mainAxisSize: MainAxisSize.min, children: [
                    ShadeLogo(size: 28),
                    SizedBox(width: 10),
                    Text('SHADE',
                        style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 3.2)),
                  ]),
                  actions: [
                    IconButton(
                      tooltip: 'Открыть Избранное',
                      onPressed: account.isEmpty
                          ? null
                          : () => context.push('/chat/$account'),
                      icon: const Icon(Icons.bookmark_border_rounded),
                    ),
                    const SizedBox(width: 12),
                  ],
                  bottom: PreferredSize(
                    preferredSize: const Size.fromHeight(1),
                    child: AnimatedContainer(
                      duration: HomeStyle.duration(context),
                      height: 1,
                      color: scrolled ? HomeStyle.border : Colors.transparent,
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 22, 24, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Сообщения',
                            style: TextStyle(
                                fontSize: 34,
                                height: 1.15,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -1.3)),
                        if (syncError != null)
                          TextButton.icon(
                            onPressed: notifier.refresh,
                            icon:
                                const Icon(Icons.cloud_off_outlined, size: 18),
                            label: Text(syncError),
                          ),
                        const SizedBox(height: 20),
                        TextField(
                          key: const Key('v2-chat-search'),
                          onChanged: notifier.setQuery,
                          textInputAction: TextInputAction.search,
                          decoration: InputDecoration(
                            hintText: 'Поиск в переписках',
                            filled: true,
                            fillColor: HomeStyle.surface,
                            prefixIcon:
                                const Icon(Icons.search_rounded, size: 21),
                            contentPadding:
                                const EdgeInsets.symmetric(vertical: 14),
                            border: HomeStyle.searchBorder,
                            enabledBorder: HomeStyle.searchBorder,
                            focusedBorder: HomeStyle.searchBorder.copyWith(
                              borderSide: const BorderSide(
                                  color: ShadeColors.textMuted),
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        Wrap(spacing: 8, children: [
                          _filter('Все чаты', false, state.savedOnly,
                              notifier.filterSaved),
                          _filter('Избранное', true, state.savedOnly,
                              notifier.filterSaved),
                        ]),
                      ],
                    ),
                  ),
                ),
              ],
              body: _content(context, state, notifier, account),
            ),
          ),
        ),
      ),
      floatingActionButton: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
        child: FloatingActionButton.extended(
          tooltip: 'Новый чат',
          elevation: 0,
          backgroundColor: HomeStyle.ink,
          foregroundColor: Colors.black,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          onPressed: () => _showNewChatDialog(context, ref),
          icon: const Icon(Icons.edit_outlined, size: 20),
          label: const Text('Написать',
              style: TextStyle(fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }

  Widget _filter(
      String label, bool saved, bool savedOnly, ValueChanged<bool> onChanged) {
    final selected = savedOnly == saved;
    return ChoiceChip(
      key: ValueKey(saved ? 'v2-saved-filter' : 'v2-all-filter'),
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      selectedColor: HomeStyle.ink,
      backgroundColor: HomeStyle.surface,
      labelStyle: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: selected ? Colors.black : ShadeColors.textSecondary,
      ),
      side: BorderSide(color: selected ? Colors.transparent : HomeStyle.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      onSelected: (_) => onChanged(saved),
    );
  }

  Widget _content(BuildContext context, V2ChatListState state,
      V2ChatListNotifier notifier, String account) {
    if (state.loading && state.chats.isEmpty) {
      return const Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox.square(
            dimension: 24, child: ShadeLoadingIndicator(strokeWidth: 2)),
        SizedBox(height: 16),
        Text('Открываем чаты',
            style: TextStyle(color: ShadeColors.textSecondary)),
      ]));
    }
    if (state.error != null && state.chats.isEmpty) {
      return SingleChildScrollView(
          child: ShadeEmptyState(
              icon: Icons.cloud_off_rounded,
              title: 'Не удалось открыть чаты',
              description:
                  'История остаётся на устройстве. Проверьте подключение и попробуйте ещё раз.',
              action: OutlinedButton.icon(
                  onPressed: notifier.refresh,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Повторить'))));
    }
    final chats = state.filtered;
    if (chats.isEmpty) {
      return SingleChildScrollView(
          child: ShadeEmptyState(
              icon: state.query.trim().isEmpty
                  ? Icons.chat_bubble_outline_rounded
                  : Icons.search_off_rounded,
              title: state.query.trim().isEmpty
                  ? 'Начните разговор'
                  : 'Ничего не найдено',
              description: state.query.trim().isEmpty
                  ? 'Найдите собеседника по нику или откройте «Избранное» — личные заметки, синхронизированные между вашими устройствами.'
                  : 'Попробуйте другой запрос: поиск идёт по нику и последнему сообщению.'));
    }
    return ListView.builder(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding:
            EdgeInsets.only(bottom: 76 + MediaQuery.paddingOf(context).bottom),
        itemCount: chats.length,
        itemBuilder: (context, index) {
          final chat = chats[index];
          return _ChatTile(
              key: ValueKey(chat.peer),
              chat: chat,
              isSelf: chat.peer == account,
              onTap: () => context.push('/chat/${chat.peer}'));
        });
  }

  /// Добавление контакта: явная сверка genesis digest вне relay.
  Future<void> _showNewChatDialog(BuildContext context, WidgetRef ref) async {
    var enteredAccount = '';
    var enteredDigest = '';
    var error = '';
    var busy = false;
    final peer = await showDialog<String>(
        context: context,
        builder: (ctx) => StatefulBuilder(
            builder: (ctx, setDialogState) => AlertDialog(
                  title: const Text('Новый чат'),
                  scrollable: true,
                  content: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                            'Введите ник друга. Если вы уже обменялись кодами безопасности, здесь можно сразу сверить ключ.',
                            style: TextStyle(
                                fontSize: 13,
                                color: ShadeColors.textSecondary,
                                height: 1.5)),
                        const SizedBox(height: 16),
                        TextField(
                            key: const Key('new-chat-account'),
                            onChanged: (text) => enteredAccount = text,
                            autocorrect: false,
                            decoration: const InputDecoration(
                                labelText: 'Никнейм друга',
                                hintText: '@никнейм')),
                        const SizedBox(height: 12),
                        TextField(
                            key: const Key('new-chat-digest'),
                            onChanged: (text) => enteredDigest = text,
                            autocorrect: false,
                            maxLines: 2,
                            decoration: const InputDecoration(
                                labelText: 'Код безопасности (необязательно)',
                                hintText: 'Вставьте скопированный код')),
                        if (error.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(error,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(ctx).colorScheme.error)),
                        ],
                      ]),
                  actions: [
                    TextButton(
                        onPressed: busy ? null : () => Navigator.pop(ctx),
                        child: const Text('Отмена')),
                    FilledButton(
                        key: const Key('new-chat-submit'),
                        onPressed: busy
                            ? null
                            : () async {
                                final peer = enteredAccount
                                    .trim()
                                    .toLowerCase()
                                    .replaceFirst(RegExp(r'^@'), '');
                                final digest = enteredDigest
                                    .toLowerCase()
                                    .replaceAll(RegExp(r'\s+'), '');
                                if (!accountPattern.hasMatch(peer)) {
                                  setDialogState(() => error =
                                      'Проверьте никнейм. Можно использовать латинские буквы, цифры и подчёркивания.');
                                  return;
                                }
                                if (digest.isNotEmpty &&
                                    !hex64Pattern.hasMatch(digest)) {
                                  setDialogState(() => error =
                                      'Вставьте код целиком. Он состоит из 64 символов.');
                                  return;
                                }
                                setDialogState(() {
                                  busy = true;
                                  error = '';
                                });
                                try {
                                  if (peer != ref.read(v2SyncProvider)?.account)
                                    await ref
                                        .read(v2ChatListProvider.notifier)
                                        .addContact(peer,
                                            digest.isEmpty ? null : digest);
                                  if (ctx.mounted) Navigator.pop(ctx, peer);
                                } catch (e) {
                                  if (!ctx.mounted) return;
                                  setDialogState(() {
                                    busy = false;
                                    error = '$e'.contains('mismatch')
                                        ? 'Код не совпал. Попросите друга скопировать его ещё раз.'
                                        : 'Не удалось подтвердить контакт. Проверьте никнейм и подключение к интернету.';
                                  });
                                }
                              },
                        child: busy
                            ? const SizedBox.square(
                                dimension: 18,
                                child: ShadeLoadingIndicator(strokeWidth: 2))
                            : const Text('Открыть чат')),
                  ],
                )));
    if (context.mounted && peer != null) context.push('/chat/$peer');
  }
}

class _ChatTile extends ConsumerWidget {
  final V2ChatSummary chat;
  final bool isSelf;
  final VoidCallback onTap;

  const _ChatTile(
      {super.key,
      required this.chat,
      required this.isSelf,
      required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = isSelf
        ? null
        : ref.watch(publicProfileProvider(chat.peer)).asData?.value;
    final title = isSelf
        ? 'Избранное'
        : (profile?.name.isNotEmpty == true ? profile!.name : '@${chat.peer}');
    final preview = chat.lastText == null
        ? (isSelf ? 'Ваши личные заметки' : 'Нет сообщений')
        : chat.lastMine && !isSelf
            ? 'Вы: ${chat.lastText}'
            : chat.lastText!;
    return Semantics(
        label: 'Чат $title. ${chat.lastText ?? 'Нет сообщений'}',
        button: true,
        child: InkWell(
            onTap: onTap,
            child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                child: Row(children: [
                  AvatarView(
                      name: chat.peer,
                      size: 52,
                      saved: isSelf,
                      image: profile?.image,
                      frame: profile?.frame ?? AvatarFrame.none),
                  const SizedBox(width: 14),
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Row(children: [
                          Expanded(
                              child: Text(title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600))),
                          if (chat.unread > 0)
                            Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: Badge(label: Text('${chat.unread}'))),
                          if (chat.lastAt != null)
                            Text(_formatTime(chat.lastAt!),
                                style: const TextStyle(
                                    fontSize: 12,
                                    color: ShadeColors.textSecondary)),
                        ]),
                        const SizedBox(height: 4),
                        Row(children: [
                          if (chat.lastMine && chat.lastStatus != null) ...[
                            _statusIcon(chat.lastStatus!),
                            const SizedBox(width: 5),
                          ],
                          if (!chat.confirmed) ...[
                            const Tooltip(
                                message: 'Код безопасности пока не сверен',
                                child: Icon(Icons.gpp_maybe_outlined,
                                    size: 15,
                                    color: ShadeColors.textSecondary)),
                            const SizedBox(width: 5),
                          ],
                          Expanded(
                              child: Text(preview,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 13.5,
                                      color: ShadeColors.textSecondary))),
                        ]),
                      ])),
                ]))));
  }

  static Widget _statusIcon(String status) {
    final icon = switch (status) {
      'queued' => Icons.schedule_rounded,
      'blocked' => Icons.error_outline_rounded,
      'delivered' || 'read' => Icons.done_all_rounded,
      'retracted' => Icons.block_rounded,
      _ => Icons.done_rounded,
    };
    final color = status == 'blocked'
        ? const Color(0xFFEF4444)
        : status == 'read'
            ? ShadeColors.greenAccent
            : ShadeColors.textMuted;
    return Icon(icon, size: 15, color: color);
  }

  static String _formatTime(int ms) {
    final time = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    if (time.year == now.year &&
        time.month == now.month &&
        time.day == now.day) {
      return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    }
    return '${time.day.toString().padLeft(2, '0')}.${time.month.toString().padLeft(2, '0')}.${time.year % 100}';
  }
}

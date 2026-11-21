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
import 'package:shade/core/widgets/shade_ui.dart';

import 'v2_providers.dart';

class V2ChatsScreen extends ConsumerWidget {
  const V2ChatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(v2ChatListProvider);
    final notifier = ref.read(v2ChatListProvider.notifier);
    final account = ref.watch(v2SyncProvider)?.account ?? '';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Чаты'),
        actions: [
          IconButton(
              tooltip: 'Новый чат',
              icon: const Icon(Icons.add_rounded),
              onPressed: () => _showNewChatDialog(context, ref)),
          IconButton(
              tooltip: 'Устройства',
              icon: const Icon(Icons.devices_outlined),
              onPressed: () => context.push('/devices')),
          IconButton(
              tooltip: 'Профиль',
              icon: const Icon(Icons.person_outline_rounded),
              onPressed: () => context.push('/profile')),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(children: [
        Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
                key: const Key('v2-chat-search'),
                onChanged: notifier.setQuery,
                style: const TextStyle(fontSize: 15),
                decoration: const InputDecoration(
                    hintText: 'Поиск',
                    prefixIcon: Icon(Icons.search_rounded,
                        color: ShadeColors.textMuted, size: 22),
                    isDense: true,
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 16, vertical: 12)))),
        Expanded(child: _content(context, ref, state, notifier, account)),
      ]),
    );
  }

  Widget _content(BuildContext context, WidgetRef ref, V2ChatListState state,
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
                  ? 'Добавьте собеседника, сверив его genesis digest, или откройте «Избранное» — личные заметки, синхронизированные между вашими устройствами.'
                  : 'Попробуйте другой запрос: поиск идёт по имени аккаунта.'));
    }
    return ListView.builder(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: chats.length,
        itemBuilder: (context, index) {
          final chat = chats[index];
          return _ChatTile(
              chat: chat,
              isSelf: chat.peer == account,
              onTap: () => context.push('/chat/${chat.peer}'));
        });
  }

  /// Добавление контакта: явная сверка genesis digest вне relay.
  Future<void> _showNewChatDialog(BuildContext context, WidgetRef ref) async {
    final accountController = TextEditingController();
    final digestController = TextEditingController();
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
                            'Попросите друга скопировать код из профиля Shade и передать вам лично или через другой мессенджер.',
                            style: TextStyle(
                                fontSize: 13,
                                color: ShadeColors.textSecondary,
                                height: 1.5)),
                        const SizedBox(height: 16),
                        TextField(
                            key: const Key('new-chat-account'),
                            controller: accountController,
                            autocorrect: false,
                            decoration: const InputDecoration(
                                labelText: 'Никнейм друга',
                                hintText: '@никнейм')),
                        const SizedBox(height: 12),
                        TextField(
                            key: const Key('new-chat-digest'),
                            controller: digestController,
                            autocorrect: false,
                            maxLines: 2,
                            decoration: const InputDecoration(
                                labelText: 'Код из профиля друга',
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
                                final peer = accountController.text
                                    .trim()
                                    .toLowerCase()
                                    .replaceFirst(RegExp(r'^@'), '');
                                final digest = digestController.text
                                    .toLowerCase()
                                    .replaceAll(RegExp(r'\s+'), '');
                                if (!accountPattern.hasMatch(peer)) {
                                  setDialogState(() => error =
                                      'Проверьте никнейм. Можно использовать латинские буквы, цифры и подчёркивания.');
                                  return;
                                }
                                if (!hex64Pattern.hasMatch(digest)) {
                                  setDialogState(() => error =
                                      'Вставьте код целиком. Он состоит из 64 символов.');
                                  return;
                                }
                                setDialogState(() {
                                  busy = true;
                                  error = '';
                                });
                                try {
                                  await ref
                                      .read(v2ChatListProvider.notifier)
                                      .addContact(peer, digest);
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
    accountController.dispose();
    digestController.dispose();
    if (context.mounted && peer != null) context.push('/chat/$peer');
  }
}

class _ChatTile extends StatelessWidget {
  final V2ChatSummary chat;
  final bool isSelf;
  final VoidCallback onTap;

  const _ChatTile(
      {required this.chat, required this.isSelf, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final title = isSelf ? 'Избранное' : '@${chat.peer}';
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
                  AvatarView(name: chat.peer, size: 52, saved: isSelf),
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
                                message: 'Genesis digest не сверен',
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

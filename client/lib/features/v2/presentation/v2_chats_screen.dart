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
import 'package:shade/core/widgets/shade_chat_list.dart';
import 'package:shade/core/widgets/avatar_view.dart';
import 'package:shade/core/widgets/shade_motion.dart';
import 'package:shade/features/home/presentation/widgets/home_style.dart';
import 'package:shade/core/widgets/shade_ui.dart';

import 'v2_social.dart';
import 'v2_providers.dart';

class V2ChatsScreen extends ConsumerStatefulWidget {
  const V2ChatsScreen({super.key});

  @override
  ConsumerState<V2ChatsScreen> createState() => _V2ChatsScreenState();
}

class _V2ChatsScreenState extends ConsumerState<V2ChatsScreen> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _compactCompose = ValueNotifier(false);
  bool _searchVisible = true;
  bool _navigating = false;

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    _compactCompose.dispose();
    super.dispose();
  }

  void _toggleSearch() {
    ShadeMotion.selection(context);
    final show = !_searchVisible;
    setState(() => _searchVisible = show);
    if (show) {
      _searchFocus.requestFocus();
    } else {
      _searchFocus.unfocus();
      _search.clear();
      ref.read(v2ChatListProvider.notifier).setQuery('');
    }
  }

  bool _handleScroll(ScrollNotification event) {
    final compact = shadeComposeCompact(event);
    if (compact != null) _compactCompose.value = compact;
    return false;
  }

  Future<void> _openChat(String peer) async {
    if (_navigating) return;
    _navigating = true;
    _searchFocus.unfocus();
    ShadeMotion.selection(context);
    try {
      await context.push('/chat/$peer');
    } finally {
      _navigating = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      backgroundColor: context.shadeColor(ShadeColors.black),
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(children: [
              Expanded(
                child: NotificationListener<ScrollNotification>(
                  onNotification: _handleScroll,
                  child: CustomScrollView(
                    key: const PageStorageKey('v2-chats-scroll'),
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    slivers: [
                      ShadeChatsAppBar(
                        searchVisible: _searchVisible,
                        onToggleSearch: _toggleSearch,
                      ),
                      SliverToBoxAdapter(
                        child: Consumer(builder: (context, ref, _) {
                          final savedOnly = ref.watch(v2ChatListProvider
                              .select((value) => value.savedOnly));
                          final actions = ref.read(v2ChatListProvider.notifier);
                          return ShadeChatsHeader(
                            searchVisible: _searchVisible,
                            controller: _search,
                            focusNode: _searchFocus,
                            onQueryChanged: actions.setQuery,
                            savedOnly: savedOnly,
                            onFilterChanged: actions.filterSaved,
                          );
                        }),
                      ),
                      Consumer(builder: (context, ref, _) {
                        final state = ref.watch(v2ChatListProvider);
                        final sync = ref.watch(v2SyncProvider);
                        return _content(
                            state,
                            ref.read(v2ChatListProvider.notifier),
                            sync?.account ?? '',
                            sync?.lastError);
                      }),
                    ],
                  ),
                ),
              ),
              if (!keyboardOpen)
                Padding(
                  padding: EdgeInsets.fromLTRB(16, 6, 16, bottomInset + 6),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: ValueListenableBuilder<bool>(
                      valueListenable: _compactCompose,
                      builder: (context, compact, _) => ShadeComposeButton(
                        compact: compact,
                        onPressed: () => _startNewChat(context, ref),
                      ),
                    ),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _content(V2ChatListState state, V2ChatListNotifier notifier,
      String account, String? syncError) {
    if (state.loading && state.chats.isEmpty) {
      return SliverToBoxAdapter(
          child: Padding(
        padding: EdgeInsets.all(24),
        child: Column(children: [
          SizedBox.square(dimension: 22, child: ShadeLoadingIndicator()),
          SizedBox(height: 12),
          Text('Открываем чаты',
              style: TextStyle(
                  color: context.shadeColor(ShadeColors.textSecondary))),
        ]),
      ));
    }
    if (state.error != null && state.chats.isEmpty) {
      return SliverToBoxAdapter(
          child: ShadeEmptyState(
        icon: Icons.cloud_off_rounded,
        title: 'Не удалось открыть чаты',
        description: 'Переписки сохранены на устройстве.',
        action: OutlinedButton(
            onPressed: notifier.refresh, child: const Text('Повторить')),
      ));
    }
    final chats = state.filtered;
    final indices = <String, int>{
      for (var i = 0; i < chats.length; i++) chats[i].peer: i
    };

    return SliverMainAxisGroup(slivers: [
      if (syncError != null)
        SliverToBoxAdapter(
            child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: notifier.refresh,
              icon: const Icon(Icons.cloud_off_outlined, size: 18),
              label: Text(syncError),
            ),
          ),
        )),
      if (chats.isEmpty)
        SliverToBoxAdapter(
            child: ShadeEmptyState(
          icon: state.query.trim().isEmpty
              ? Icons.chat_bubble_outline_rounded
              : Icons.search_off_rounded,
          title: state.query.trim().isNotEmpty
              ? 'Ничего не найдено'
              : state.savedOnly
                  ? 'Пока нет личных заметок'
                  : 'Начните разговор',
          description: state.query.trim().isNotEmpty
              ? 'Попробуйте другой никнейм или фрагмент сообщения.'
              : state.savedOnly
                  ? 'Здесь будет ваша переписка с собой.'
                  : 'Найдите собеседника по никнейму.',
        ))
      else
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final chat = chats[index];
              return _ChatTile(
                key: ValueKey(chat.peer),
                chat: chat,
                isSelf: chat.peer == account,
                onOpen: _openChat,
              );
            },
            childCount: chats.length,
            findChildIndexCallback: (key) =>
                indices[(key as ValueKey<String>).value],
          ),
        ),
      const SliverToBoxAdapter(child: SizedBox(height: 8)),
    ]);
  }

  Future<void> _startNewChat(BuildContext context, WidgetRef ref) async {
    if (_navigating) return;
    _navigating = true;
    _searchFocus.unfocus();
    ShadeMotion.selection(context);
    String? peer;
    try {
      peer = await _showNewChatDialog(context, ref);
    } finally {
      _navigating = false;
    }
    if (mounted && peer != null) await _openChat(peer);
  }

  /// Добавление контакта: явная сверка genesis digest вне relay.
  Future<String?> _showNewChatDialog(
      BuildContext context, WidgetRef ref) async {
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
                        Text(
                            'Введите ник друга. Если вы уже обменялись кодами безопасности, здесь можно сразу сверить ключ.',
                            style: TextStyle(
                                fontSize: 13,
                                color: context
                                    .shadeColor(ShadeColors.textSecondary),
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
                                if (busy) return;
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
                                  if (peer !=
                                      ref.read(v2SyncProvider)?.account) {
                                    await ref
                                        .read(v2ChatListProvider.notifier)
                                        .addContact(peer,
                                            digest.isEmpty ? null : digest);
                                  }
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
    return peer;
  }
}

class _ChatTile extends StatefulWidget {
  const _ChatTile(
      {super.key,
      required this.chat,
      required this.isSelf,
      required this.onOpen});

  final V2ChatSummary chat;
  final bool isSelf;
  final ValueChanged<String> onOpen;

  @override
  State<_ChatTile> createState() => _ChatTileState();
}

class _ChatTileState extends State<_ChatTile> {
  late Widget _row = _buildRow(widget.chat, widget.isSelf);

  // Sync produces a fresh summary for every peer. Keep the existing widget for
  // rows whose rendered values did not change; avatar updates listen separately.
  static Object _displayedValues(V2ChatSummary chat, bool isSelf) => (
        chat.peer,
        isSelf,
        chat.confirmed,
        chat.lastAt,
        chat.lastText,
        chat.lastMine,
        chat.lastStatus,
        chat.unread,
      );

  @override
  void didUpdateWidget(covariant _ChatTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_displayedValues(oldWidget.chat, oldWidget.isSelf) !=
        _displayedValues(widget.chat, widget.isSelf)) {
      _row = _buildRow(widget.chat, widget.isSelf);
    }
  }

  @override
  Widget build(BuildContext context) => _row;

  Widget _buildRow(V2ChatSummary chat, bool isSelf) =>
      Consumer(builder: (context, ref, _) {
        final profile = isSelf
            ? null
            : ref.watch(publicProfileProvider(chat.peer)).valueOrNull;
        final title = isSelf
            ? 'Избранное'
            : profile?.name.isNotEmpty == true
                ? profile!.name
                : '@${chat.peer}';
        final preview = chat.lastText == null
            ? (isSelf ? 'Ваши личные заметки' : 'Нет сообщений')
            : chat.lastMine && !isSelf
                ? 'Вы: ${chat.lastText}'
                : chat.lastText!;
        return ShadeChatRow(
          title: title,
          preview: preview,
          time: chat.lastAt,
          status: chat.lastMine ? chat.lastStatus : null,
          unreadCount: chat.unread,
          confirmed: chat.confirmed,
          avatar: AvatarView(
            name: title,
            size: 46,
            saved: isSelf,
            image: profile?.image,
            frame: profile?.frame ?? AvatarFrame.none,
          ),
          onOpen: () => widget.onOpen(chat.peer),
        );
      });
}

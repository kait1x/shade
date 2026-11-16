import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shade/features/chats/data/repositories/chat_repository.dart';
import 'package:shade/features/chats/presentation/screens/chat_screen.dart';
import 'package:shade/features/auth/data/repositories/auth_notifier.dart';
import 'package:shade/core/widgets/shade_ui.dart';
import 'package:shade/main.dart';
import 'home_style.dart';

final conversationsProvider = FutureProvider<List<Conversation>>(
    (ref) => ref.watch(chatRepositoryProvider).getDecryptedConversations());

class ChatListView extends ConsumerStatefulWidget {
  final String query;
  final bool savedOnly;
  const ChatListView({super.key, this.query = '', this.savedOnly = false});
  @override
  ConsumerState<ChatListView> createState() => _ChatListViewState();
}

class _ChatListViewState extends ConsumerState<ChatListView> {
  Set<int>? _knownIds;
  @override
  Widget build(BuildContext context) {
    final chats = ref.watch(conversationsProvider);
    final nickname = ref.watch(authNotifierProvider).nickname;
    return chats.when(
        loading: () =>
            const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (_, __) => _scrollableState(ShadeEmptyState(
            icon: Icons.cloud_off_rounded,
            title: 'Не получилось открыть чаты',
            description:
                'Попробуйте ещё раз. Сохранённая история останется на устройстве.',
            action: OutlinedButton(
                onPressed: () => ref.invalidate(conversationsProvider),
                child: const Text('Повторить')))),
        data: (all) {
          final ids = all.map((chat) => chat.id).toSet();
          final added =
              _knownIds == null ? <int>{} : ids.difference(_knownIds!);
          _knownIds = ids;
          final search = widget.query.trim().toLowerCase();
          final visible = all
              .where((c) =>
                  (!widget.savedOnly ||
                      c.name == 'Избранное' ||
                      c.name == nickname) &&
                  (search.isEmpty ||
                      c.name.toLowerCase().contains(search) ||
                      (c.lastMessage?.encryptedContent
                              .toLowerCase()
                              .contains(search) ??
                          false)))
              .toList();
          if (visible.isEmpty) {
            return _scrollableState(ShadeEmptyState(
                icon: search.isNotEmpty
                    ? Icons.search_off_rounded
                    : Icons.chat_bubble_outline_rounded,
                title: search.isNotEmpty
                    ? 'Ничего не нашлось'
                    : 'Здесь начнётся общение',
                description: search.isNotEmpty
                    ? 'Попробуйте другое имя или слово\nиз последнего сообщения.'
                    : 'Найдите друга по никнейму\nи отправьте первое сообщение.',
                action: search.isEmpty
                    ? OutlinedButton(
                        onPressed: () async {
                          await context.push('/search');
                          if (mounted) ref.invalidate(conversationsProvider);
                        },
                        child: const Text('Найти собеседника'))
                    : null));
          }
          return ListView.separated(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 100),
              itemCount: visible.length,
              separatorBuilder: (_, __) => const Divider(
                  height: 1,
                  indent: 80,
                  endIndent: 12,
                  color: HomeStyle.border),
              itemBuilder: (context, i) => TweenAnimationBuilder<double>(
                  key: ValueKey(visible[i].id),
                  tween: Tween(
                      begin: added.contains(visible[i].id) ? 0 : 1, end: 1),
                  duration: HomeStyle.duration(context),
                  builder: (_, value, child) => Opacity(
                      opacity: value,
                      child: Transform.translate(
                          offset: Offset(0, 8 * (1 - value)), child: child)),
                  child: _ChatTile(conversation: visible[i])));
        });
  }

  Widget _scrollableState(Widget child) => LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: child)));
}

class _ChatTile extends ConsumerWidget {
  final Conversation conversation;
  const _ChatTile({required this.conversation});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authNotifierProvider);
    final self =
        conversation.name == auth.nickname || conversation.name == 'Избранное';
    final key = self ? auth.publicKey : conversation.publicKey;
    final message = conversation.lastMessage;
    final preview = message == null
        ? (self
            ? 'Ссылки, заметки и важное — для себя'
            : 'Отправьте первое сообщение')
        : message.encryptedContent;
    final unread = self ? 0 : conversation.unreadCount;
    return ListTile(
        minVerticalPadding: 18,
        horizontalTitleGap: 15,
        minLeadingWidth: 54,
        hoverColor: HomeStyle.surface,
        splashColor: HomeStyle.border,
        titleAlignment: ListTileTitleAlignment.center,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        leading: ShadeAvatar(
            name: conversation.name,
            username: conversation.name,
            saved: self,
            size: 54),
        title: Row(children: [
          Expanded(
              child: Text(self ? 'Избранное' : conversation.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 16,
                      height: 1.25,
                      letterSpacing: -.2,
                      fontWeight: FontWeight.w700))),
          if (message != null) ...[
            const SizedBox(width: 10),
            Text(_time(message.timestamp),
                style:
                    const TextStyle(fontSize: 11, color: ShadeColors.textMuted))
          ]
        ]),
        subtitle: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(children: [
              if (message?.isOutgoing == true && !self) ...[
                Icon(
                    message!.status == 'read' || message.status == 'delivered'
                        ? Icons.done_all_rounded
                        : (message.status == 'pending' ||
                                message.status == 'queued')
                            ? Icons.schedule_rounded
                            : Icons.done_rounded,
                    size: 16,
                    color: message.status == 'read'
                        ? HomeStyle.ink
                        : ShadeColors.textMuted),
                const SizedBox(width: 4),
              ],
              Expanded(
                  child: Text(preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 14,
                          height: 1.4,
                          color: unread > 0
                              ? HomeStyle.ink
                              : ShadeColors.textSecondary))),
              const SizedBox(width: 10),
              AnimatedSwitcher(
                  duration: HomeStyle.duration(context),
                  transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: ScaleTransition(scale: animation, child: child)),
                  child: unread == 0
                      ? const SizedBox.shrink(key: ValueKey(0))
                      : Semantics(
                          label: 'Непрочитанных сообщений: $unread',
                          key: ValueKey(unread),
                          child: Container(
                              constraints: const BoxConstraints(minWidth: 22),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                  color: HomeStyle.ink,
                                  borderRadius: BorderRadius.circular(8)),
                              child: Text(unread > 99 ? '99+' : '$unread',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      color: Colors.black,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700))))),
            ])),
        onTap: () async {
          await context.push('/chat/${conversation.id}',
              extra: key == null
                  ? null
                  : ChatScreenArgs(
                      conversationName: self ? 'Избранное' : conversation.name,
                      recipientPublicKey: key,
                      recipientUsername:
                          self ? (auth.nickname ?? '') : conversation.name));
          if (context.mounted) ref.invalidate(conversationsProvider);
        });
  }

  String _time(DateTime value) {
    final now = DateTime.now();
    if (value.year == now.year &&
        value.month == now.month &&
        value.day == now.day) {
      return '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
    }
    return '${value.day.toString().padLeft(2, '0')}.${value.month.toString().padLeft(2, '0')}';
  }
}

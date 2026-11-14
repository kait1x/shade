import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shade/features/chats/data/repositories/chat_repository.dart';
import 'package:shade/features/chats/presentation/screens/chat_screen.dart';
import 'package:shade/features/auth/data/repositories/auth_notifier.dart';
import 'package:shade/core/widgets/shade_ui.dart';
import 'package:shade/main.dart';

final conversationsProvider = FutureProvider<List<Conversation>>(
    (ref) => ref.watch(chatRepositoryProvider).getDecryptedConversations());

class ChatListView extends ConsumerWidget {
  final String query;
  final bool savedOnly;
  const ChatListView({super.key, this.query = '', this.savedOnly = false});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chats = ref.watch(conversationsProvider);
    final nickname = ref.watch(authNotifierProvider).nickname;
    return chats.when(
        loading: () =>
            const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (_, __) => ShadeEmptyState(
            icon: Icons.cloud_off_rounded,
            title: 'Не получилось открыть чаты',
            description:
                'Попробуйте ещё раз. Сохранённая история останется на устройстве.',
            action: OutlinedButton(
                onPressed: () => ref.invalidate(conversationsProvider),
                child: const Text('Повторить'))),
        data: (all) {
          final search = query.trim().toLowerCase();
          final visible = all
              .where((c) =>
                  (!savedOnly || c.name == 'Избранное' || c.name == nickname) &&
                  (search.isEmpty ||
                      c.name.toLowerCase().contains(search) ||
                      (c.lastMessage?.encryptedContent
                              .toLowerCase()
                              .contains(search) ??
                          false)))
              .toList();
          if (visible.isEmpty) {
            return ShadeEmptyState(
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
                        onPressed: () => context.push('/search'),
                        child: const Text('Найти собеседника'))
                    : null);
          }
          return ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 100),
              itemCount: visible.length,
              separatorBuilder: (_, __) => const Divider(
                  height: 1,
                  indent: 80,
                  endIndent: 12,
                  color: Color(0xFF252525)),
              itemBuilder: (_, i) => _ChatTile(conversation: visible[i]));
        });
  }
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
    return ListTile(
        minVerticalPadding: 17,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        leading: ShadeAvatar(name: conversation.name, saved: self, size: 54),
        title: Row(children: [
          Expanded(
              child: Text(self ? 'Избранное' : conversation.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700))),
          if (message != null) ...[
            const SizedBox(width: 10),
            Text(_time(message.timestamp),
                style:
                    const TextStyle(fontSize: 11, color: ShadeColors.textMuted))
          ]
        ]),
        subtitle: Padding(
            padding: const EdgeInsets.only(top: 7),
            child: Text(preview,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: ShadeColors.textSecondary))),
        onTap: key == null
            ? null
            : () async {
                await context.push('/chat/${conversation.id}',
                    extra: ChatScreenArgs(
                        conversationName:
                            self ? 'Избранное' : conversation.name,
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

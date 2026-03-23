import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:shade/features/chats/data/repositories/chat_repository.dart';
import 'package:shade/features/chats/presentation/screens/chat_screen.dart';
import 'package:shade/features/auth/data/repositories/auth_notifier.dart';
import 'package:shade/main.dart';

/// Loads all conversations with decrypted last message preview.
final conversationsProvider = FutureProvider<List<Conversation>>((ref) async {
  final repo = ref.watch(chatRepositoryProvider);
  return repo.getDecryptedConversations();
});

/// Widget that displays the list of conversations.
class ChatListView extends ConsumerWidget {
  const ChatListView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conversationsAsync = ref.watch(conversationsProvider);

    return conversationsAsync.when(
      loading: () => const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      ),
      error: (error, stack) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Ошибка загрузки чатов',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      ),
      data: (conversations) {
        if (conversations.isEmpty) {
          return _EmptyState();
        }

        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: conversations.length,
          separatorBuilder: (_, __) =>
              const Divider(height: 1, indent: 76, endIndent: 16),
          itemBuilder: (context, index) {
            final conv = conversations[index];
            return _ChatTile(conversation: conv);
          },
        );
      },
    );
  }
}

class _ChatTile extends ConsumerWidget {
  final Conversation conversation;

  const _ChatTile({required this.conversation});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authNotifierProvider);
    final myPublicKey = authState.publicKey;
    final myNickname = authState.nickname;

    // Determine recipient key: from conversation, or self-key for self-chat
    String? recipientKey = conversation.publicKey;
    final isSelfChat =
        conversation.name == myNickname || conversation.name == 'Избранное';
    if (isSelfChat) {
      recipientKey = myPublicKey;
    }

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      leading: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              ShadeColors.violet.withOpacity(0.7),
              ShadeColors.cyan.withOpacity(0.4),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Center(
          child: Text(
            conversation.name.isNotEmpty
                ? conversation.name[0].toUpperCase()
                : '?',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
        ),
      ),
      title: Text(
        conversation.name,
        style: const TextStyle(
          fontWeight: FontWeight.w600,
          color: ShadeColors.textPrimary,
        ),
      ),
      subtitle: conversation.lastMessage != null
          ? Text(
              conversation.lastMessage!.encryptedContent,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                color: ShadeColors.textSecondary,
              ),
            )
          : const Text(
              'Нет сообщений',
              style: TextStyle(
                fontSize: 13,
                color: ShadeColors.textMuted,
              ),
            ),
      trailing: conversation.lastMessage != null
          ? Text(
              _formatTime(conversation.lastMessage!.timestamp),
              style: const TextStyle(
                fontSize: 11,
                color: ShadeColors.textMuted,
              ),
            )
          : null,
      onTap: () {
        if (recipientKey != null) {
          context.push(
            '/chat/${conversation.id}',
            extra: ChatScreenArgs(
              conversationName: conversation.name,
              recipientPublicKey: recipientKey,
              recipientUsername: conversation.name,
            ),
          );
        }
      },
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inMinutes < 1) return 'сейчас';
    if (diff.inHours < 1) return '${diff.inMinutes}м';
    if (diff.inDays < 1) {
      return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    }
    return '${time.day.toString().padLeft(2, '0')}.${time.month.toString().padLeft(2, '0')}';
  }
}

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: ShadeColors.surfaceCard,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: ShadeColors.greyBorder,
                width: 0.5,
              ),
            ),
            child: const Icon(
              Icons.chat_bubble_outline_rounded,
              size: 36,
              color: ShadeColors.violet,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'No active chats',
            style: TextStyle(
              fontSize: 15,
              color: ShadeColors.textSecondary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Tap + to start a new conversation',
            style: TextStyle(
              fontSize: 12,
              color: ShadeColors.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

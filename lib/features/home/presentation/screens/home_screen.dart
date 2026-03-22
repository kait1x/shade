import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:shade/features/auth/data/repositories/auth_notifier.dart';
import 'package:shade/features/chats/data/repositories/chat_repository.dart';
import 'package:shade/features/chats/presentation/screens/chat_screen.dart';
import 'package:shade/features/home/presentation/widgets/chat_list_view.dart';
import 'package:shade/main.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _isOpeningSelfChat = false;

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authNotifierProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('SHADE'),
        titleSpacing: 20,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(
            height: 0.5,
            color: ShadeColors.greyBorder,
          ),
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Profile card
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: ShadeColors.surfaceCard,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: ShadeColors.greyBorder,
                  width: 0.5,
                ),
              ),
              child: Row(
                children: [
                  // Gradient avatar
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [ShadeColors.violet, ShadeColors.cyan],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Center(
                      child: Text(
                        authState.nickname?.isNotEmpty == true
                            ? authState.nickname![0].toUpperCase()
                            : '?',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          authState.nickname ?? 'Unknown',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: ShadeColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: const BoxDecoration(
                                color: ShadeColors.greenAccent,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'RSA 4096 · E2EE',
                              style: TextStyle(
                                fontSize: 12,
                                color: ShadeColors.textSecondary,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Section header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
            child: Text(
              'ЧАТЫ',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: ShadeColors.textMuted,
                letterSpacing: 2,
              ),
            ),
          ),

          // Chat list
          const Expanded(child: ChatListView()),
        ],
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Self-chat (Избранное)
          _MiniFAB(
            icon: Icons.bookmark_rounded,
            isLoading: _isOpeningSelfChat,
            onPressed: _isOpeningSelfChat ? null : _openSelfChat,
          ),
          const SizedBox(height: 12),
          // New chat
          _MiniFAB(
            icon: Icons.search_rounded,
            isLoading: false,
            onPressed: () {
              context.push('/search');
            },
          ),
        ],
      ),
    );
  }

  Future<void> _openSelfChat() async {
    setState(() => _isOpeningSelfChat = true);

    try {
      final authState = ref.read(authNotifierProvider);
      final publicKey = authState.publicKey;
      final nickname = authState.nickname;

      if (publicKey == null || nickname == null) {
        throw Exception('Профиль не найден');
      }

      final chatRepo = ref.read(chatRepositoryProvider);
      final conversations = await chatRepo.getConversations();
      const selfChatName = 'Избранное';

      Conversation? selfChat;
      for (final conv in conversations) {
        if (conv.name == selfChatName) {
          selfChat = conv;
          break;
        }
      }

      final conversationId =
          selfChat?.id ?? await chatRepo.createConversation(selfChatName);

      if (mounted) {
        ref.invalidate(conversationsProvider);
        context.push(
          '/chat/$conversationId',
          extra: ChatScreenArgs(
            conversationName: selfChatName,
            recipientPublicKey: publicKey,
            recipientUsername: nickname,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Ошибка: $e'),
            backgroundColor: const Color(0xFFEF4444),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isOpeningSelfChat = false);
    }
  }

}

class _MiniFAB extends StatelessWidget {
  final IconData icon;
  final bool isLoading;
  final VoidCallback? onPressed;

  const _MiniFAB({
    required this.icon,
    required this.isLoading,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: onPressed != null
              ? [ShadeColors.violet, ShadeColors.violetDark]
              : [ShadeColors.surfaceElevated, ShadeColors.surfaceCard],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
        boxShadow: onPressed != null
            ? [
                BoxShadow(
                  color: ShadeColors.violet.withOpacity(0.3),
                  blurRadius: 12,
                  offset: const Offset(0, 3),
                ),
              ]
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(14),
          child: Center(
            child: isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Icon(icon, color: Colors.white, size: 22),
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shade/core/services/connection_service.dart';
import 'package:shade/features/auth/data/repositories/auth_notifier.dart';
import 'package:shade/features/chats/data/repositories/chat_repository.dart';
import 'package:shade/features/chats/presentation/screens/chat_screen.dart';
import 'package:shade/main.dart';

/// Search for users on the server and start a chat.
class UserSearchScreen extends ConsumerStatefulWidget {
  const UserSearchScreen({super.key});

  @override
  ConsumerState<UserSearchScreen> createState() => _UserSearchScreenState();
}

class _UserSearchScreenState extends ConsumerState<UserSearchScreen> {
  final _controller = TextEditingController();
  bool _isSearching = false;
  String? _error;
  PublicKeyBundle? _foundUser;
  String? _searchedUsername;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final username = _controller.text.trim();
    if (username.isEmpty) return;

    setState(() {
      _isSearching = true;
      _error = null;
      _foundUser = null;
      _searchedUsername = username;
    });

    try {
      final connectionService = ref.read(connectionServiceProvider);
      final bundle = await connectionService.getPublicKey(username);

      if (bundle == null) {
        setState(() {
          _error = 'Пользователь не найден или подпись невалидна';
          _isSearching = false;
        });
        return;
      }

      setState(() {
        _foundUser = bundle;
        _isSearching = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Ошибка поиска: $e';
        _isSearching = false;
      });
    }
  }

  Future<void> _startChat() async {
    if (_foundUser == null || _searchedUsername == null) return;

    final myNickname = ref.read(authNotifierProvider).nickname;
    if (myNickname == null) return;

    // Don't allow chatting with yourself through search
    if (_searchedUsername == myNickname) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Это вы! Используйте "Избранное"')),
      );
      return;
    }

    final chatRepo = ref.read(chatRepositoryProvider);

    // Save contact
    final db = ref.read(databaseServiceProvider);
    await db.saveContact(
      nickname: _searchedUsername!,
      publicKey: _foundUser!.publicKey,
      signature: _foundUser!.signature,
    );

    // Create or find conversation
    final conversations = await chatRepo.getConversations();
    int? conversationId;

    for (final conv in conversations) {
      if (conv.name == _searchedUsername) {
        conversationId = conv.id;
        break;
      }
    }

    conversationId ??= await chatRepo.createConversation(
      _searchedUsername!,
      publicKey: _foundUser!.publicKey,
    );

    if (mounted) {
      context.pushReplacement(
        '/chat/$conversationId',
        extra: ChatScreenArgs(
          conversationName: _searchedUsername!,
          recipientPublicKey: _foundUser!.publicKey,
          recipientUsername: _searchedUsername!,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Найти пользователя'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 0.5, color: ShadeColors.greyBorder),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Search field
            TextField(
              controller: _controller,
              style: const TextStyle(color: ShadeColors.textPrimary),
              cursorColor: ShadeColors.violet,
              decoration: InputDecoration(
                hintText: 'Введите никнейм...',
                prefixIcon: const Icon(Icons.search, color: ShadeColors.violet),
                suffixIcon: _controller.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, color: ShadeColors.textMuted),
                        onPressed: () {
                          _controller.clear();
                          setState(() {
                            _foundUser = null;
                            _error = null;
                          });
                        },
                      )
                    : null,
              ),
              onSubmitted: (_) => _search(),
              onChanged: (_) => setState(() {}),
            ),

            const SizedBox(height: 16),

            // Search button
            SizedBox(
              height: 48,
              child: ElevatedButton(
                onPressed: _isSearching ? null : _search,
                child: _isSearching
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Найти'),
              ),
            ),

            const SizedBox(height: 24),

            // Results
            if (_isSearching)
              const Center(child: CircularProgressIndicator())
            else if (_error != null)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.red.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, color: Colors.red),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _error!,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                  ],
                ),
              )
            else if (_foundUser != null && _searchedUsername != null)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: ShadeColors.surfaceCard,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: ShadeColors.greyBorder),
                ),
                child: Column(
                  children: [
                    // User avatar and name
                    CircleAvatar(
                      radius: 32,
                      backgroundColor: ShadeColors.violet.withOpacity(0.2),
                      child: Text(
                        _searchedUsername![0].toUpperCase(),
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: ShadeColors.violet,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _searchedUsername!,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: ShadeColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.verified, size: 14, color: ShadeColors.greenAccent),
                        SizedBox(width: 4),
                        Text(
                          'Подпись верна · E2EE',
                          style: TextStyle(
                            fontSize: 12,
                            color: ShadeColors.greenAccent,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _startChat,
                        icon: const Icon(Icons.chat),
                        label: const Text('Начать чат'),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

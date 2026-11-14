import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shade/core/services/connection_service.dart';
import 'package:shade/features/auth/data/repositories/auth_notifier.dart';
import 'package:shade/features/chats/data/repositories/chat_repository.dart';
import 'package:shade/features/chats/presentation/screens/chat_screen.dart';
import 'package:shade/main.dart';
import 'package:shade/core/widgets/shade_ui.dart';

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
    final username = _controller.text.trim().toLowerCase();
    if (username.isEmpty || _isSearching) return;

    setState(() {
      _isSearching = true;
      _error = null;
      _foundUser = null;
      _searchedUsername = username;
    });

    try {
      final connectionService = ref.read(connectionServiceProvider);
      final bundle = await connectionService.getPublicKey(username);

      if (!mounted) return;
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
      if (!mounted) return;
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
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Новый разговор')),
      body: Center(
          child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text('Найдите своих',
                            style: TextStyle(
                                fontSize: 30,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -.8)),
                        const SizedBox(height: 10),
                        const Text(
                            'Введите точный никнейм друга в Shade.\nИмена аккаунтов состоят из латинских букв, цифр и _.',
                            style: TextStyle(
                                color: ShadeColors.textSecondary,
                                height: 1.6,
                                fontSize: 14)),
                        const SizedBox(height: 26),
                        TextField(
                            key: const Key('user-search'),
                            controller: _controller,
                            enabled: !_isSearching,
                            autocorrect: false,
                            textInputAction: TextInputAction.search,
                            decoration: InputDecoration(
                                hintText: 'Никнейм собеседника',
                                prefixIcon: const Icon(
                                    Icons.alternate_email_rounded,
                                    size: 21),
                                suffixIcon: _controller.text.isEmpty
                                    ? null
                                    : IconButton(
                                        tooltip: 'Очистить',
                                        icon: const Icon(Icons.close_rounded,
                                            size: 19),
                                        onPressed: () {
                                          _controller.clear();
                                          setState(() {
                                            _foundUser = null;
                                            _error = null;
                                          });
                                        })),
                            onSubmitted: (_) => _search(),
                            onChanged: (_) => setState(() {
                                  _foundUser = null;
                                  _error = null;
                                })),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                            onPressed:
                                _isSearching || _controller.text.trim().isEmpty
                                    ? null
                                    : _search,
                            icon: _isSearching
                                ? const SizedBox(
                                    width: 17,
                                    height: 17,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2))
                                : const Icon(Icons.search_rounded, size: 20),
                            label: Text(
                                _isSearching ? 'Ищем…' : 'Найти собеседника'),
                            style: FilledButton.styleFrom(
                                minimumSize: const Size.fromHeight(52))),
                        const SizedBox(height: 28),
                        if (_error != null)
                          const ShadeEmptyState(
                              icon: Icons.person_search_outlined,
                              title: 'Пока не нашли',
                              description:
                                  'Проверьте никнейм и соединение с сервером.\nЗатем попробуйте ещё раз.')
                        else if (_foundUser != null &&
                            _searchedUsername != null)
                          Container(
                              padding: const EdgeInsets.all(24),
                              decoration: BoxDecoration(
                                  color: ShadeColors.surfaceCard,
                                  borderRadius: BorderRadius.circular(24),
                                  border: Border.all(
                                      color: ShadeColors.greyBorder)),
                              child: Column(children: [
                                ShadeAvatar(name: _searchedUsername!, size: 76),
                                const SizedBox(height: 18),
                                Text('@$_searchedUsername',
                                    style: const TextStyle(
                                        fontSize: 22,
                                        fontWeight: FontWeight.w700)),
                                const SizedBox(height: 8),
                                const Text('Профиль найден',
                                    style: TextStyle(
                                        color: ShadeColors.greenAccent,
                                        fontSize: 13)),
                                const SizedBox(height: 22),
                                SizedBox(
                                    width: double.infinity,
                                    child: FilledButton.icon(
                                        onPressed: _startChat,
                                        icon: const Icon(
                                            Icons.chat_bubble_outline_rounded,
                                            size: 19),
                                        label: const Text('Написать сообщение'),
                                        style: FilledButton.styleFrom(
                                            minimumSize:
                                                const Size.fromHeight(50)))),
                              ]))
                        else if (!_isSearching)
                          const ShadeEmptyState(
                              icon: Icons.waving_hand_outlined,
                              title: 'Одно имя — и вы на связи',
                              description:
                                  'Попросите друга поделиться никнеймом.\nВаш собственный никнейм есть в профиле.'),
                      ])))));
}

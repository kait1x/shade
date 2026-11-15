import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shade/core/services/connection_service.dart';
import 'package:shade/core/services/notification_service.dart';
import 'package:shade/core/widgets/shade_logo.dart';
import 'package:shade/core/widgets/shade_ui.dart';
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

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  bool _isOpeningSelfChat = false;
  StreamSubscription? _messageSub;
  StreamSubscription? _deletionSub;
  final _search = TextEditingController();
  bool _savedOnly = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final conn = ref.read(connectionServiceProvider);
      _messageSub = conn.messages.listen((_) {
        if (mounted) ref.invalidate(conversationsProvider);
      });
      _deletionSub = conn.messageDeleted.listen((_) {
        if (mounted) ref.invalidate(conversationsProvider);
      });
      NotificationService.cancelAll();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final conn = ref.read(connectionServiceProvider);
    final auth = ref.read(authNotifierProvider);
    if (state == AppLifecycleState.paused) {
      conn.disconnect();
    } else if (state == AppLifecycleState.resumed &&
        auth.status == AuthStatus.authenticated &&
        auth.nickname != null) {
      conn.connect(auth.nickname!);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _messageSub?.cancel();
    _deletionSub?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _showProfile() => context.push('/profile');

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authNotifierProvider);
    final connection = ref.watch(connectionServiceProvider);
    return Scaffold(
      body: SafeArea(
          child: Center(
              child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                            padding: const EdgeInsets.fromLTRB(24, 14, 20, 0),
                            child: Row(children: [
                              const ShadeLogo(size: 34),
                              const SizedBox(width: 8),
                              const Text('shade',
                                  style: TextStyle(
                                      fontSize: 25,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: -.9)),
                              const Spacer(),
                              IconButton(
                                  tooltip: 'Открыть Избранное',
                                  onPressed:
                                      _isOpeningSelfChat ? null : _openSelfChat,
                                  icon: _isOpeningSelfChat
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2))
                                      : const Icon(
                                          Icons.bookmark_border_rounded,
                                          color: ShadeColors.textSecondary)),
                              const SizedBox(width: 6),
                              IconButton(
                                  tooltip: 'Мой профиль',
                                  onPressed: _showProfile,
                                  icon: ShadeAvatar(
                                      name: auth.nickname ?? '',
                                      imageUrl: auth.avatarUrl,
                                      size: 38)),
                            ])),
                        Padding(
                            padding: const EdgeInsets.fromLTRB(24, 26, 24, 0),
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('Сообщения',
                                      style: TextStyle(
                                          fontSize: 32,
                                          height: 1.15,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: -1)),
                                  const SizedBox(height: 10),
                                  StreamBuilder<bool>(
                                      stream: connection.connectionChanges,
                                      initialData: connection.isConnected,
                                      builder: (context, snapshot) =>
                                          Row(children: [
                                            Icon(
                                                snapshot.data == true
                                                    ? Icons.cloud_done_outlined
                                                    : Icons.cloud_off_rounded,
                                                size: 15,
                                                color: snapshot.data == true
                                                    ? ShadeColors.greenAccent
                                                    : ShadeColors.textMuted),
                                            const SizedBox(width: 7),
                                            Expanded(
                                                child: Text(
                                                    snapshot.data == true
                                                        ? 'Вы на связи'
                                                        : 'Офлайн · история доступна',
                                                    style: const TextStyle(
                                                        fontSize: 13,
                                                        color: ShadeColors
                                                            .textSecondary))),
                                          ])),
                                  const SizedBox(height: 24),
                                  TextField(
                                      key: const Key('conversation-search'),
                                      controller: _search,
                                      onChanged: (_) => setState(() {}),
                                      decoration: InputDecoration(
                                          hintText: 'Поиск в переписках',
                                          prefixIcon: const Icon(
                                              Icons.search_rounded,
                                              size: 22),
                                          suffixIcon: _search.text.isEmpty
                                              ? null
                                              : IconButton(
                                                  tooltip: 'Очистить поиск',
                                                  icon: const Icon(
                                                      Icons.close_rounded,
                                                      size: 19),
                                                  onPressed: () {
                                                    _search.clear();
                                                    setState(() {});
                                                  }))),
                                  const SizedBox(height: 18),
                                  Wrap(spacing: 8, children: [
                                    ChoiceChip(
                                        label: const Text('Все чаты'),
                                        selected: !_savedOnly,
                                        showCheckmark: false,
                                        onSelected: (_) =>
                                            setState(() => _savedOnly = false)),
                                    ChoiceChip(
                                        label: const Text('Избранное'),
                                        selected: _savedOnly,
                                        showCheckmark: false,
                                        onSelected: (_) =>
                                            setState(() => _savedOnly = true)),
                                  ]),
                                ])),
                        const SizedBox(height: 12),
                        Expanded(
                            child: ChatListView(
                                query: _search.text, savedOnly: _savedOnly)),
                      ])))),
      floatingActionButton: FloatingActionButton.extended(
          onPressed: () => context.push('/search'),
          icon: const Icon(Icons.edit_outlined, size: 21),
          label: const Text('Написать',
              style: TextStyle(fontWeight: FontWeight.w700))),
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

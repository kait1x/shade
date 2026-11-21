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
import '../widgets/home_style.dart';
import '../widgets/home_connection_status.dart';

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
  StreamSubscription? _statusSub;
  StreamSubscription? _upgradeSub;
  bool _upgradeNoticeShown = false;
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
      _statusSub = conn.messageStatusUpdates.listen((_) {
        if (mounted) ref.invalidate(conversationsProvider);
      });
      _upgradeSub = conn.upgradeRequiredEvents.listen((kind) {
        if (!mounted || _upgradeNoticeShown) return;
        _upgradeNoticeShown = true;
        _showUpgradeNotice(kind);
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
        auth.nickname != null &&
        !ref.read(connectionServiceProvider).upgradeRequired) {
      conn.connect(auth.nickname!);
    }
  }

  void _showUpgradeNotice(String kind) {
    final account = kind == 'account';
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF111113),
        title: Text(account ? 'Аккаунт переведён на Shade v2' : 'Собеседник перешёл на Shade v2',
            style: const TextStyle(color: Color(0xFFF5F5F7), fontSize: 17)),
        content: Text(
          account
              ? 'Этот аккаунт уже использует протокол v2. Войдите в раздел '
                '«Устройства (v2)» с тем же ключом — история и ключи сохранены. '
                'Новая регистрация не требуется.'
              : 'Сообщение не доставлено: получатель использует Shade v2. '
                'Обновите приложение и перейдите в раздел «Устройства (v2)», '
                'чтобы продолжить переписку. Ключи и история сохраняются.',
          style: const TextStyle(color: Color(0xFF8E8E93), fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Понятно', style: TextStyle(color: Color(0xFF8E8E93))),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              context.push('/profile');
            },
            child: const Text('Открыть профиль', style: TextStyle(color: Color(0xFFF5F5F7))),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _messageSub?.cancel();
    _deletionSub?.cancel();
    _statusSub?.cancel();
    _upgradeSub?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _showProfile() => context.push('/profile');

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authNotifierProvider);
    return Scaffold(
      backgroundColor: HomeStyle.background,
      body: SafeArea(
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
                        title: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
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
                              onPressed:
                                  _isOpeningSelfChat ? null : _openSelfChat,
                              icon: _isOpeningSelfChat
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2))
                                  : const Icon(Icons.bookmark_border_rounded,
                                      size: 23)),
                          IconButton(
                              tooltip: 'Мой профиль',
                              onPressed: _showProfile,
                              icon: ShadeAvatar(
                                  name: auth.displayName ?? auth.nickname ?? '',
                                  username: auth.nickname,
                                  imageUrl: auth.avatarUrl,
                                  size: 34)),
                          const SizedBox(width: 12),
                        ],
                        bottom: PreferredSize(
                            preferredSize: const Size.fromHeight(1),
                            child: AnimatedContainer(
                                duration: HomeStyle.duration(context),
                                height: 1,
                                color: scrolled
                                    ? HomeStyle.border
                                    : Colors.transparent)),
                      ),
                      SliverToBoxAdapter(
                          child: Padding(
                              padding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text('Сообщения',
                                        style: TextStyle(
                                            fontSize: 34,
                                            height: 1.15,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: -1.3)),
                                    const SizedBox(height: 10),
                                    const HomeConnectionStatus(),
                                    const SizedBox(height: 24),
                                    TextField(
                                        key: const Key('conversation-search'),
                                        controller: _search,
                                        onChanged: (_) => setState(() {}),
                                        style: const TextStyle(fontSize: 15),
                                        textInputAction: TextInputAction.search,
                                        decoration: InputDecoration(
                                            hintText: 'Поиск в переписках',
                                            filled: true,
                                            fillColor: HomeStyle.surface,
                                            contentPadding:
                                                const EdgeInsets.symmetric(
                                                    vertical: 14),
                                            border: HomeStyle.searchBorder,
                                            enabledBorder:
                                                HomeStyle.searchBorder,
                                            focusedBorder:
                                                HomeStyle.searchBorder.copyWith(
                                                    borderSide:
                                                        const BorderSide(
                                                            color: ShadeColors
                                                                .textMuted)),
                                            prefixIcon: const Icon(
                                                Icons.search_rounded,
                                                size: 21),
                                            suffixIcon: _search.text.isEmpty
                                                ? null
                                                : IconButton(
                                                    tooltip: 'Очистить поиск',
                                                    icon: const Icon(
                                                        Icons.close_rounded,
                                                        size: 18),
                                                    onPressed: () {
                                                      _search.clear();
                                                      setState(() {});
                                                    }))),
                                    const SizedBox(height: 14),
                                    Wrap(spacing: 8, children: [
                                      _filter('Все чаты', false),
                                      _filter('Избранное', true),
                                    ]),
                                    const SizedBox(height: 18),
                                  ]))),
                    ],
                    body: ChatListView(
                        query: _search.text, savedOnly: _savedOnly),
                  )))),
      floatingActionButton: FloatingActionButton.extended(
          elevation: 0,
          backgroundColor: HomeStyle.ink,
          foregroundColor: Colors.black,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          onPressed: _openSearch,
          icon: const Icon(Icons.edit_outlined, size: 20),
          label: const Text('Написать',
              style: TextStyle(fontWeight: FontWeight.w700))),
    );
  }

  Widget _filter(String title, bool saved) => ChoiceChip(
      label: Text(title),
      selected: _savedOnly == saved,
      showCheckmark: false,
      selectedColor: HomeStyle.ink,
      backgroundColor: HomeStyle.surface,
      labelStyle: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color:
              _savedOnly == saved ? Colors.black : ShadeColors.textSecondary),
      side: BorderSide(
          color: _savedOnly == saved ? Colors.transparent : HomeStyle.border),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      onSelected: (_) => setState(() => _savedOnly = saved));

  Future<void> _openSearch() async {
    await context.push('/search');
    if (mounted) ref.invalidate(conversationsProvider);
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
        await context.push(
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
      if (mounted) {
        ref.invalidate(conversationsProvider);
        setState(() => _isOpeningSelfChat = false);
      }
    }
  }
}

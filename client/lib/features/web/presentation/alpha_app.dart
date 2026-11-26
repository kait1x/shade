import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shade/core/theme/shade_theme.dart';
import 'package:shade/core/widgets/avatar_view.dart';
import 'package:shade/core/widgets/shade_chat_list.dart';
import 'package:shade/core/widgets/shade_motion.dart';
import 'package:shade/core/widgets/shade_profile_layout.dart';
import 'package:shade/core/widgets/shade_states.dart';
import 'package:shade/core/widgets/shade_tab_dock.dart';
import 'package:shade/features/chats/presentation/widgets/message_bubble.dart';
import 'package:shade/features/chats/presentation/widgets/message_input.dart';
import 'package:shade/features/stickers/collection.dart';
import 'alpha_avatar_editor.dart';
import 'alpha_controller.dart';
import 'alpha_sticker_backend.dart';
import 'recovery_screen.dart';

bool _isVoiceMedia(Object? media) =>
    media is Map && (media['mime'] as String?)?.startsWith('audio/') == true;

class _VoicePlayer extends StatefulWidget {
  const _VoicePlayer(this.controller, this.messageRef, {required this.mine});
  final AlphaController controller;
  final String messageRef;
  final bool mine;

  @override
  State<_VoicePlayer> createState() => _VoicePlayerState();
}

class _VoicePlayerState extends State<_VoicePlayer> {
  Timer? _timer;
  bool _playing = false;
  bool _busy = false;
  double _position = 0;
  double _duration = 0;

  Future<void> _update(String action, [double? position]) async {
    if (_busy) return;
    _busy = true;
    try {
      final status = await widget.controller.dispatch(action, {
        'ref': widget.messageRef,
        if (position != null) 'position': position,
      });
      if (!mounted || status is! Map) return;
      setState(() {
        _playing = status['playing'] == true;
        _position = (status['position'] as num?)?.toDouble() ?? 0;
        _duration = (status['duration'] as num?)?.toDouble() ?? 0;
      });
      if (_playing) {
        _timer ??= Timer.periodic(
            const Duration(milliseconds: 250), (_) => _update('voice.status'));
      } else {
        _timer?.cancel();
        _timer = null;
      }
    } catch (_) {
      // The web bridge already displays playback errors.
    } finally {
      _busy = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String _clock(double seconds) {
    final whole = seconds.floor();
    return '${whole ~/ 60}:${(whole % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final color =
        widget.mine ? Colors.black : Theme.of(context).colorScheme.onSurface;
    return SizedBox(
      width: 226,
      child: Row(children: [
        IconButton.filled(
          tooltip: _playing ? 'Пауза' : 'Голосовое',
          onPressed: () => _update('voice.play'),
          icon: Icon(_playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
        ),
        const SizedBox(width: 8),
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Голосовое',
                style: TextStyle(color: color, fontWeight: FontWeight.w600)),
            if (_duration > 0)
              Slider(
                value: _position.clamp(0, _duration).toDouble(),
                max: _duration,
                onChanged: (value) => _update('voice.seek', value),
                semanticFormatterCallback: _clock,
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: LinearProgressIndicator(value: 0, color: color),
              ),
            if (_duration > 0)
              Text('${_clock(_position)} / ${_clock(_duration)}',
                  style: TextStyle(color: color, fontSize: 11)),
          ]),
        ),
      ]),
    );
  }
}

class ShadeAlphaApp extends StatelessWidget {
  const ShadeAlphaApp({super.key, required this.controller});
  final AlphaController controller;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
      valueListenable: shadeLightTheme,
      builder: (_, light, __) {
        final theme = light ? buildShadeLightTheme() : buildShadeTheme();
        return MaterialApp(
          title: 'Shade',
          debugShowCheckedModeBanner: false,
          theme: theme.copyWith(
            textTheme:
                theme.textTheme.apply(fontFamilyFallback: const ['ShadeEmoji']),
          ),
          home: ListenableBuilder(
              listenable: controller,
              // Режим восстановления: отдельный экран до появления device-сессии.
              builder: (_, __) => controller.recovery != null
                  ? RecoveryScreen(controller: controller)
                  : _Shell(controller: controller)),
        );
      });
}

class _Shell extends StatefulWidget {
  const _Shell({required this.controller});
  final AlphaController controller;
  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  bool profile = false;
  bool settings = false;
  bool peerProfile = false;
  // Экран «Новый разговор» живёт в той же оболочке, что и профили.
  bool newChat = false;
  void openNewChat() => setState(() {
        profile = false;
        settings = false;
        peerProfile = false;
        newChat = true;
      });
  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return LayoutBuilder(builder: (context, bounds) {
      final wide = bounds.maxWidth >= 900;
      final showDock = !wide &&
          !newChat &&
          !peerProfile &&
          c.selected == null &&
          MediaQuery.viewInsetsOf(context).bottom == 0;
      void selectTab(int index) => setState(() {
            settings = index == 1;
            profile = index == 2;
          });
      final right = settings
          ? _Profile(
              controller: c, settingsOnly: true, close: () => selectTab(0))
          : newChat
              ? _NewChat(
                  controller: c, close: () => setState(() => newChat = false))
              : profile
                  ? _Profile(
                      controller: c,
                      showSettings: wide,
                      close: () => setState(() => profile = false))
                  : peerProfile && c.selected != null
                      ? _PeerProfile(
                          controller: c,
                          peer: c.selected!,
                          openChat: () => setState(() => peerProfile = false))
                      : _Conversation(
                          key: ValueKey(c.selected),
                          controller: c,
                          back: () => c.act('back', {'account': c.selected}),
                          openPeer: () => setState(() => peerProfile = true));
      return PopScope(
          canPop: c.selected == null &&
              !profile &&
              !settings &&
              !peerProfile &&
              !newChat,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) {
              if (newChat) {
                setState(() => newChat = false);
              } else if (peerProfile) {
                setState(() => peerProfile = false);
              } else if (profile || settings) {
                selectTab(0);
              } else {
                c.act('back', {'account': c.selected});
              }
            }
          },
          child: Scaffold(
              extendBody: showDock,
              bottomNavigationBar: showDock
                  ? ShadeTabDock(
                      selectedIndex: settings
                          ? 1
                          : profile
                              ? 2
                              : 0,
                      onSelected: selectTab)
                  : null,
              body: SafeArea(
                  bottom: false,
                  child: Center(
                      child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 1600),
                          child: wide
                              ? Row(children: [
                                  SizedBox(
                                      width: bounds.maxWidth < 1200 ? 340 : 380,
                                      child: _Chats(
                                          controller: c,
                                          newChat: openNewChat,
                                          openChat: () => setState(() {
                                                profile = false;
                                                settings = false;
                                                peerProfile = false;
                                                newChat = false;
                                              }),
                                          profile: () => setState(() {
                                                settings = false;
                                                profile = !profile;
                                              }))),
                                  const VerticalDivider(width: 1),
                                  Expanded(child: right),
                                ])
                              : AnimatedSwitcher(
                                  duration: ShadeMotion.duration(context),
                                  child: newChat ||
                                          profile ||
                                          settings ||
                                          peerProfile && c.selected != null ||
                                          c.selected != null
                                      ? right
                                      : _Chats(
                                          controller: c,
                                          newChat: openNewChat,
                                          openChat: () => setState(() {
                                                profile = false;
                                                settings = false;
                                                peerProfile = false;
                                                newChat = false;
                                              }),
                                          profile: null)))))));
    });
  }
}

class _Chats extends StatefulWidget {
  const _Chats(
      {required this.controller,
      required this.profile,
      required this.newChat,
      required this.openChat});
  final AlphaController controller;
  final VoidCallback? profile;
  final VoidCallback newChat, openChat;
  @override
  State<_Chats> createState() => _ChatsState();
}

class _ChatsState extends State<_Chats> {
  final search = TextEditingController();
  final focus = FocusNode();
  final compactCompose = ValueNotifier(false);
  bool savedOnly = false;
  bool searchVisible = true;

  @override
  void dispose() {
    search.dispose();
    focus.dispose();
    compactCompose.dispose();
    super.dispose();
  }

  void toggleSearch() {
    ShadeMotion.selection(context);
    setState(() => searchVisible = !searchVisible);
    if (searchVisible) {
      focus.requestFocus();
    } else {
      focus.unfocus();
      search.clear();
    }
  }

  void compose() {
    focus.unfocus();
    ShadeMotion.selection(context);
    widget.newChat();
    widget.controller.act('refresh');
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final query = search.text.trim().toLowerCase();
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final peers = c.peers.where((p) {
      final account = p['account'] as String;
      final items = c.conversation(account);
      final hasChat =
          items.isNotEmpty || p['pinned'] == true || p['unverified'] == true;
      return hasChat &&
          (!savedOnly || p['favorites'] == true) &&
          (account.contains(query) ||
              (items.lastOrNull?['text'] as String? ?? '')
                  .toLowerCase()
                  .contains(query));
    }).toList()
      ..sort((a, b) {
        final at = c
                .conversation(a['account'] as String)
                .lastOrNull?['createdAt'] as num? ??
            0;
        final bt = c
                .conversation(b['account'] as String)
                .lastOrNull?['createdAt'] as num? ??
            0;
        return bt.compareTo(at);
      });
    final indices = <String, int>{
      for (var i = 0; i < peers.length; i++) peers[i]['account'] as String: i,
    };
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(children: [
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: (event) {
                final compact = shadeComposeCompact(event);
                if (compact != null) compactCompose.value = compact;
                return false;
              },
              child: CustomScrollView(
                key: const PageStorageKey('web-chats-scroll'),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                slivers: [
                  ShadeChatsAppBar(
                    searchVisible: searchVisible,
                    onToggleSearch: toggleSearch,
                    actions: [
                      if (widget.profile != null)
                        IconButton(
                          tooltip: 'Профиль',
                          onPressed: widget.profile,
                          icon: AccountAvatar(
                              controller: c, account: c.account, size: 32),
                        ),
                    ],
                  ),
                  SliverToBoxAdapter(
                    child: ShadeChatsHeader(
                      searchVisible: searchVisible,
                      controller: search,
                      focusNode: focus,
                      onQueryChanged: (_) => setState(() {}),
                      savedOnly: savedOnly,
                      onFilterChanged: (saved) =>
                          setState(() => savedOnly = saved),
                    ),
                  ),
                  if (!c.connected && c.connection.trim().isNotEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: () => c.act('sync'),
                            icon:
                                const Icon(Icons.cloud_off_outlined, size: 18),
                            label: Text(c.connection),
                          ),
                        ),
                      ),
                    ),
                  if (peers.isEmpty)
                    SliverToBoxAdapter(
                      child: ShadeEmptyState(
                        icon: query.isEmpty
                            ? Icons.chat_bubble_outline_rounded
                            : Icons.search_off_rounded,
                        title: query.isNotEmpty
                            ? 'Ничего не найдено'
                            : savedOnly
                                ? 'Пока нет личных заметок'
                                : 'Начните разговор',
                        description: query.isNotEmpty
                            ? 'Попробуйте другой никнейм или фрагмент сообщения.'
                            : savedOnly
                                ? 'Здесь будет ваша переписка с собой.'
                                : 'Найдите собеседника по никнейму.',
                      ),
                    )
                  else
                    SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, i) {
                          final info = peers[i];
                          final peer = info['account'] as String;
                          final latest = c.conversation(peer).lastOrNull;
                          final mine = latest?['from'] == c.account;
                          final isSelf = peer == c.account;
                          final text = latest?['text'] as String? ??
                              (_isVoiceMedia(latest?['media'])
                                  ? '🎙 Голосовое'
                                  : latest?['media'] != null
                                      ? '📷 Фото'
                                      : null);
                          return ShadeChatRow(
                            key: ValueKey(peer),
                            title: isSelf ? 'Избранное' : c.peerName(peer),
                            preview: text == null
                                ? (isSelf
                                    ? 'Ваши личные заметки'
                                    : 'Нет сообщений')
                                : (mine && !isSelf ? 'Вы: $text' : text),
                            time: (latest?['createdAt'] as num?)?.toInt(),
                            status: mine && latest != null
                                ? AlphaController.status(latest)
                                : null,
                            unreadCount: c.unread(peer),
                            confirmed: info['unverified'] != true,
                            selected: c.selected == peer,
                            avatar: AccountAvatar(
                                controller: c,
                                account: peer,
                                size: 46,
                                favorites: isSelf),
                            onOpen: () {
                              focus.unfocus();
                              ShadeMotion.selection(context);
                              widget.openChat();
                              c.act('select', {'account': peer});
                            },
                          );
                        },
                        childCount: peers.length,
                        findChildIndexCallback: (key) =>
                            indices[(key as ValueKey<String>).value],
                      ),
                    ),
                  const SliverToBoxAdapter(child: SizedBox(height: 8)),
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
                  valueListenable: compactCompose,
                  builder: (context, compact, _) =>
                      ShadeComposeButton(compact: compact, onPressed: compose),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

// Typing (contract C2) wins over presence; both degrade to the static line.
String _statusLine(AlphaController c, String peer) {
  final typingUntil = c.typing[peer] as num? ?? 0;
  if (typingUntil > DateTime.now().millisecondsSinceEpoch) return 'печатает…';
  final p = c.presence[peer];
  if (p is Map && p['online'] == true) return 'В сети';
  final lastSeen = (p is Map ? p['lastSeen'] as num? : null)?.toInt() ?? 0;
  if (lastSeen > 0) return _lastSeenLine(lastSeen);
  return 'Личная переписка';
}

// Last-seen wording mirrors UserStatus.displayText (connection_service.dart).
String _lastSeenLine(int lastSeen) {
  final diff = DateTime.now().millisecondsSinceEpoch - lastSeen;
  if (diff <= 60000) return 'был(а) только что';
  final minutes = diff ~/ 60000;
  if (minutes < 60) return 'был(а) $minutes мин назад';
  final hours = diff ~/ 3600000;
  if (hours < 24) return 'был(а) сегодня';
  if (hours < 48) return 'был(а) вчера';
  return 'был(а) давно';
}

class _Conversation extends StatefulWidget {
  const _Conversation(
      {super.key,
      required this.controller,
      required this.back,
      required this.openPeer});
  final AlphaController controller;
  final VoidCallback back;
  final VoidCallback openPeer;
  @override
  State<_Conversation> createState() => _ConversationState();
}

class _ConversationState extends State<_Conversation>
    with WidgetsBindingObserver {
  late final ScrollController scroll;
  Set<String>? known;
  Timer? positionTimer;
  bool restored = false, atBottom = true;
  int unseen = 0;
  Map<String, dynamic>? replyTo;
  late final String? activeAccount;
  // Decoded media bytes per message ref. Every item build used to re-run
  // base64Decode, producing a fresh Uint8List whose identity makes Flutter's
  // image cache miss and re-decode the 900px bitmap on each projection
  // update — visible jank while scrolling photo histories on mid-range
  // phones. Bounded FIFO (insertion order): the raw bytes are ~75% of the
  // base64 already held in encrypted state.
  static const _mediaCacheLimit = 24;
  final Map<String, Uint8List> _mediaCache = <String, Uint8List>{};
  Uint8List _mediaBytes(String ref, Map media) =>
      _mediaCache.putIfAbsent(ref, () {
        if (_mediaCache.length >= _mediaCacheLimit) {
          _mediaCache.remove(_mediaCache.keys.first);
        }
        return base64Decode(media['data'] as String);
      });
  @override
  void initState() {
    super.initState();
    activeAccount = widget.controller.selected;
    final saved = widget.controller.positions[activeAccount] as Map?;
    // Restore before the first sliver layout: clamping to its initial estimated
    // extent loses positions in histories with tall, lazily laid-out messages.
    scroll = ScrollController(
        initialScrollOffset: saved != null && saved['bottom'] == false
            ? (saved['offset'] as num).toDouble()
            : 0,
        keepScrollOffset: false);
    WidgetsBinding.instance.addObserver(this);
    scroll.addListener(_scroll);
  }

  void _scroll() {
    if (!scroll.hasClients || !restored) return;
    // The list is reversed like Android's: offset 0 is the latest message.
    atBottom = scroll.position.pixels < 80;
    if (atBottom && unseen != 0) setState(() => unseen = 0);
    positionTimer?.cancel();
    positionTimer = Timer(const Duration(milliseconds: 180), () {
      _savePosition();
      if (mounted && atBottom && activeAccount == widget.controller.selected) {
        final items = widget.controller.conversation(activeAccount!);
        if (items.isNotEmpty) {
          widget.controller.act('read',
              {'account': activeAccount, 'until': items.last['createdAt']});
        }
      }
    });
  }

  void _savePosition() {
    if (scroll.hasClients && restored && activeAccount != null) {
      widget.controller.act('position', {
        'account': activeAccount,
        'offset': scroll.offset,
        'bottom': atBottom
      });
    }
  }

  void _showMessageMenu(Map<String, dynamic> m) {
    ShadeMotion.selection(context);
    showModalBottomSheet(
      context: context,
      sheetAnimationStyle: ShadeMotion.sheet(context),
      showDragHandle: true,
      backgroundColor: context.shadeColor(ShadeColors.surfaceCard),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
          child: SingleChildScrollView(
              child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(Icons.reply_rounded,
                color: context.shadeColor(ShadeColors.cyan)),
            title: Text('Ответить',
                style: TextStyle(
                    color: context.shadeColor(ShadeColors.textPrimary))),
            onTap: () {
              Navigator.pop(ctx);
              setState(() => replyTo = {
                    'ref': m['ref'],
                    'from': m['from'],
                    'text': m['text'],
                  });
            },
          ),
          ListTile(
            leading: Icon(Icons.delete_outline_rounded,
                color: context.shadeColor(ShadeColors.textSecondary)),
            title: Text('Удалить у себя',
                style: TextStyle(
                    color: context.shadeColor(ShadeColors.textPrimary))),
            onTap: () {
              Navigator.pop(ctx);
              _deleteMessage(m['ref'] as String);
            },
          ),
          // Delete-for-all (contract C3): only the sender, only non-queued.
          if (m['from'] == widget.controller.account &&
              m['status'] != 'queued' &&
              m['status'] != 'blocked')
            ListTile(
                leading: const Icon(Icons.delete_forever_rounded,
                    color: Color(0xFFEF4444)),
                title: const Text('Удалить у всех',
                    style: TextStyle(color: Color(0xFFEF4444))),
                onTap: () {
                  Navigator.pop(ctx);
                  _retractMessage(m['ref'] as String);
                }),
        ],
      ))),
    );
  }

  Future<void> _retractMessage(String ref) async {
    try {
      await widget.controller.act('retract', {'ref': ref});
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Не удалось отозвать. Проверьте сеть и повторите.')));
      }
    }
  }

  Future<void> _deleteMessage(String ref) async {
    try {
      await widget.controller.act('deleteLocal', {'ref': ref});
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Не удалось удалить. Проверьте сеть и повторите.')));
      }
    }
  }

  void _jumpToBottom([int attempts = 6]) {
    if (!mounted || !scroll.hasClients) return;
    // Reverse list: the latest message sits at offset 0.
    scroll.jumpTo(0);
    _trackBottom();
    if (attempts > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // Retry on the raw extent: the atBottom flag may transiently lag while
        // lazily built items keep growing maxScrollExtent.
        if (mounted && scroll.hasClients && scroll.position.pixels > 1) {
          _jumpToBottom(attempts - 1);
        }
      });
    }
  }

  // Lazy list extents keep growing for a few frames after a jump, without new
  // scroll notifications; re-derive atBottom until they settle.
  void _trackBottom([int attempts = 5]) {
    if (!mounted || !scroll.hasClients) return;
    final bottomNow = scroll.position.pixels < 80;
    if (bottomNow != atBottom) {
      setState(() => atBottom = bottomNow);
    }
    if (attempts > 0) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _trackBottom(attempts - 1));
    }
  }

  void _toLatest() {
    if (!scroll.hasClients) return;
    if (unseen != 0) setState(() => unseen = 0);
    scroll.animateTo(0,
        duration: ShadeMotion.duration(context, 180), curve: Curves.easeOut);
    _followBottom();
  }

  // Lazy items keep growing maxScrollExtent while the animation runs, and a
  // TickerFuture does not complete on natural end, so follow by frames: keep
  // the bottom in sight until the position actually stops moving.
  void _followBottom([int frames = 40]) {
    if (!mounted || !scroll.hasClients || frames <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !scroll.hasClients) return;
      final position = scroll.position;
      if (position.pixels > 1) {
        if (!position.isScrollingNotifier.value) {
          position.animateTo(0,
              duration: ShadeMotion.duration(context, 180),
              curve: Curves.easeOut);
        }
        _followBottom(frames - 1);
      }
    });
  }

  @override
  void didChangeMetrics() {
    if (atBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && scroll.hasClients) {
          _jumpToBottom();
        }
      });
    }
  }

  @override
  void dispose() {
    _savePosition();
    positionTimer?.cancel();
    scroll.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller, peer = c.selected;
    if (peer == null) {
      return const ShadeEmptyState(
          icon: Icons.forum_outlined,
          title: 'Личное остаётся личным',
          description:
              'Выберите диалог слева.\nПереписка зашифрована на ваших устройствах.');
    }
    final items = c.conversation(peer),
        ids = items.map((m) => m['ref'] as String).toSet();
    final added = known == null ? <String>{} : ids.difference(known!);
    known = ids;
    // Count only the peer's messages that arrived while scrolled away; own
    // messages force the usual follow-to-bottom behaviour instead.
    if (restored && !atBottom && added.isNotEmpty) {
      unseen += items
          .where((m) => added.contains(m['ref']) && m['from'] != c.account)
          .length;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !scroll.hasClients) return;
      if (!restored) {
        final saved = c.positions[peer] as Map?;
        if (saved == null || saved['bottom'] == true) _jumpToBottom();
        restored = true;
        _trackBottom();
      } else if (added.isNotEmpty && atBottom) {
        // Reversed list: the latest message lives at offset 0.
        scroll.animateTo(0,
            duration: ShadeMotion.duration(context, 180),
            curve: Curves.easeOut);
      }
      if (atBottom && items.isNotEmpty) {
        c.act('read', {'account': peer, 'until': items.last['createdAt']});
      }
    });
    return Column(children: [
      Container(
          padding: const EdgeInsets.fromLTRB(8, 10, 12, 10),
          decoration: BoxDecoration(
              border: Border(
                  bottom: BorderSide(
                      color: context.shadeColor(ShadeColors.greyBorder),
                      width: .5))),
          child: Row(children: [
            IconButton(
                tooltip: 'Назад к чатам',
                onPressed: widget.back,
                icon: const Icon(Icons.chevron_left_rounded)),
            Expanded(
                child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: peer == c.account ? null : widget.openPeer,
                    child: Row(children: [
                      AccountAvatar(
                          controller: c,
                          account: peer,
                          size: 40,
                          favorites: peer == c.account),
                      const SizedBox(width: 12),
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(c.peerName(peer),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 16, fontWeight: FontWeight.w700)),
                            const SizedBox(height: 3),
                            Text(_statusLine(c, peer),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 11,
                                    color: (c.typing[peer] as num? ?? 0) >
                                            DateTime.now()
                                                .millisecondsSinceEpoch
                                        ? context.shadeColor(ShadeColors.cyan)
                                        : context.shadeColor(
                                            ShadeColors.textMuted))),
                          ])),
                    ]))),
            IconButton(
                tooltip: 'Проверить ключ контакта',
                onPressed: () => c.act('verify', {'account': peer}),
                icon: Icon(
                    c.pinned(peer) && !c.unverified(peer)
                        ? Icons.verified_user_outlined
                        : Icons.shield_outlined,
                    size: 21)),
          ])),
      // TOFU-бейдж: ключ закреплён автоматически, ручная сверка доступна.
      if (c.unverified(peer) && peer != c.account)
        Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            color: context.shadeColor(ShadeColors.surfaceCard),
            child: Row(children: [
              Icon(Icons.shield_outlined,
                  size: 16,
                  color: context.shadeColor(ShadeColors.textSecondary)),
              const SizedBox(width: 8),
              Expanded(
                  child: Text('Ключ не сверен',
                      style: TextStyle(
                          fontSize: 12,
                          color:
                              context.shadeColor(ShadeColors.textSecondary)))),
              TextButton(
                  onPressed: () => c.act('verify', {'account': peer}),
                  child: const Text('Сверить',
                      style: TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w700))),
            ])),
      AnimatedSize(
          duration: ShadeMotion.duration(context),
          child: !c.connected
              ? Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  color: context.shadeColor(ShadeColors.surfaceCard),
                  child: Text(c.connection,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12,
                          color:
                              context.shadeColor(ShadeColors.textSecondary))))
              : const SizedBox(width: double.infinity)),
      Expanded(
          child: CustomPaint(
              painter: _ConversationPatternPainter(
                  light: Theme.of(context).brightness == Brightness.light),
              child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 840),
                      child: items.isEmpty
                          ? ShadeEmptyState(
                              icon: Icons.lock_outline_rounded,
                              title: c.pinned(peer)
                                  ? 'Только между вами'
                                  : 'Сверьте отпечаток ключа',
                              description: c.pinned(peer)
                                  ? 'Сообщения шифруются на устройстве.\nНачните с простого «Привет».'
                                  : 'Сравните отпечатки через доверенный канал,\nчтобы начать безопасную переписку.')
                          : Stack(children: [
                              ListView.builder(
                                  controller: scroll,
                                  reverse: true,
                                  padding:
                                      const EdgeInsets.only(top: 8, bottom: 16),
                                  itemCount: items.length,
                                  keyboardDismissBehavior:
                                      ScrollViewKeyboardDismissBehavior.onDrag,
                                  itemBuilder: (context, i) {
                                    // Reversed index: 0 is the newest message; the
                                    // original (chronological) index is the mirror.
                                    final m = items[items.length - 1 - i],
                                        date =
                                            DateTime.fromMillisecondsSinceEpoch(
                                                (m['createdAt'] as num)
                                                    .toInt());
                                    final reply = m['reply'] as Map?;
                                    final media = m['media'] as Map?;
                                    final voice = _isVoiceMedia(media);
                                    final mediaBytes = media == null || voice
                                        ? null
                                        : _mediaBytes(
                                            m['ref'] as String, media);
                                    bool grouped(int originalIndex) =>
                                        originalIndex >= 0 &&
                                        originalIndex < items.length &&
                                        items[originalIndex]['from'] ==
                                            m['from'] &&
                                        ((items[originalIndex]['createdAt']
                                                        as num) -
                                                    (m['createdAt'] as num))
                                                .abs() <
                                            180000 &&
                                        DateUtils.isSameDay(
                                            date,
                                            DateTime.fromMillisecondsSinceEpoch(
                                                (items[originalIndex]
                                                        ['createdAt'] as num)
                                                    .toInt()));
                                    final showDate = i == items.length - 1 ||
                                        !DateUtils.isSameDay(
                                            date,
                                            DateTime.fromMillisecondsSinceEpoch(
                                                (items[items.length - 2 - i]
                                                        ['createdAt'] as num)
                                                    .toInt()));
                                    return Column(
                                        key: ValueKey(m['ref']),
                                        children: [
                                          if (showDate)
                                            ShadeDateSeparator(date: date),
                                          ShadeMessageArrival(
                                              animate: added.contains(m['ref']),
                                              child: MessageBubble(
                                                  text: media != null
                                                      ? ''
                                                      : m['text'] as String,
                                                  timestamp: date,
                                                  isMine:
                                                      m['from'] == c.account,
                                                  isEncrypted: true,
                                                  isImage:
                                                      media != null && !voice,
                                                  imageData: mediaBytes,
                                                  onOpenLocation: m['text']
                                                              is String &&
                                                          (m['text'] as String)
                                                              .startsWith(
                                                                  '📍 Геопозиция\n')
                                                      ? () => c.act(
                                                          'location.open',
                                                          {'ref': m['ref']})
                                                      : null,
                                                  voicePlayer: voice
                                                      ? _VoicePlayer(
                                                          c, m['ref'] as String,
                                                          mine:
                                                              m['from'] == c.account)
                                                      : null,
                                                  status: AlphaController.status(m),
                                                  deliveryLabel: AlphaController.delivery(m),
                                                  groupedWithPrevious: grouped(items.length - 2 - i),
                                                  groupedWithNext: grouped(items.length - i),
                                                  onLongPress: () => _showMessageMenu(m),
                                                  replyText: reply?['text'] as String?,
                                                  replySender: reply == null
                                                      ? null
                                                      : reply['from'] == c.account
                                                          ? 'Вы'
                                                          : peer)),
                                        ]);
                                  }),
                              // Live scroll truth for the jump button: lazy list
                              // extents grow without new notifications, so the
                              // flag fields alone cannot be trusted here. In a
                              // reversed list «away» means offset > 180.
                              ListenableBuilder(
                                  listenable: scroll,
                                  builder: (context, _) => Align(
                                      alignment: Alignment.bottomRight,
                                      child: restored &&
                                              scroll.hasClients &&
                                              scroll.position.pixels > 180
                                          ? Padding(
                                              padding: const EdgeInsets.only(
                                                  right: 16, bottom: 12),
                                              child: FloatingActionButton.small(
                                                  key: const Key(
                                                      'jump-to-latest'),
                                                  heroTag: 'alpha-latest',
                                                  tooltip: unseen > 0
                                                      ? 'Новых сообщений: $unseen. К последним'
                                                      : 'К последним сообщениям',
                                                  backgroundColor: context.shadeColor(
                                                      ShadeColors.greyBorder),
                                                  onPressed: _toLatest,
                                                  child: unseen > 0
                                                      ? Text('$unseen',
                                                          style:
                                                              const TextStyle(fontWeight: FontWeight.w700))
                                                      : const Icon(Icons.arrow_downward_rounded, size: 21)))
                                          : null)),
                            ]))))),
      if (!c.pinned(peer))
        SafeArea(
            top: false,
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: OutlinedButton.icon(
                    onPressed: () => c.act('verify', {'account': peer}),
                    icon: const Icon(Icons.shield_outlined),
                    label: const Text('Сверить отпечаток'))))
      else ...[
        // Reply preview, mirroring the Android composer attachment bar.
        if (replyTo != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: context.shadeColor(ShadeColors.surfaceElevated),
            child: Row(children: [
              Container(
                  width: 3,
                  height: 40,
                  color: context.shadeColor(ShadeColors.cyan)),
              const SizedBox(width: 12),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(replyTo!['from'] == c.account ? 'Вы' : peer,
                        style: TextStyle(
                            color: context.shadeColor(ShadeColors.cyan),
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                    Text(replyTo!['text'] as String,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color:
                                context.shadeColor(ShadeColors.textSecondary),
                            fontSize: 13)),
                  ])),
              IconButton(
                  icon: Icon(Icons.close_rounded,
                      size: 18,
                      color: context.shadeColor(ShadeColors.textMuted)),
                  tooltip: 'Отменить ответ',
                  onPressed: () => setState(() => replyTo = null)),
            ]),
          ),
        Align(
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 840),
                child: MessageInput(
                    key: ValueKey('composer-$peer'),
                    maxLines: MediaQuery.sizeOf(context).height -
                                MediaQuery.viewInsetsOf(context).bottom <
                            600
                        ? 3
                        : 5,
                    onTyping: () => c.act('typing', {'account': peer}),
                    onShareLocation: () {
                      FocusManager.instance.primaryFocus?.unfocus();
                      c.act('location.share', {'account': peer});
                    },
                    onVoiceRecord: () {
                      FocusManager.instance.primaryFocus?.unfocus();
                      c.act('voice.record', {'account': peer});
                    },
                    onImageSelected: (bytes) async {
                      atBottom = true;
                      await c.act('sendMedia', {
                        'account': peer,
                        'image': base64Encode(bytes),
                        'mime': 'image/jpeg',
                      });
                      // The bridge already fires a fire-and-forget sync after
                      // sendMedia; awaiting a second sync here would surface
                      // its transient 429s as a false "photo failed" error.
                    },
                    onSend: (text) async {
                      atBottom = true;
                      final reply = replyTo == null
                          ? null
                          : Map<String, dynamic>.from(replyTo!);
                      await c.act('send', {
                        'account': peer,
                        'text': text,
                        if (reply != null) 'reply': reply,
                      });
                      if (mounted) setState(() => replyTo = null);
                      // Samsung GBoard keeps the field focused with a phantom
                      // shrunken visual viewport after send; the engine misses
                      // the final resize and the composer strands mid-screen.
                      // Closing the keyboard deterministically settles the
                      // metrics instead of racing them mid-transition.
                      FocusManager.instance.primaryFocus?.unfocus();
                    }))),
      ],
    ]);
  }
}

// Экран «Новый разговор»: поиск по точному никнейму вместо каталога всех
// пользователей. Найденный контакт закрепляется автоматически (TOFU) —
// переписка начинается без ручного обмена ключами.
class _NewChat extends StatefulWidget {
  const _NewChat({required this.controller, required this.close});
  final AlphaController controller;
  final VoidCallback close;
  @override
  State<_NewChat> createState() => _NewChatState();
}

class _NewChatState extends State<_NewChat> {
  final field = TextEditingController();
  bool busy = false;
  String error = '';
  // Правила регистрации: 3–32 символа, латинские буквы, цифры и _.
  static final _nickname = RegExp(r'^[a-zA-Z0-9_]{3,32}$');
  String get value => field.text.trim().replaceFirst(RegExp(r'^@'), '').trim();
  bool get valid => _nickname.hasMatch(value);
  @override
  void dispose() {
    field.dispose();
    super.dispose();
  }

  Future<void> _find() async {
    if (!valid || busy) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await widget.controller.act('find', {'account': value.toLowerCase()});
      // Мост уже открыл чат (selected): закрываем экран поиска.
      if (mounted) widget.close();
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = e is StateError
              ? e.message
              : 'Не удалось найти собеседника. Проверьте сеть и повторите.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(children: [
        Row(children: [
          IconButton(
              tooltip: 'Назад',
              onPressed: widget.close,
              icon: const Icon(Icons.chevron_left_rounded)),
          const Text('Новый разговор',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        ]),
        Expanded(
            child: Center(
                child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: ListView(
                        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                        children: [
                          const Text('Найдите своих',
                              style: TextStyle(
                                  fontSize: 32,
                                  height: 1.15,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -1)),
                          const SizedBox(height: 10),
                          Text(
                              'Введите точный никнейм друга в Shade. Имена аккаунтов состоят из латинских букв, цифр и _.',
                              style: TextStyle(
                                  fontSize: 14,
                                  height: 1.5,
                                  color: context
                                      .shadeColor(ShadeColors.textSecondary))),
                          const SizedBox(height: 24),
                          Semantics(
                              label: 'Никнейм собеседника',
                              textField: true,
                              child: TextField(
                                  key: const Key('new-chat-field'),
                                  controller: field,
                                  autofocus: true,
                                  enabled: !busy,
                                  maxLength: 32,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  textInputAction: TextInputAction.search,
                                  onSubmitted: (_) => _find(),
                                  onChanged: (_) => setState(() => error = ''),
                                  style: const TextStyle(fontSize: 16),
                                  decoration: InputDecoration(
                                      hintText: 'Никнейм собеседника',
                                      counterText: '',
                                      prefixText: '@ ',
                                      prefixStyle: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                          color: context.shadeColor(
                                              ShadeColors.textMuted)),
                                      suffixIcon: value.isEmpty
                                          ? null
                                          : IconButton(
                                              tooltip: 'Очистить поле',
                                              onPressed: () {
                                                field.clear();
                                                setState(() {});
                                              },
                                              icon: const Icon(
                                                  Icons.close_rounded,
                                                  size: 18))))),
                          if (value.isNotEmpty && !valid)
                            Padding(
                                padding: EdgeInsets.only(top: 8),
                                child: Text(
                                    'От 3 до 32 символов: латинские буквы, цифры и _',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: context.shadeColor(
                                            ShadeColors.textMuted)))),
                          if (error.isNotEmpty)
                            Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Semantics(
                                    liveRegion: true,
                                    child: Row(children: [
                                      const Icon(Icons.error_outline_rounded,
                                          size: 16, color: Color(0xFFEF4444)),
                                      const SizedBox(width: 6),
                                      Expanded(
                                          child: Text(error,
                                              style: const TextStyle(
                                                  fontSize: 13,
                                                  height: 1.4,
                                                  color: Color(0xFFEF4444)))),
                                    ]))),
                          const SizedBox(height: 16),
                          SizedBox(
                              width: double.infinity,
                              height: 52,
                              child: FilledButton(
                                  key: const Key('new-chat-find'),
                                  onPressed: valid && !busy ? _find : null,
                                  style: FilledButton.styleFrom(
                                      shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(18))),
                                  child: busy
                                      ? const Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                              SizedBox(
                                                  width: 18,
                                                  height: 18,
                                                  child:
                                                      CircularProgressIndicator(
                                                          strokeWidth: 2,
                                                          color: Colors.black)),
                                              SizedBox(width: 10),
                                              Text('Ищем…'),
                                            ])
                                      : const Text('Найти собеседника',
                                          style: TextStyle(
                                              fontSize: 15,
                                              fontWeight: FontWeight.w700)))),
                          const SizedBox(height: 28),
                          // Подсказка под формой: что делать, если никнейм неизвестен.
                          Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                    width: 56,
                                    height: 56,
                                    decoration: BoxDecoration(
                                        color: context.shadeColor(
                                            ShadeColors.surfaceCard),
                                        borderRadius: BorderRadius.circular(18),
                                        border: Border.all(
                                            color: context.shadeColor(
                                                ShadeColors.greyBorder))),
                                    child: Icon(Icons.alternate_email_rounded,
                                        size: 26,
                                        color: context.shadeColor(
                                            ShadeColors.textSecondary))),
                                const SizedBox(width: 14),
                                Expanded(
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                      Text('Одно имя — и вы на связи',
                                          style: TextStyle(
                                              fontSize: 15,
                                              fontWeight: FontWeight.w700)),
                                      SizedBox(height: 4),
                                      Text(
                                          'Попросите друга поделиться никнеймом. Ваш собственный никнейм есть в профиле.',
                                          style: TextStyle(
                                              fontSize: 13,
                                              height: 1.5,
                                              color: context.shadeColor(
                                                  ShadeColors.textMuted))),
                                    ])),
                              ]),
                        ])))),
      ]);
}

class _Profile extends StatelessWidget {
  const _Profile({
    required this.controller,
    required this.close,
    this.showSettings = true,
    this.settingsOnly = false,
  });
  final bool showSettings;
  final bool settingsOnly;
  final AlphaController controller;
  final VoidCallback close;

  String get displayName => controller.profile['displayName'] as String? ?? '';

  // Identicon seed: sha256 over the SPKI public key, hex-projected by
  // alpha-ui.mjs (Android key-card parity). Empty until the vault unlocks.
  List<int> get _identiconBytes {
    final seed = controller.key?['seed'] as String?;
    if (seed == null || seed.isEmpty) return const [];
    final bytes = <int>[];
    for (var i = 0; i + 1 < seed.length; i += 2) {
      bytes.add(int.parse(seed.substring(i, i + 2), radix: 16));
    }
    return bytes;
  }

  // Card preview: the first four hex groups of the genesis digest, like the
  // Android 'Ключ шифрования' row. The full grouped code lives in the dialog.
  String get _fingerprintPreview {
    final hex = (controller.key?['digest'] as String? ?? '').toUpperCase();
    if (hex.length < 16) return 'Отпечаток формируется…';
    return '${[
      hex.substring(0, 4),
      hex.substring(4, 8),
      hex.substring(8, 12),
      hex.substring(12, 16)
    ].join(' ')}…';
  }

  Future<void> _editAvatar(BuildContext context) async {
    final frame = AvatarFrame.values.firstWhere(
      (f) => f.name == controller.profile['frame'],
      orElse: () => AvatarFrame.none,
    );
    final bytes = await controller.avatarImage(
      controller.profile['digest'] as String? ?? '',
    );
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AlphaAvatarEditor(
          initialImage: bytes,
          initialName: displayName.isEmpty ? controller.account : displayName,
          initialFrame: frame,
          save: ({required frame, required replaceImage, image}) =>
              controller.act('profile.save', {
            'frame': frame.name,
            if (replaceImage)
              'avatar': image == null ? null : base64Encode(image),
          }),
        ),
      ),
    );
  }

  Future<void> _editName(BuildContext context) async {
    final field = TextEditingController(text: displayName);
    final updated = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Отображаемое имя'),
        content: TextField(
          controller: field,
          autofocus: true,
          maxLength: 64,
          style: const TextStyle(fontSize: 15, height: 1.5),
          decoration: const InputDecoration(
            hintText: 'Как вас видят собеседники',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog, field.text),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (updated == null || !context.mounted) return;
    if (updated.trim() == displayName) return;
    try {
      await controller.act('profile.save', {'displayName': updated});
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Не удалось сохранить имя. Проверьте сеть и повторите.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _confirmLogout(
    BuildContext context,
    AlphaController controller,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Выйти из аккаунта?'),
        content: const Text(
          'Сессия Google завершится. Ключи и история останутся в этом '
          'браузере; для входа понадобится фраза устройства.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Выйти'),
          ),
        ],
      ),
    );
    if (confirmed == true) await controller.act('logout');
  }

  Future<void> _confirmRevoke(
    BuildContext context,
    AlphaController controller,
    String id,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Отозвать устройство?'),
        content: const Text(
          'Очередь и push-подписка устройства будут удалены. '
          'Действие необратимо: ключи отозванного устройства больше '
          'не смогут получать сообщения.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Отозвать'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await controller.act('devices.revoke', {'id': id});
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Не удалось отозвать устройство. Проверьте сеть и повторите.',
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = controller.account;
    final visibleName = displayName.isNotEmpty
        ? displayName
        : name.isEmpty
            ? 'Shade'
            : name[0].toUpperCase() + name.substring(1);
    final back = IconButton(
      tooltip: 'Назад',
      onPressed: close,
      icon: const Icon(Icons.chevron_left_rounded),
    );
    return CustomScrollView(
      slivers: [
        if (settingsOnly)
          SliverAppBar(
            pinned: true,
            primary: false,
            leading: back,
            title: const Text('Настройки'),
          )
        else
          ShadeProfileHeader(
            visibleName: visibleName,
            handle: '@$name',
            leading: back,
            smallAvatar: AccountAvatar(
              controller: controller,
              account: name,
              size: 34,
            ),
            largeAvatar: ShadeAvatarEdit(
              avatar: AccountAvatar(
                controller: controller,
                account: name,
                size: 108,
              ),
              onTap: () => _editAvatar(context),
            ),
          ),
        SliverToBoxAdapter(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  20,
                  settingsOnly ? 8 : 4,
                  20,
                  32 + MediaQuery.paddingOf(context).bottom,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (settingsOnly) const Card(child: ShadeAppearanceTile()),
                    if (!settingsOnly) ...[
                      Row(
                        children: [
                          Expanded(
                            child: ShadeProfileAction(
                              Icons.edit_outlined,
                              'Имя',
                              () => _editName(context),
                              primary: true,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: ShadeProfileAction(
                              Icons.copy_outlined,
                              'Скопировать',
                              () async {
                                await Clipboard.setData(
                                  ClipboardData(text: '@${controller.account}'),
                                );
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Имя пользователя скопировано',
                                      ),
                                    ),
                                  );
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: ShadeProfileAction(
                              Icons.qr_code_2_rounded,
                              'Мой ключ',
                              () => controller.act('identity'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 22),
                      const ShadeProfileSection('Информация'),
                      const SizedBox(height: 8),
                      ShadeProfileCard(
                        children: [
                          ListTile(
                            leading: const Icon(Icons.add_a_photo_outlined),
                            title: const Text('Изменить аватар'),
                            trailing: const Icon(Icons.chevron_right_rounded),
                            onTap: () => _editAvatar(context),
                          ),
                          ListTile(
                            leading: const Icon(Icons.alternate_email_rounded),
                            title: Text('@${controller.account}'),
                            subtitle: const Text('Имя пользователя'),
                          ),
                          if (controller.email != null) ...[
                            ListTile(
                              leading: const Icon(Icons.mail_outline_rounded),
                              title: Text(
                                controller.email!,
                                style: const TextStyle(fontSize: 15),
                              ),
                              subtitle: const Text('Google-аккаунт'),
                            ),
                          ],
                          const ListTile(
                            leading: Icon(Icons.phone_iphone_rounded),
                            title: Text('Это устройство'),
                            subtitle: Text(
                              'Приватный ключ не покидает браузер',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'ШИФРОВАНИЕ',
                        style: TextStyle(
                          fontSize: 11,
                          letterSpacing: 1.5,
                          color: context.shadeColor(ShadeColors.textMuted),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Card(
                        clipBehavior: Clip.antiAlias,
                        child: Semantics(
                          button: true,
                          child: InkWell(
                            onTap: () => controller.act('identity'),
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Row(
                                children: [
                                  _KeyIdenticon(
                                    bytes: _identiconBytes,
                                    size: 52,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            const Expanded(
                                              child: Text(
                                                'Ключ шифрования',
                                                style: TextStyle(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ),
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 8,
                                                vertical: 4,
                                              ),
                                              decoration: BoxDecoration(
                                                color: context.shadeColor(
                                                    ShadeColors
                                                        .surfaceElevated),
                                                borderRadius:
                                                    BorderRadius.circular(20),
                                              ),
                                              child: Text(
                                                'Ваш',
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w600,
                                                  color: context.shadeColor(
                                                      ShadeColors.textPrimary),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          _fingerprintPreview,
                                          style: TextStyle(
                                            fontFamily: 'monospace',
                                            fontSize: 12,
                                            letterSpacing: 1.2,
                                            color: context.shadeColor(
                                                ShadeColors.textSecondary),
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          'Нажмите, чтобы показать код',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: context.shadeColor(
                                                ShadeColors.textMuted),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Icon(
                                    Icons.chevron_right_rounded,
                                    color: context
                                        .shadeColor(ShadeColors.textMuted),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.file_download_outlined),
                          title: const Text('Recovery-пакет'),
                          subtitle: const Text('Сохранить зашифрованную копию'),
                          onTap: () => controller.act('backup'),
                        ),
                      ),
                      if (controller.profile['canSaveRecovery'] == true)
                        Card(
                          child: ListTile(
                            leading: const Icon(Icons.cloud_outlined),
                            title: Text(
                              controller.profile['cloudRecoverySaved'] == true
                                  ? 'Копия сохранена на сервере'
                                  : 'Сохранить копию на сервере',
                            ),
                            onTap:
                                controller.profile['cloudRecoverySaved'] == true
                                    ? null
                                    : () => controller.act('backup.cloud'),
                          ),
                        ),
                      const SizedBox(height: 24),
                      Text(
                        'ПОДАРКИ · ВИНИЛОВАЯ СТЕНА',
                        style: TextStyle(
                          fontSize: 11,
                          letterSpacing: 1.5,
                          color: context.shadeColor(ShadeColors.textMuted),
                        ),
                      ),
                      const SizedBox(height: 4),
                      StickerCollection(
                        username: controller.account,
                        owner: true,
                        backend: AlphaStickerBackend(controller),
                      ),
                      const SizedBox(height: 24),
                    ],
                    if (showSettings) ...[
                      Text(
                        'ПОДКЛЮЧЁННЫЕ УСТРОЙСТВА',
                        style: TextStyle(
                          fontSize: 11,
                          letterSpacing: 1.5,
                          color: context.shadeColor(ShadeColors.textMuted),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Card(
                        child: Column(
                          children: controller.devices
                              .map(
                                (d) => ListTile(
                                  leading: Icon(
                                    d['current'] == true
                                        ? Icons.devices_rounded
                                        : Icons.phonelink_rounded,
                                  ),
                                  title: Text(
                                    d['name'] as String? ??
                                        (d['current'] == true
                                            ? 'Этот браузер'
                                            : 'Устройство'),
                                    style: const TextStyle(fontSize: 15),
                                  ),
                                  subtitle: Text(
                                    d['id'] as String,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: context
                                          .shadeColor(ShadeColors.textMuted),
                                    ),
                                  ),
                                  trailing: d['current'] == true
                                      ? null
                                      : PopupMenuButton<String>(
                                          tooltip: 'Действия с устройством',
                                          onSelected: (action) async {
                                            final id = d['id'] as String;
                                            if (action == 'revoke') {
                                              await _confirmRevoke(
                                                context,
                                                controller,
                                                id,
                                              );
                                              return;
                                            }
                                            try {
                                              await controller.act(
                                                'history.send',
                                                {'id': id},
                                              );
                                            } catch (_) {
                                              // The browser bridge presents the server error.
                                            }
                                          },
                                          itemBuilder: (_) => const [
                                            PopupMenuItem(
                                              value: 'history',
                                              child: Text(
                                                'Передать переписку на Android',
                                              ),
                                            ),
                                            PopupMenuItem(
                                              value: 'revoke',
                                              child: Text(
                                                'Отозвать устройство',
                                              ),
                                            ),
                                          ],
                                        ),
                                ),
                              )
                              .toList(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.add_link_rounded),
                          title: const Text(
                            'Добавить устройство',
                            style: TextStyle(fontSize: 15),
                          ),
                          subtitle: Text(
                            'Код подключения → подтверждение запроса',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: context.shadeColor(ShadeColors.textMuted),
                            ),
                          ),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => controller.act('devices.pair'),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Card(
                        child: ListTile(
                          leading: const Icon(Icons.notifications_outlined),
                          title: const Text('Уведомления'),
                          subtitle: Text(switch (controller.platform) {
                            'ios' =>
                              'Push-сигнал без текста · iOS: установленное приложение',
                            'android' =>
                              'Push-сигнал без текста · Android: разрешение уведомлений',
                            _ =>
                              'Push-сигнал без текста · разрешите уведомления в браузере',
                          }),
                          onTap: () => controller.act('push.toggle'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: () => controller.act('install'),
                        icon: const Icon(Icons.ios_share_rounded),
                        label: const Text('Установить Shade'),
                      ),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: () => _confirmLogout(context, controller),
                        child: const Text('Выйти из аккаунта'),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'Ключи и история остаются в этом браузере.\nНе очищайте данные сайта без recovery-пакета.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.6,
                          color: context.shadeColor(ShadeColors.textMuted),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PeerProfile extends StatelessWidget {
  const _PeerProfile(
      {required this.controller, required this.peer, required this.openChat});
  final AlphaController controller;
  final String peer;
  final VoidCallback openChat;

  Future<void> _editNote(BuildContext context) async {
    final current = controller.notes[peer] as String? ?? '';
    final field = TextEditingController(text: current);
    final updated = await showDialog<String>(
        context: context,
        builder: (dialog) => AlertDialog(
                title: const Text('Личная заметка'),
                content: TextField(
                    controller: field,
                    autofocus: true,
                    maxLines: 4,
                    maxLength: 2000,
                    style: const TextStyle(fontSize: 15, height: 1.5),
                    decoration: const InputDecoration(
                        hintText: 'Заметка о собеседнике')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialog),
                      child: const Text('Отмена')),
                  TextButton(
                      onPressed: () => Navigator.pop(dialog, field.text),
                      child: const Text('Сохранить')),
                ]));
    if (updated == null || !context.mounted) return;
    if (updated.trim() == current) return;
    try {
      await controller.act('note', {'account': peer, 'text': updated});
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Не удалось сохранить заметку. Проверьте сеть и повторите.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final pinned = c.pinned(peer);
    final tofu = c.unverified(peer);
    final messages = c.conversation(peer).length;
    final note = c.notes[peer] as String? ?? '';
    final presence = c.presence[peer];
    final online = presence is Map && presence['online'] == true;
    final lastSeen =
        (presence is Map ? presence['lastSeen'] as num? : null)?.toInt() ?? 0;
    final statusLine = online
        ? 'В сети'
        : lastSeen > 0
            ? _lastSeenLine(lastSeen)
            : null;
    return Column(children: [
      Row(children: [
        IconButton(
            tooltip: 'Назад к переписке',
            onPressed: openChat,
            icon: const Icon(Icons.chevron_left_rounded)),
        const Flexible(
            child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text('Профиль собеседника',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w700)))),
      ]),
      Expanded(
          child: Center(
              child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: ListView(padding: const EdgeInsets.all(24), children: [
                    Center(
                        child: AccountAvatar(
                            controller: c, account: peer, size: 100)),
                    const SizedBox(height: 20),
                    Text(c.peerName(peer),
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 28, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    Text('@$peer',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: context.shadeColor(ShadeColors.textMuted))),
                    if (statusLine != null) ...[
                      const SizedBox(height: 4),
                      Text(statusLine,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 13,
                              color:
                                  context.shadeColor(ShadeColors.textMuted))),
                    ],
                    const SizedBox(height: 32),
                    Text('ПЕРЕПИСКА И БЕЗОПАСНОСТЬ',
                        style: TextStyle(
                            fontSize: 11,
                            letterSpacing: 1.5,
                            color: context.shadeColor(ShadeColors.textMuted))),
                    const SizedBox(height: 12),
                    Card(
                        child: Column(children: [
                      // Три состояния доверия: сверен вручную, TOFU, не закреплён.
                      ListTile(
                          leading: Icon(
                              pinned && !tofu
                                  ? Icons.verified_user_outlined
                                  : Icons.shield_outlined,
                              color: pinned && !tofu
                                  ? context.shadeColor(ShadeColors.cyan)
                                  : context
                                      .shadeColor(ShadeColors.textSecondary)),
                          title: Text(pinned && !tofu
                              ? 'Ключ собеседника проверен'
                              : tofu
                                  ? 'Ключ не сверен'
                                  : 'Ключ ещё не проверен'),
                          subtitle: Text(pinned && !tofu
                              ? 'Отпечаток закреплён за этим аккаунтом'
                              : tofu
                                  ? 'Закреплён автоматически при первом контакте. Сверьте отпечаток через доверенный канал.'
                                  : 'Сверьте отпечатки через независимый доверенный канал'),
                          trailing: tofu
                              ? TextButton(
                                  onPressed: () =>
                                      c.act('verify', {'account': peer}),
                                  child: const Text('Сверить'))
                              : const Icon(Icons.chevron_right_rounded),
                          onTap: () => c.act('verify', {'account': peer})),
                      const Divider(height: 1, indent: 56),
                      ListTile(
                          leading: const Icon(Icons.forum_outlined),
                          title: Text('$messages'),
                          subtitle: const Text('Сообщений в переписке')),
                      const Divider(height: 1, indent: 56),
                      ListTile(
                          leading: const Icon(Icons.sticky_note_2_outlined),
                          title: Text(note.isEmpty
                              ? 'Добавить заметку'
                              : 'Личная заметка'),
                          subtitle: Text(
                              note.isEmpty
                                  ? 'Только для себя · зашифровано на этом устройстве'
                                  : note,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => _editNote(context)),
                      const Divider(height: 1, indent: 56),
                      ListTile(
                          leading: const Icon(Icons.copy_rounded),
                          title: const Text('Копировать ник'),
                          onTap: () async {
                            await Clipboard.setData(ClipboardData(text: peer));
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text('Никнейм скопирован')));
                            }
                          }),
                    ])),
                    const SizedBox(height: 24),
                    Text('ПОДАРКИ · ВИНИЛОВАЯ СТЕНА',
                        style: TextStyle(
                            fontSize: 11,
                            letterSpacing: 1.5,
                            color: context.shadeColor(ShadeColors.textMuted))),
                    StickerCollection(
                        username: peer,
                        owner: false,
                        backend: AlphaStickerBackend(controller)),
                    const SizedBox(height: 20),
                    OutlinedButton.icon(
                        onPressed: openChat,
                        icon: const Icon(Icons.chat_bubble_outline_rounded),
                        label: const Text('Открыть переписку')),
                    const SizedBox(height: 20),
                    Text(
                        'Shade подтверждает ключи только вашей личной сверкой.\nGoogle и сервер не гарантируют личность собеседника.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12,
                            height: 1.6,
                            color: context.shadeColor(ShadeColors.textMuted))),
                  ])))),
    ]);
  }
}

/// Avatar for any account: the signed-in user resolves through the local
/// profile projection, peers through the v2 profile adapter (display name,
/// frame and bytes keyed by the projected digest). Accounts without a v2
/// avatar stay initials by design.
class AccountAvatar extends StatefulWidget {
  const AccountAvatar(
      {super.key,
      required this.controller,
      required this.account,
      required this.size,
      this.favorites = false});
  final AlphaController controller;
  final String account;
  final double size;
  final bool favorites;
  @override
  State<AccountAvatar> createState() => _AccountAvatarState();
}

class _AccountAvatarState extends State<AccountAvatar> {
  Uint8List? bytes;
  String loadedDigest = '';
  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    if (widget.favorites) {
      return AvatarView(name: '', saved: true, size: widget.size);
    }
    if (widget.account == c.account) {
      final frame = AvatarFrame.values.firstWhere(
          (f) => f.name == c.profile['frame'],
          orElse: () => AvatarFrame.none);
      final digest = c.profile['digest'] as String? ?? '';
      _load(digest, () => c.avatarImage(digest));
      return AvatarView(
          name: c.account, image: bytes, frame: frame, size: widget.size);
    }
    final peer = c.peers
        .where((p) => p['account'] == widget.account)
        .fold<Map<String, dynamic>?>(null, (acc, p) => p);
    final frame = AvatarFrame.values.firstWhere(
        (f) => f.name == (peer?['frame'] ?? 'none'),
        orElse: () => AvatarFrame.none);
    final digest = peer?['avatarDigest'] as String? ?? '';
    _load(digest, () => c.peerAvatarBytes(widget.account, digest));
    return AvatarView(
        name: c.peerName(widget.account),
        image: bytes,
        frame: bytes == null ? frame : AvatarFrame.none,
        size: widget.size);
  }

  void _load(String digest, Future<Uint8List?> Function() fetch) {
    if (digest != loadedDigest) {
      loadedDigest = digest;
      bytes = null;
      if (digest.isNotEmpty) {
        fetch().then((value) {
          if (mounted && loadedDigest == digest) {
            setState(() => bytes = value);
          }
        });
      }
    }
  }
}

// Subtle conversation backdrop matching the Android chat texture: a staggered
// grid of tiny circles and crosses over a near-black diagonal gradient
// (AMOLED — barely visible, never competes with the bubbles).
class _ConversationPatternPainter extends CustomPainter {
  const _ConversationPatternPainter({required this.light});
  final bool light;
  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()
      ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(size.width, size.height),
          light
              ? const [Color(0xFFFFFFFF), Color(0xFFF7F8F9)]
              : const [Color(0xFF0C0C0C), Color(0xFF101010)]);
    canvas.drawRect(Offset.zero & size, bg);
    final mark = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = light ? const Color(0xFFE9EDF1) : const Color(0xFF232326);
    const stepX = 91.0, circleToCross = 39.0, crossToCircle = 52.0, half = 45.5;
    var y = 26.0;
    var circleRow = true;
    while (y < size.height + 10) {
      final offset = circleRow ? 0.0 : half;
      for (var x = offset; x < size.width + 10; x += stepX) {
        if (circleRow) {
          canvas.drawCircle(Offset(x, y), 2.2, mark);
        } else {
          const r = 3.2;
          canvas.drawLine(Offset(x - r, y - r), Offset(x + r, y + r), mark);
          canvas.drawLine(Offset(x - r, y + r), Offset(x + r, y - r), mark);
        }
      }
      y += circleRow ? circleToCross : crossToCircle;
      circleRow = !circleRow;
    }
  }

  @override
  bool shouldRepaint(covariant _ConversationPatternPainter oldDelegate) =>
      oldDelegate.light != light;
}

// Key-card identicon, ported from the Android profile_screen.dart painter:
// an 8×8 grid where each cell takes a nibble of the seed bytes (high nibble
// on even cells, low on odd) mapped to a four-step grey palette.
class _KeyIdenticon extends StatelessWidget {
  final List<int> bytes;
  final double size;
  const _KeyIdenticon({required this.bytes, required this.size});

  @override
  Widget build(BuildContext context) => ClipRRect(
      borderRadius: BorderRadius.circular(size > 100 ? 14 : 10),
      child: CustomPaint(
          size: Size.square(size), painter: _IdenticonPainter(bytes)));
}

class _IdenticonPainter extends CustomPainter {
  final List<int> bytes;
  const _IdenticonPainter(this.bytes);

  static const _colors = [
    Color(0xFF2A2A2A),
    Color(0xFF5C5C5C),
    Color(0xFF9E9E9E),
    Color(0xFFEDEDED),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / 8;
    final paint = Paint();
    for (var i = 0; i < 64; i++) {
      final byte = bytes.isEmpty ? 0 : bytes[(i >> 1) % bytes.length];
      final nibble = i.isEven ? byte >> 4 : byte & 0x0F;
      paint.color = _colors[nibble & 0x03];
      canvas.drawRect(
          Rect.fromLTWH((i % 8) * cell, (i >> 3) * cell, cell + .5, cell + .5),
          paint);
    }
  }

  @override
  bool shouldRepaint(covariant _IdenticonPainter oldDelegate) =>
      oldDelegate.bytes != bytes;
}

import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shade/core/theme/shade_theme.dart';
import 'package:shade/core/widgets/avatar_frame.dart';
import 'package:shade/core/widgets/avatar_view.dart';
import 'package:shade/core/widgets/shade_logo.dart';
import 'package:shade/core/widgets/shade_motion.dart';
import 'package:shade/core/widgets/shade_states.dart';
import 'package:shade/features/chats/presentation/widgets/message_bubble.dart';
import 'package:shade/features/chats/presentation/widgets/message_input.dart';
import 'package:shade/features/stickers/collection.dart';
import 'alpha_avatar_editor.dart';
import 'alpha_controller.dart';
import 'alpha_sticker_backend.dart';
import 'recovery_screen.dart';

class ShadeAlphaApp extends StatelessWidget {
  const ShadeAlphaApp({super.key, required this.controller});
  final AlphaController controller;
  @override
  Widget build(BuildContext context) => MaterialApp(
      title: 'Shade',
      debugShowCheckedModeBanner: false,
      theme: buildShadeTheme().copyWith(
          textTheme: buildShadeTheme()
              .textTheme
              .apply(fontFamilyFallback: const ['ShadeEmoji'])),
      home: ListenableBuilder(
          listenable: controller,
          // Режим восстановления: отдельный экран до появления device-сессии.
          builder: (_, __) => controller.recovery != null
              ? RecoveryScreen(controller: controller)
              : _Shell(controller: controller)));
}

class _Shell extends StatefulWidget {
  const _Shell({required this.controller});
  final AlphaController controller;
  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  bool profile = false;
  bool peerProfile = false;
  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return LayoutBuilder(builder: (context, bounds) {
      final wide = bounds.maxWidth >= 900;
      final right = profile
          ? _Profile(
              controller: c, close: () => setState(() => profile = false))
          : peerProfile && c.selected != null
              ? _PeerProfile(
                  controller: c,
                  peer: c.selected!,
                  openChat: () => setState(() => peerProfile = false))
              : _Conversation(
                  key: ValueKey(c.selected),
                  controller: c,
                  back: () => c.act('back'),
                  openPeer: () => setState(() => peerProfile = true));
      return PopScope(
          canPop: c.selected == null && !profile && !peerProfile,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) {
              if (peerProfile) {
                setState(() => peerProfile = false);
              } else if (profile) {
                setState(() => profile = false);
              } else {
                c.act('back');
              }
            }
          },
          child: Scaffold(
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
                                          openChat: () => setState(() {
                                                profile = false;
                                                peerProfile = false;
                                              }),
                                          profile: () => setState(
                                              () => profile = !profile))),
                                  const VerticalDivider(width: 1),
                                  Expanded(child: right),
                                ])
                              : AnimatedSwitcher(
                                  duration: ShadeMotion.duration(context),
                                  child: profile ||
                                          peerProfile && c.selected != null ||
                                          c.selected != null
                                      ? right
                                      : _Chats(
                                          controller: c,
                                          openChat: () => setState(() {
                                                profile = false;
                                                peerProfile = false;
                                              }),
                                          profile: () => setState(
                                              () => profile = true))))))));
    });
  }
}

class _Chats extends StatefulWidget {
  const _Chats(
      {required this.controller,
      required this.profile,
      required this.openChat});
  final AlphaController controller;
  final VoidCallback profile, openChat;
  @override
  State<_Chats> createState() => _ChatsState();
}

class _ChatsState extends State<_Chats> {
  final search = TextEditingController();
  final seenAccounts = <String>{};
  bool directory = false;
  bool savedOnly = false;
  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final query = search.text.trim().toLowerCase();
    final peers = c.peers.where((p) {
      final account = p['account'] as String;
      final items = c.conversation(account);
      final hasChat =
          items.isNotEmpty || p['pinned'] == true || p['unverified'] == true;
      return (directory || hasChat) &&
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
    return Stack(children: [
      Column(children: [
      Expanded(
          child: CustomScrollView(slivers: [
        SliverToBoxAdapter(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
              padding: const EdgeInsets.fromLTRB(24, 14, 14, 0),
              child: Row(children: [
                const ShadeLogo(size: 28),
                const SizedBox(width: 10),
                const Flexible(
                    child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text('SHADE',
                            style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 3.2)))),
                const Spacer(),
                IconButton(
                    tooltip: 'Профиль',
                    onPressed: widget.profile,
                    icon: AccountAvatar(controller: c, account: c.account, size: 34)),
                IconButton(
                    tooltip: 'Найти собеседника',
                    onPressed: () {
                      setState(() => directory = !directory);
                      c.act('refresh');
                    },
                    icon: Icon(
                        directory ? Icons.close_rounded : Icons.edit_square,
                        size: 22)),
              ])),
          Padding(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 18),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(directory ? 'Новый диалог' : 'Сообщения',
                        style: const TextStyle(
                            fontSize: 34,
                            height: 1.15,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -1.3)),
                    const SizedBox(height: 10),
                    const Row(children: [
                      Icon(Icons.lock_outline_rounded,
                          size: 14, color: ShadeColors.textMuted),
                      SizedBox(width: 6),
                      Expanded(
                          child: Text('Личное остаётся личным',
                              style: TextStyle(
                                  fontSize: 12,
                                  height: 1.4,
                                  color: ShadeColors.textMuted))),
                    ]),
                    const SizedBox(height: 24),
                    TextField(
                        controller: search,
                        onChanged: (_) => setState(() {}),
                        style: const TextStyle(fontSize: 16),
                        decoration: InputDecoration(
                            hintText: directory
                                ? 'Найти пользователя'
                                : 'Поиск в переписках',
                            prefixIcon:
                                const Icon(Icons.search_rounded, size: 21),
                            suffixIcon: query.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: 'Очистить поиск',
                                    onPressed: () {
                                      search.clear();
                                      setState(() {});
                                    },
                                    icon: const Icon(Icons.close_rounded,
                                        size: 18)))),
                  ])),
          if (directory)
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(children: [
                  const Expanded(
                      child: Text('ПОЛЬЗОВАТЕЛИ SHADE',
                          style: TextStyle(
                              fontSize: 10,
                              letterSpacing: 1.5,
                              color: ShadeColors.textMuted,
                              fontWeight: FontWeight.w700))),
                  IconButton(
                      tooltip: 'Обновить список',
                      onPressed: () => c.act('refresh'),
                      icon: const Icon(Icons.refresh_rounded, size: 18)),
                ]))
          else
            Padding(
                padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
                child: Wrap(spacing: 8, children: [
                  _homeFilter('Все чаты', false),
                  _homeFilter('Избранное', true),
                ])),
        ])),
        if (peers.isEmpty)
          SliverToBoxAdapter(
              child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 36),
                  child: Column(children: [
                    ShadeEmptyState(
                        icon: query.isEmpty
                            ? Icons.chat_bubble_outline_rounded
                            : Icons.search_off_rounded,
                        title: query.isEmpty
                            ? 'Здесь начнётся общение'
                            : 'Ничего не нашлось',
                        description: query.isEmpty
                            ? 'Найдите друга по никнейму\nи отправьте первое сообщение.'
                            : 'Попробуйте другое имя или слово из сообщения.'),
                    if (query.isEmpty)
                      Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: OutlinedButton.icon(
                              onPressed: () {
                                setState(() => directory = true);
                                c.act('refresh');
                              },
                              icon: const Icon(Icons.person_search_rounded),
                              label: const Text('Найти собеседника'))),
                  ])))
        else
          SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              sliver: SliverList.separated(
                  itemCount: peers.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1, indent: 80, endIndent: 12),
                  itemBuilder: (context, i) {
                    final peer = peers[i]['account'] as String;
                    final latest = c.conversation(peer).lastOrNull;
                    final unread = c.unread(peer);
                    // Android animates only genuinely new tiles; a stable key
                    // keeps an existing row from replaying its entrance.
                    return TweenAnimationBuilder<double>(
                        key: ValueKey(peer),
                        tween: Tween(
                            begin: seenAccounts.add(peer) ? 0 : 1, end: 1),
                        duration: ShadeMotion.duration(context, 200),
                        curve: Curves.easeOut,
                        builder: (context, t, child) => Opacity(
                            opacity: t,
                            child: Transform.translate(
                                offset: Offset(0, 14 * (1 - t)),
                                child: child)),
                        child: ListTile(
                        selected: c.selected == peer,
                        selectedTileColor: ShadeColors.surfaceCard,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18)),
                        horizontalTitleGap: 15,
                        leading: AccountAvatar(
                            controller: c,
                            account: peer,
                            size: 54,
                            favorites: peer == c.account),
                        onTap: () {
                          widget.openChat();
                          c.act('select', {'account': peer});
                        },
                        title: Row(children: [
                          Expanded(
                              child: Text(c.peerName(peer),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700))),
                          if (latest != null) ...[
                            const SizedBox(width: 8),
                            Text(_time(latest),
                                style: const TextStyle(
                                    fontSize: 11, color: ShadeColors.textMuted))
                          ]
                        ]),
                        subtitle: Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Row(children: [
                              if (latest != null &&
                                  latest['from'] == c.account) ...[
                                Icon(
                                    AlphaController.status(latest) == 'read' ||
                                            AlphaController.status(latest) ==
                                                'delivered'
                                        ? Icons.done_all_rounded
                                        : AlphaController.status(latest) ==
                                                'queued'
                                            ? Icons.schedule_rounded
                                            : Icons.done_rounded,
                                    size: 15,
                                    color: ShadeColors.textMuted),
                                const SizedBox(width: 4)
                              ],
                              Expanded(
                                  child: Text(
                                      latest?['text'] as String? ??
                                          (latest?['media'] != null
                                              ? '📷 Фото'
                                              : (c.pinned(peer)
                                                  ? 'Отправьте первое сообщение'
                                                  : 'Сверьте отпечаток ключа')),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          fontSize: 13,
                                          height: 1.4,
                                          color: ShadeColors.textMuted))),
                              if (unread > 0)
                                Container(
                                    margin: const EdgeInsets.only(left: 8),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 7, vertical: 3),
                                    decoration: BoxDecoration(
                                        color: ShadeColors.textPrimary,
                                        borderRadius:
                                            BorderRadius.circular(10)),
                                    child: Text(unread > 99 ? '99+' : '$unread',
                                        semanticsLabel: '$unread непрочитанных',
                                        style: const TextStyle(
                                            fontSize: 11,
                                            color: Colors.black,
                                            fontWeight: FontWeight.w700))),
                            ]))));
                  })),
      ])),
      SafeArea(
          top: false,
          child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 14, 16, 14),
              child: Row(children: [
                const Icon(Icons.lock_outline_rounded,
                    size: 14, color: ShadeColors.textMuted),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(c.connection,
                        maxLines: 2,
                        style: const TextStyle(
                            fontSize: 11, color: ShadeColors.textMuted))),
                if (!c.connected)
                  Flexible(
                      child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: TextButton(
                              onPressed: () => c.act('sync'),
                              child: const Text('Повторить')))),
              ]))),
      ]),
      if (!directory)
        Positioned(
            right: 16,
            bottom: 58,
            child: FloatingActionButton.extended(
                elevation: 0,
                heroTag: 'alpha-compose',
                backgroundColor: const Color(0xFFF5F5F7),
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20)),
                onPressed: () {
                  setState(() => directory = true);
                  c.act('refresh');
                },
                icon: const Icon(Icons.edit_outlined, size: 20),
                label: const Text('Написать',
                    style: TextStyle(fontWeight: FontWeight.w700)))),
    ]);
  }

  // Android home filters (home_screen.dart _filter): selected chip fills
  // light with black text, idle chip stays dark with the hairline border.
  Widget _homeFilter(String title, bool saved) => ChoiceChip(
      label: Text(title),
      selected: savedOnly == saved,
      showCheckmark: false,
      selectedColor: const Color(0xFFF5F5F7),
      backgroundColor: const Color(0xFF111113),
      labelStyle: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: savedOnly == saved ? Colors.black : ShadeColors.textSecondary),
      side: BorderSide(
          color: savedOnly == saved
              ? Colors.transparent
              : const Color(0xFF29292D)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      onSelected: (_) => setState(() => savedOnly = saved));
}

// Typing (contract C2) wins over presence; both degrade to the static line.
String _statusLine(AlphaController c, String peer) {
  final typingUntil = c.typing[peer] as num? ?? 0;
  if (typingUntil > DateTime.now().millisecondsSinceEpoch) return 'печатает…';
  if (c.presence[peer] == true) return 'В сети';
  return 'Личная переписка';
}

String _time(Map<String, dynamic> item) {
  final date =
      DateTime.fromMillisecondsSinceEpoch((item['createdAt'] as num).toInt());
  if (DateUtils.isSameDay(date, DateTime.now())) {
    return '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }
  final day = date.day.toString().padLeft(2, '0');
  final month = date.month.toString().padLeft(2, '0');
  return '$day.$month';
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
      backgroundColor: ShadeColors.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
          child: SingleChildScrollView(
              child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.reply_rounded, color: ShadeColors.cyan),
            title: const Text('Ответить',
                style: TextStyle(color: ShadeColors.textPrimary)),
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
            leading: const Icon(Icons.delete_outline_rounded,
                color: ShadeColors.textSecondary),
            title: const Text('Удалить у себя',
                style: TextStyle(color: ShadeColors.textPrimary)),
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
                leading:
                    const Icon(Icons.delete_forever_rounded, color: Color(0xFFEF4444)),
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
            content: Text(
                'Не удалось отозвать. Проверьте сеть и повторите.')));
      }
    }
  }

  Future<void> _deleteMessage(String ref) async {
    try {
      await widget.controller.act('deleteLocal', {'ref': ref});
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('Не удалось удалить. Проверьте сеть и повторите.')));
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
        if (mounted &&
            scroll.hasClients &&
            scroll.position.pixels > 1) {
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
          decoration: const BoxDecoration(
              border: Border(
                  bottom:
                      BorderSide(color: ShadeColors.greyBorder, width: .5))),
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
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700)),
                            const SizedBox(height: 3),
                            Text(_statusLine(c, peer),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 11,
                                    color: (c.typing[peer] as num? ?? 0) >
                                            DateTime.now().millisecondsSinceEpoch
                                        ? ShadeColors.cyan
                                        : ShadeColors.textMuted)),
                          ])),
                    ]))),
            IconButton(
                tooltip: 'Проверить ключ контакта',
                onPressed: () => c.act('verify', {'account': peer}),
                icon: Icon(
                    c.pinned(peer)
                        ? Icons.verified_user_outlined
                        : Icons.shield_outlined,
                    size: 21)),
          ])),
      AnimatedSize(
          duration: ShadeMotion.duration(context),
          child: !c.connected
              ? Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  color: ShadeColors.surfaceCard,
                  child: Text(c.connection,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 12, color: ShadeColors.textSecondary)))
              : const SizedBox(width: double.infinity)),
      Expanded(
          child: CustomPaint(
              painter: const _ConversationPatternPainter(),
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
                          padding: const EdgeInsets.only(top: 8, bottom: 16),
                          itemCount: items.length,
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          itemBuilder: (context, i) {
                            // Reversed index: 0 is the newest message; the
                            // original (chronological) index is the mirror.
                            final m = items[items.length - 1 - i],
                                date = DateTime.fromMillisecondsSinceEpoch(
                                    (m['createdAt'] as num).toInt());
                            final reply = m['reply'] as Map?;
                            final media = m['media'] as Map?;
                            final mediaBytes = media == null
                                ? null
                                : _mediaBytes(m['ref'] as String, media);
                            bool grouped(int originalIndex) =>
                                originalIndex >= 0 &&
                                originalIndex < items.length &&
                                items[originalIndex]['from'] == m['from'] &&
                                ((items[originalIndex]['createdAt'] as num) -
                                            (m['createdAt'] as num))
                                        .abs() <
                                    180000 &&
                                DateUtils.isSameDay(
                                    date,
                                    DateTime.fromMillisecondsSinceEpoch(
                                        (items[originalIndex]['createdAt'] as num)
                                            .toInt()));
                            final showDate = i == items.length - 1 ||
                                !DateUtils.isSameDay(
                                    date,
                                    DateTime.fromMillisecondsSinceEpoch(
                                        (items[items.length - 2 - i]['createdAt'] as num)
                                            .toInt()));
                            return Column(key: ValueKey(m['ref']), children: [
                              if (showDate) ShadeDateSeparator(date: date),
                              ShadeMessageArrival(
                                  animate: added.contains(m['ref']),
                                  child: MessageBubble(
                                      text: media != null ? '' : m['text'] as String,
                                      timestamp: date,
                                      isMine: m['from'] == c.account,
                                      isEncrypted: true,
                                      isImage: media != null,
                                      imageData: mediaBytes,
                                      status: AlphaController.status(m),
                                      deliveryLabel:
                                          AlphaController.delivery(m),
                                      groupedWithPrevious:
                                          grouped(items.length - 2 - i),
                                      groupedWithNext:
                                          grouped(items.length - i),
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
                                              backgroundColor: const Color(
                                                  0xFF29292D),
                                              onPressed: _toLatest,
                                              child: unseen > 0
                                                  ? Text('$unseen',
                                                      style:
                                                          const TextStyle(
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w700))
                                                  : const Icon(Icons
                                                      .arrow_downward_rounded,
                                                      size: 21)))
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
            color: ShadeColors.surfaceElevated,
            child: Row(children: [
              Container(width: 3, height: 40, color: ShadeColors.cyan),
              const SizedBox(width: 12),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(replyTo!['from'] == c.account ? 'Вы' : peer,
                        style: const TextStyle(
                            color: ShadeColors.cyan,
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                    Text(replyTo!['text'] as String,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: ShadeColors.textSecondary, fontSize: 13)),
                  ])),
              IconButton(
                  icon: const Icon(Icons.close_rounded,
                      size: 18, color: ShadeColors.textMuted),
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
                    }))),
      ],
    ]);
  }
}

class _Profile extends StatelessWidget {
  const _Profile({required this.controller, required this.close});
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

  Widget _profileAction(BuildContext context,
      {required IconData icon,
      required String label,
      required VoidCallback onTap,
      bool primary = false}) {
    final ink = primary ? Colors.black : ShadeColors.textPrimary;
    return Material(
        color: primary ? ShadeColors.textPrimary : ShadeColors.surfaceCard,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: BorderSide(
                color: primary ? Colors.transparent : ShadeColors.greyBorder)),
        child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onTap,
            child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(icon, size: 21, color: ink),
                  const SizedBox(height: 9),
                  Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: ink, fontSize: 12, fontWeight: FontWeight.w600)),
                ]))));
  }

  Future<void> _editAvatar(BuildContext context) async {
    final frame = AvatarFrame.values.firstWhere(
        (f) => f.name == controller.profile['frame'],
        orElse: () => AvatarFrame.none);
    final bytes = await controller.avatarImage(
        controller.profile['digest'] as String? ?? '');
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => AlphaAvatarEditor(
            initialImage: bytes,
            initialName:
                displayName.isEmpty ? controller.account : displayName,
            initialFrame: frame,
            save: ({required frame, required replaceImage, image}) =>
                controller.act('profile.save', {
                  'frame': frame.name,
                  if (replaceImage)
                    'avatar': image == null ? null : base64Encode(image),
                }))));
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
                    hintText: 'Как вас видят собеседники')),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialog),
                  child: const Text('Отмена')),
              TextButton(
                  onPressed: () => Navigator.pop(dialog, field.text),
                  child: const Text('Сохранить')),
            ]));
    if (updated == null || !context.mounted) return;
    if (updated.trim() == displayName) return;
    try {
      await controller.act('profile.save', {'displayName': updated});
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('Не удалось сохранить имя. Проверьте сеть и повторите.')));
      }
    }
  }

  Future<void> _confirmLogout(
      BuildContext context, AlphaController controller) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
            title: const Text('Выйти из аккаунта?'),
            content: const Text(
                'Сессия Google завершится. Ключи и история останутся в этом '
                'браузере; для входа понадобится фраза устройства.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialog, false),
                  child: const Text('Отмена')),
              TextButton(
                  onPressed: () => Navigator.pop(dialog, true),
                  child: const Text('Выйти')),
            ]));
    if (confirmed == true) await controller.act('logout');
  }

  Future<void> _confirmRevoke(
      BuildContext context, AlphaController controller, String id) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
            title: const Text('Отозвать устройство?'),
            content: const Text(
                'Очередь и push-подписка устройства будут удалены. '
                'Действие необратимо: ключи отозванного устройства больше '
                'не смогут получать сообщения.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialog, false),
                  child: const Text('Отмена')),
              TextButton(
                  onPressed: () => Navigator.pop(dialog, true),
                  child: const Text('Отозвать')),
            ]));
    if (confirmed != true || !context.mounted) return;
    try {
      await controller.act('devices.revoke', {'id': id});
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Не удалось отозвать устройство. Проверьте сеть и повторите.')));
      }
    }
  }
  @override
  Widget build(BuildContext context) => Column(children: [
        Row(children: [
          IconButton(
              tooltip: 'Назад',
              onPressed: close,
              icon: const Icon(Icons.chevron_left_rounded)),
          const Text('Профиль',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))
        ]),
        Expanded(
            child: Center(
                child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child:
                        ListView(padding: const EdgeInsets.all(24), children: [
                      Center(
                          child: GestureDetector(
                              onTap: () => _editAvatar(context),
                              child: Stack(children: [
                                AccountAvatar(
                                    controller: controller,
                                    account: controller.account,
                                    size: 100),
                                Positioned(
                                    right: 0,
                                    bottom: 0,
                                    child: Container(
                                        padding: const EdgeInsets.all(6),
                                        decoration: BoxDecoration(
                                            color: ShadeColors.surfaceCard,
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                                color:
                                                    ShadeColors.greyBorder)),
                                        child: const Icon(Icons.edit_rounded,
                                            size: 14,
                                            color: ShadeColors.textMuted))),
                                const Positioned.fill(
                                    child: Material(
                                        type: MaterialType.transparency)),
                              ]))),
                      const SizedBox(height: 8),
                      Semantics(
                          button: true,
                          child: TextButton(
                              onPressed: () => _editAvatar(context),
                              child: const Text('Изменить аватар',
                                  style: TextStyle(fontSize: 13)))),
                      const SizedBox(height: 12),
                      Text(
                          displayName.isEmpty
                              ? controller.account
                              : displayName,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              fontSize: 28, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      Text('@${controller.account}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: ShadeColors.textMuted)),
                      const SizedBox(height: 8),
                      const SizedBox(height: 16),
                      Row(children: [
                        Expanded(
                            child: _profileAction(context,
                                icon: Icons.edit_outlined,
                                label: 'Имя',
                                primary: true,
                                onTap: () => _editName(context))),
                        const SizedBox(width: 10),
                        Expanded(
                            child: _profileAction(context,
                                icon: Icons.copy_outlined,
                                label: 'Копировать',
                                onTap: () async {
                                  await Clipboard.setData(ClipboardData(
                                      text: '@${controller.account}'));
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                            content: Text(
                                                'Имя пользователя скопировано')));
                                  }
                                })),
                        const SizedBox(width: 10),
                        Expanded(
                            child: _profileAction(context,
                                icon: Icons.qr_code_2_rounded,
                                label: 'Мой ключ',
                                onTap: () => controller.act('identity'))),
                      ]),
                      const SizedBox(height: 24),
                      const Text('ИНФОРМАЦИЯ',
                          style: TextStyle(
                              fontSize: 11,
                              letterSpacing: 1.5,
                              color: ShadeColors.textMuted)),
                      const SizedBox(height: 12),
                      Card(
                          child: Column(children: [
                        ListTile(
                            leading: const Icon(Icons.alternate_email_rounded),
                            title: Text('@${controller.account}'),
                            subtitle: const Text('Имя пользователя')),
                        if (controller.email != null) ...[
                          const Divider(height: 1, indent: 56),
                          ListTile(
                              leading: const Icon(Icons.mail_outline_rounded),
                              title: Text(controller.email!,
                                  style: const TextStyle(fontSize: 15)),
                              subtitle: const Text('Google-аккаунт')),
                        ],
                        const Divider(height: 1, indent: 56),
                        const ListTile(
                            leading: Icon(Icons.phone_iphone_rounded),
                            title: Text('Это устройство'),
                            subtitle: Text(
                                'Приватный ключ не покидает браузер')),
                      ])),
                      const SizedBox(height: 24),
                      const Text('ШИФРОВАНИЕ',
                          style: TextStyle(
                              fontSize: 11,
                              letterSpacing: 1.5,
                              color: ShadeColors.textMuted)),
                      const SizedBox(height: 12),
                      Card(
                          clipBehavior: Clip.antiAlias,
                          child: Semantics(
                              button: true,
                              child: InkWell(
                                  onTap: () => controller.act('identity'),
                                  child: Padding(
                                      padding: const EdgeInsets.all(16),
                                      child: Row(children: [
                                        _KeyIdenticon(
                                            bytes: _identiconBytes, size: 52),
                                        const SizedBox(width: 12),
                                        Expanded(
                                            child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Row(children: [
                                                    const Expanded(
                                                        child: Text(
                                                            'Ключ шифрования',
                                                            style: TextStyle(
                                                                fontSize: 14,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w600))),
                                                    Container(
                                                        padding: const EdgeInsets
                                                            .symmetric(
                                                            horizontal: 8,
                                                            vertical: 4),
                                                        decoration: BoxDecoration(
                                                            color: ShadeColors
                                                                .surfaceElevated,
                                                            borderRadius:
                                                                BorderRadius
                                                                    .circular(
                                                                        20)),
                                                        child: const Text('Ваш',
                                                            style: TextStyle(
                                                                fontSize: 11,
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w600,
                                                                color: ShadeColors
                                                                    .textPrimary))),
                                                  ]),
                                                  const SizedBox(height: 6),
                                                  Text(_fingerprintPreview,
                                                      style: const TextStyle(
                                                          fontFamily:
                                                              'monospace',
                                                          fontSize: 12,
                                                          letterSpacing: 1.2,
                                                          color: ShadeColors
                                                              .textSecondary)),
                                                  const SizedBox(height: 4),
                                                  const Text(
                                                      'Нажмите, чтобы показать код',
                                                      style: TextStyle(
                                                          fontSize: 12,
                                                          color: ShadeColors
                                                              .textMuted)),
                                                ])),
                                        const Icon(
                                            Icons.chevron_right_rounded,
                                            color: ShadeColors.textMuted),
                                      ]))))),
                      const SizedBox(height: 12),
                      Card(
                          child: ListTile(
                            leading: const Icon(Icons.file_download_outlined),
                            title: const Text('Recovery-пакет'),
                            subtitle:
                                const Text('Сохранить зашифрованную копию'),
                            onTap: () => controller.act('backup'),
                          )),
                      const SizedBox(height: 24),
                      const Text('ПОДАРКИ · ВИНИЛОВАЯ СТЕНА',
                          style: TextStyle(
                              fontSize: 11,
                              letterSpacing: 1.5,
                              color: ShadeColors.textMuted)),
                      const SizedBox(height: 4),
                      StickerCollection(
                          username: controller.account,
                          owner: true,
                          backend: AlphaStickerBackend(controller)),
                      const SizedBox(height: 24),
                      const Text('ПОДКЛЮЧЁННЫЕ УСТРОЙСТВА',
                          style: TextStyle(
                              fontSize: 11,
                              letterSpacing: 1.5,
                              color: ShadeColors.textMuted)),
                      const SizedBox(height: 12),
                      Card(
                          child: Column(
                              children: controller.devices
                                  .map((d) => ListTile(
                                      leading: Icon(d['current'] == true
                                          ? Icons.devices_rounded
                                          : Icons.phonelink_rounded),
                                      title: Text(d['name'] as String? ??
                                          (d['current'] == true
                                              ? 'Этот браузер'
                                              : 'Устройство'),
                                          style: const TextStyle(fontSize: 15)),
                                      subtitle: Text(d['id'] as String,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              fontSize: 11,
                                              color: ShadeColors.textMuted)),
                                      trailing: d['current'] == true
                                          ? null
                                          : IconButton(
                                              tooltip: 'Отозвать устройство',
                                              icon: const Icon(
                                                  Icons.delete_outline_rounded,
                                                  size: 18,
                                                  color: ShadeColors
                                                      .textSecondary),
                                              onPressed: () =>
                                                  _confirmRevoke(context,
                                                      controller,
                                                      d['id'] as String))))
                                  .toList())),
                      const SizedBox(height: 12),
                      Card(
                          child: ListTile(
                              leading: const Icon(Icons.add_link_rounded),
                              title: const Text('Добавить устройство',
                                  style: TextStyle(fontSize: 15)),
                              subtitle: const Text(
                                  'Код подключения → подтверждение запроса',
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: ShadeColors.textMuted)),
                              trailing:
                                  const Icon(Icons.chevron_right_rounded),
                              onTap: () => controller.act('devices.pair'))),
                      const SizedBox(height: 20),
                      Card(
                          child: ListTile(
                              leading:
                                  const Icon(Icons.notifications_outlined),
                              title: const Text('Уведомления'),
                              subtitle: Text(switch (controller.platform) {
                                'ios' =>
                                  'Push-сигнал без текста · iOS: установленное приложение',
                                'android' =>
                                  'Push-сигнал без текста · Android: разрешение уведомлений',
                                _ =>
                                  'Push-сигнал без текста · разрешите уведомления в браузере',
                              }),
                              onTap: () => controller.act('push.toggle'))),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                          onPressed: () => controller.act('install'),
                          icon: const Icon(Icons.ios_share_rounded),
                          label: const Text('Установить Shade')),
                      const SizedBox(height: 12),
                      TextButton(
                          onPressed: () => _confirmLogout(context, controller),
                          child: const Text('Выйти из аккаунта')),
                      const SizedBox(height: 20),
                      const Text(
                          'Ключи и история остаются в этом браузере.\nНе очищайте данные сайта без recovery-пакета.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 12,
                              height: 1.6,
                              color: ShadeColors.textMuted)),
                    ])))),
      ]);
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
                style: const TextStyle(
                    fontSize: 15, height: 1.5),
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
            content:
                Text('Не удалось сохранить заметку. Проверьте сеть и повторите.')));
      }
    }
  }
  @override
  Widget build(BuildContext context) {
    final c = controller;
    final pinned = c.pinned(peer);
    final messages = c.conversation(peer).length;
    final note = c.notes[peer] as String? ?? '';
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
                        style: const TextStyle(color: ShadeColors.textMuted)),
                    const SizedBox(height: 32),
                    const Text('ПЕРЕПИСКА И БЕЗОПАСНОСТЬ',
                        style: TextStyle(
                            fontSize: 11,
                            letterSpacing: 1.5,
                            color: ShadeColors.textMuted)),
                    const SizedBox(height: 12),
                      Card(
                        child: Column(children: [
                      ListTile(
                          leading: Icon(
                              pinned
                                  ? Icons.verified_user_outlined
                                  : Icons.shield_outlined,
                              color: pinned
                                  ? ShadeColors.cyan
                                  : ShadeColors.textSecondary),
                          title: Text(pinned
                              ? 'Ключ собеседника проверен'
                              : 'Ключ ещё не проверен'),
                          subtitle: Text(pinned
                              ? 'Отпечаток закреплён за этим аккаунтом'
                              : 'Сверьте отпечатки через независимый доверенный канал'),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => c.act('verify', {'account': peer})),
                      const Divider(height: 1, indent: 56),
                      ListTile(
                          leading:
                              const Icon(Icons.forum_outlined),
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
                                      content:
                                          Text('Никнейм скопирован')));
                            }
                          }),
                    ])),
                    const SizedBox(height: 24),
                    const Text('ПОДАРКИ · ВИНИЛОВАЯ СТЕНА',
                        style: TextStyle(
                            fontSize: 11,
                            letterSpacing: 1.5,
                            color: ShadeColors.textMuted)),
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
                    const Text(
                        'Shade подтверждает ключи только вашей личной сверкой.\nGoogle и сервер не гарантируют личность собеседника.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12,
                            height: 1.6,
                            color: ShadeColors.textMuted)),
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
  const _ConversationPatternPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()
      ..shader = ui.Gradient.linear(
          Offset.zero, Offset(size.width, size.height), const [
        Color(0xFF0C0C0C),
        Color(0xFF101010),
      ]);
    canvas.drawRect(Offset.zero & size, bg);
    final mark = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = const Color(0xFF232326);
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
      false;
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

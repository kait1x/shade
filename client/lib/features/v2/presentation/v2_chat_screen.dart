/// Диалог native v2: история E2EE, отправка текста с долговечной очередью,
/// reply, статусы queued/blocked/sent/delivered/read по подписанной
/// ack/status-проекции, typing/presence (транспорт поддерживает контракт C2).
///
/// Клавиатура/viewport как в v1 chat_screen: resizeToAvoidBottomInset,
/// reverse ListView с onDrag-dismiss, SafeArea у ввода, масштабирование
/// тулбара под системный шрифт. MessageBubble/MessageInput/AvatarView/тема/
/// empty-states переиспользуются импортом.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:shade/core/theme/shade_theme.dart';
import 'package:shade/core/widgets/avatar_view.dart';
import 'package:shade/core/widgets/shade_motion.dart';
import 'package:shade/core/widgets/shade_ui.dart';
import 'package:shade/features/chats/presentation/widgets/message_bubble.dart';
import 'package:shade/features/chats/presentation/widgets/message_input.dart';

import 'v2_social.dart';
import 'v2_providers.dart';

class V2ChatScreen extends ConsumerStatefulWidget {
  final String peer;
  const V2ChatScreen({super.key, required this.peer});

  @override
  ConsumerState<V2ChatScreen> createState() => _V2ChatScreenState();
}

class _V2ChatScreenState extends ConsumerState<V2ChatScreen> {
  final _scroll = ScrollController();
  final _arrivals = <String>{};
  bool _away = false;
  int _unseen = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  void _onScroll() {
    final away = _scroll.offset > 180;
    if (away != _away || (!away && _unseen != 0)) {
      setState(() {
        _away = away;
        if (!away) _unseen = 0;
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _toLatest() {
    if (!_scroll.hasClients) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _scroll.jumpTo(0);
    } else {
      _scroll.animateTo(0,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic);
    }
  }

  /// Новые сообщения: анимация появления внизу, автоскролл к своим при
  /// чтении истории, счётчик непрочитанных при возврате к последним.
  void _trackArrivals(V2ConversationState? previous, V2ConversationState next) {
    final before = previous?.messages ?? const <V2MessageView>[];
    final after = next.messages;
    if (before.isEmpty || after.isEmpty) return;
    final known = before.map((m) => m.ref).toSet();
    final added = after.where((m) => !known.contains(m.ref)).toList();
    if (added.isEmpty) return;
    if (!_away) {
      _arrivals.addAll(added.map((m) => m.ref));
    } else if (added.any((m) => m.mine)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _toLatest();
      });
    } else {
      _unseen += added.length;
    }
    final active = after.map((m) => m.ref).toSet();
    _arrivals.removeWhere((ref) => !active.contains(ref));
  }

  @override
  Widget build(BuildContext context) {
    final peer = widget.peer;
    final state = ref.watch(v2ConversationProvider(peer));
    final notifier = ref.read(v2ConversationProvider(peer).notifier);
    final account = ref.watch(v2SyncProvider)?.account ?? '';
    final isSelf = peer == account;
    final profile = ref.watch(publicProfileProvider(peer)).asData?.value;
    ref.listen(v2ConversationProvider(peer), _trackArrivals);

    final subtitle = state.peerTyping
        ? 'печатает…'
        : isSelf
            ? 'Ваши личные заметки'
            : state.peerOnline == true
                ? 'в сети'
                : 'Личная переписка';

    return Scaffold(
      backgroundColor: context.shadeColor(ShadeColors.black),
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        toolbarHeight:
            68 + max(0, MediaQuery.textScalerOf(context).scale(16) - 16) * 2,
        shape: const Border(bottom: BorderSide(color: Color(0xFF1C1C1F))),
        leading: const BackButton(),
        leadingWidth: 48,
        titleSpacing: 0,
        title: Row(children: [
          AvatarView(
              image: profile?.image,
              frame: profile?.frame ?? AvatarFrame.none,
              name: peer,
              size: 40,
              saved: isSelf,
              online: !isSelf && state.peerOnline == true),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(
                    isSelf
                        ? 'Избранное'
                        : (profile?.name.isNotEmpty == true
                            ? profile!.name
                            : '@$peer'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                AnimatedSwitcher(
                    duration: ShadeMotion.duration(context, 160),
                    child: Text(subtitle,
                        key: ValueKey(subtitle),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12,
                            color: state.peerTyping ||
                                    (!isSelf && state.peerOnline == true)
                                ? context.shadeColor(ShadeColors.greenAccent)
                                : context
                                    .shadeColor(ShadeColors.textSecondary)))),
              ])),
        ]),
        actions: [
          if (!isSelf && ref.watch(v2SocialProvider) != null)
            IconButton(
                tooltip: 'Профиль собеседника',
                icon: const Icon(Icons.person_outline),
                onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                        builder: (_) => PeerProfile(peer)))),
          IconButton(
              tooltip: 'Обновить переписку',
              icon: const Icon(Icons.refresh_rounded, size: 22),
              onPressed: notifier.refresh),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(children: [
        Expanded(
            child: ShadeConversationBackground(
                child: _messagesArea(context, state, notifier, account))),
        if (state.blocked)
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              child: Text(
                  'Собеседник ещё не перешёл на v2. Сообщения остаются в подписанной очереди и будут доставлены после перехода.',
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12))),
        if (state.error != null && state.messages.isNotEmpty)
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              child: Text(
                  'Не удалось выполнить действие. Проверьте подключение и повторите.',
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12))),
        if (state.replyTo != null)
          _replyPreview(context, state, notifier, peer, account),
        MessageInput(
            onSend: notifier.send,
            onImageSelected: notifier.sendImage,
            onTyping: notifier.notifyTyping),
      ]),
    );
  }

  Widget _replyPreview(BuildContext context, V2ConversationState state,
      V2ConversationNotifier notifier, String peer, String account) {
    final reply = state.replyTo!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: context.shadeColor(ShadeColors.surfaceElevated),
      child: Row(children: [
        Container(
            width: 3, height: 40, color: context.shadeColor(ShadeColors.cyan)),
        const SizedBox(width: 12),
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(reply.mine ? 'Вы' : '@$peer',
              style: TextStyle(
                  color: context.shadeColor(ShadeColors.cyan),
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          Text(reply.isImage ? 'Фото' : reply.text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: context.shadeColor(ShadeColors.textSecondary),
                  fontSize: 13)),
        ])),
        IconButton(
            tooltip: 'Отменить ответ',
            icon: Icon(Icons.close_rounded,
                size: 18, color: context.shadeColor(ShadeColors.textMuted)),
            onPressed: notifier.clearReply),
      ]),
    );
  }

  Widget _messagesArea(BuildContext context, V2ConversationState state,
      V2ConversationNotifier notifier, String account) {
    final msgs = state.messages;
    if (state.loading && msgs.isEmpty) {
      return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox.square(
            dimension: 24, child: ShadeLoadingIndicator(strokeWidth: 2)),
        SizedBox(height: 16),
        Text('Открываем переписку',
            style: TextStyle(
                color: context.shadeColor(ShadeColors.textSecondary))),
      ]));
    }
    if (state.error != null && msgs.isEmpty) {
      return SingleChildScrollView(
          child: ShadeEmptyState(
              icon: Icons.cloud_off_rounded,
              title: 'Не удалось открыть переписку',
              description:
                  'История остаётся на устройстве. Попробуйте ещё раз.',
              action: OutlinedButton.icon(
                  onPressed: notifier.refresh,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Повторить'))));
    }
    if (msgs.isEmpty) {
      return const Center(
          child: SingleChildScrollView(
              child: ShadeEmptyState(
                  icon: Icons.chat_bubble_outline_rounded,
                  title: 'Начните разговор',
                  description:
                      'Слова, фотографии, важные моменты.\nВсё начинается с одного сообщения.')));
    }

    final hasTyping = state.peerTyping;
    final offset = hasTyping ? 1 : 0;
    bool grouped(V2MessageView a, V2MessageView b) {
      final at = DateTime.fromMillisecondsSinceEpoch(a.createdAt);
      final bt = DateTime.fromMillisecondsSinceEpoch(b.createdAt);
      return a.mine == b.mine &&
          at.year == bt.year &&
          at.month == bt.month &&
          at.day == bt.day &&
          bt.difference(at).inMinutes.abs() < 5;
    }

    return Stack(children: [
      ListView.builder(
          key: PageStorageKey('v2-messages-${widget.peer}'),
          controller: _scroll,
          reverse: true,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.only(top: 8, bottom: 12),
          itemCount: msgs.length + offset + 1,
          itemBuilder: (context, index) {
            if (hasTyping && index == 0) return const _TypingBubble();
            final reversed = msgs.length - 1 - (index - offset);
            if (reversed < 0) {
              return Padding(
                  padding: EdgeInsets.symmetric(vertical: 20, horizontal: 32),
                  child: Text('Начало переписки',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 11,
                          color: context.shadeColor(ShadeColors.textMuted))));
            }
            final msg = msgs[reversed];
            final previous = reversed > 0 ? msgs[reversed - 1] : null;
            final next = reversed + 1 < msgs.length ? msgs[reversed + 1] : null;
            final time = DateTime.fromMillisecondsSinceEpoch(msg.createdAt);
            final startsDay = previous == null ||
                DateTime.fromMillisecondsSinceEpoch(previous.createdAt).day !=
                    time.day ||
                DateTime.fromMillisecondsSinceEpoch(previous.createdAt).month !=
                    time.month ||
                DateTime.fromMillisecondsSinceEpoch(previous.createdAt).year !=
                    time.year;
            final retracted = msg.status == 'retracted';
            final reply = msg.reply;
            return Column(
                key: ValueKey(msg.ref),
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (startsDay) ShadeDateSeparator(date: time),
                  ShadeMessageArrival(
                      animate: _arrivals.remove(msg.ref),
                      child: MessageBubble(
                          text: retracted
                              ? (msg.mine
                                  ? 'Сообщение отозвано'
                                  : 'Сообщение отозвано отправителем')
                              : msg.mediaPending
                                  ? 'Фото загружается…'
                                  : msg.text,
                          timestamp: time,
                          isMine: msg.mine,
                          isEncrypted: true,
                          isImage: msg.isImage,
                          imageData: msg.imageData,
                          status: retracted ? 'sent' : msg.status,
                          deliveryLabel: msg.statusLabel,
                          groupedWithPrevious:
                              previous != null && grouped(previous, msg),
                          groupedWithNext: next != null && grouped(msg, next),
                          onLongPress: () =>
                              _messageMenu(context, msg, notifier, retracted),
                          replyText:
                              reply == null ? null : reply['text'] as String?,
                          replySender: reply == null
                              ? null
                              : reply['from'] == account
                                  ? 'Вы'
                                  : '@${reply['from']}')),
                ]);
          }),
      if (_away)
        Positioned(
            right: 16,
            bottom: 12,
            child: FloatingActionButton.small(
                key: const Key('jump-to-latest'),
                heroTag: 'v2-latest-${widget.peer}',
                tooltip: _unseen > 0
                    ? 'Новых сообщений: $_unseen. К последним'
                    : 'К последним сообщениям',
                backgroundColor: context.shadeColor(ShadeColors.greyBorder),
                onPressed: _toLatest,
                child: _unseen > 0
                    ? Text('$_unseen',
                        style: const TextStyle(fontWeight: FontWeight.w700))
                    : const Icon(Icons.arrow_downward_rounded, size: 21))),
    ]);
  }

  void _messageMenu(BuildContext context, V2MessageView msg,
      V2ConversationNotifier notifier, bool retracted) {
    ShadeMotion.selection(context);
    final canRetract = msg.mine &&
        !retracted &&
        msg.status != 'queued' &&
        msg.status != 'blocked';
    showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: ShadeMotion.sheet(context),
      showDragHandle: true,
      builder: (ctx) => SafeArea(
          child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (!retracted)
          ListTile(
              leading: Icon(Icons.reply_rounded,
                  color: context.shadeColor(ShadeColors.cyan)),
              title: const Text('Ответить'),
              onTap: () {
                Navigator.pop(ctx);
                notifier.setReply(msg);
              }),
        ListTile(
            leading: Icon(Icons.delete_outline_rounded,
                color: context.shadeColor(ShadeColors.textSecondary)),
            title: const Text('Удалить у себя'),
            onTap: () async {
              Navigator.pop(ctx);
              try {
                await notifier.deleteLocal(msg.ref);
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Не удалось удалить: $e')));
                }
              }
            }),
        if (canRetract)
          ListTile(
              leading: const Icon(Icons.delete_forever_rounded,
                  color: Color(0xFFEF4444)),
              title: const Text('Отозвать у всех',
                  style: TextStyle(color: Color(0xFFEF4444))),
              onTap: () async {
                Navigator.pop(ctx);
                try {
                  await notifier.retract(msg.ref);
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Не удалось отозвать: $e')));
                  }
                }
              }),
      ]))),
    );
  }
}

/// Индикатор набора текста: спокойные статичные точки (reduced-motion по
/// умолчанию), semantics для скринридеров.
class _TypingBubble extends StatelessWidget {
  const _TypingBubble();

  @override
  Widget build(BuildContext context) {
    return Semantics(
        label: 'Собеседник печатает',
        child: Align(
            alignment: Alignment.centerLeft,
            child: Container(
                margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                decoration: BoxDecoration(
                    color: context.shadeColor(ShadeColors.surfaceElevated),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: context.shadeColor(ShadeColors.greyBorder))),
                child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(
                        3,
                        (i) => Container(
                            width: 7,
                            height: 7,
                            margin: const EdgeInsets.symmetric(horizontal: 2.5),
                            decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: context
                                    .shadeColor(ShadeColors.textSecondary)
                                    .withValues(alpha: 0.4 + i * 0.2))))))));
  }
}

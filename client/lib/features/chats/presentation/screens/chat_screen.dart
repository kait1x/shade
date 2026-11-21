import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:math';
import 'package:shade/core/widgets/shade_motion.dart';
import 'package:shade/features/home/presentation/widgets/chat_list_view.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shade/core/services/connection_service.dart';
import 'package:shade/core/services/crypto_service.dart';
import 'package:shade/core/services/notification_service.dart';
import 'package:shade/features/auth/data/repositories/auth_notifier.dart';
import 'package:shade/features/chats/data/repositories/chat_repository.dart';
import 'package:shade/features/chats/presentation/widgets/message_bubble.dart';
import 'package:shade/features/chats/presentation/widgets/message_input.dart';
import 'package:shade/main.dart';
import 'package:shade/core/widgets/shade_ui.dart';
import 'package:go_router/go_router.dart';

/// Arguments passed to [ChatScreen] via GoRouter `extra`.
class ChatScreenArgs {
  final String conversationName;
  final String recipientPublicKey;
  final String recipientUsername;

  const ChatScreenArgs({
    required this.conversationName,
    required this.recipientPublicKey,
    required this.recipientUsername,
  });
}

/// A single decrypted message ready for display.
class DisplayMessage {
  final String? networkId;
  final int id;
  final String text;
  final DateTime timestamp;
  final bool isMine;
  final bool decryptSuccess;
  final bool isImage;
  final Uint8List? imageData;
  final String status; // 'sent', 'delivered', 'read'
  final String? replyText;
  final String? replySender;

  const DisplayMessage({
    this.networkId,
    required this.id,
    required this.text,
    required this.timestamp,
    required this.isMine,
    this.decryptSuccess = true,
    this.isImage = false,
    this.imageData,
    this.status = 'sent',
    this.replyText,
    this.replySender,
  });
}

/// State for the chat screen messages.
class ChatMessagesState {
  final List<DisplayMessage> messages;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasMore;
  final String? paginationError;
  final String? error;
  final bool isRecipientTyping;
  final UserStatus? userStatus;
  final DisplayMessage? replyTo;

  const ChatMessagesState({
    this.messages = const [],
    this.isLoading = true,
    this.isLoadingMore = false,
    this.hasMore = true,
    this.paginationError,
    this.error,
    this.isRecipientTyping = false,
    this.userStatus,
    this.replyTo,
  });

  ChatMessagesState copyWith({
    List<DisplayMessage>? messages,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasMore,
    String? paginationError,
    bool clearPaginationError = false,
    bool clearError = false,
    String? error,
    bool? isRecipientTyping,
    UserStatus? userStatus,
    DisplayMessage? replyTo,
    bool clearReply = false,
  }) {
    return ChatMessagesState(
      messages: messages ?? this.messages,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
      paginationError: clearPaginationError
          ? null
          : (paginationError ?? this.paginationError),
      error: clearError ? null : (error ?? this.error),
      isRecipientTyping: isRecipientTyping ?? this.isRecipientTyping,
      userStatus: userStatus ?? this.userStatus,
      replyTo: clearReply ? null : (replyTo ?? this.replyTo),
    );
  }
}

/// Notifier that loads, decrypts, and manages chat messages with pagination.
class ChatMessagesNotifier extends StateNotifier<ChatMessagesState> {
  final int conversationId;
  final int currentSenderId;
  final String recipientPublicKey;
  final String recipientUsername;
  final String currentUsername;
  final ChatRepository _chatRepository;
  final CryptoService _cryptoService;
  final ConnectionService _connectionService;
  StreamSubscription<IncomingMessage>? _wsSub;
  StreamSubscription<String>? _typingSub;
  StreamSubscription<MessageDeletedEvent>? _deleteSub;
  StreamSubscription<Map<String, dynamic>>? _messageStatusSub;
  Timer? _typingTimeout;

  // Pagination state
  static const int _pageSize = 20;
  int _loadedCount = 0;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  Future<void> _operations = Future.value();

  // Serialize refreshes and pagination so offsets and decrypted pages agree.
  Future<void> _enqueue(Future<void> Function() operation) {
    final next = _operations.then((_) async {
      if (!_isDisposed) await operation();
    });
    _operations = next.catchError((Object _) {});
    return next;
  }

  ChatMessagesNotifier({
    required this.conversationId,
    required this.currentSenderId,
    required this.recipientPublicKey,
    required this.recipientUsername,
    required this.currentUsername,
    required ChatRepository chatRepository,
    required CryptoService cryptoService,
    required ConnectionService connectionService,
  })  : _chatRepository = chatRepository,
        _cryptoService = cryptoService,
        _connectionService = connectionService,
        super(const ChatMessagesState()) {
    _loadMessages();
    _listenForIncoming();
    _watchUserStatus();
    _listenForMessageStatus();
  }

  void _listenForMessageStatus() {
    _messageStatusSub = _connectionService.messageStatusUpdates.listen((data) {
      if (data['from'] != recipientUsername) return;
      unawaited(_loadMessages());
    });
  }

  StreamSubscription? _connectionSub;
  StreamSubscription? _statusSub;

  void _watchUserStatus() {
    _connectionSub = _connectionService.connectionChanges.listen((online) {
      if (online) unawaited(_loadMessages());
    });
    if (recipientUsername == currentUsername) return;

    // Tell server we're watching this user
    _connectionService.watchUser(recipientUsername);

    // Listen for real-time status updates
    _statusSub = _connectionService.statusUpdates.listen((update) {
      if (update.username == recipientUsername) {
        state = state.copyWith(userStatus: update.toUserStatus());
      }
    });

    // Also fetch initial status via HTTP
    _connectionService.getUserStatus(recipientUsername).then((status) {
      if (status != null && !_isDisposed) {
        state = state.copyWith(userStatus: status);
      }
    });
  }

  bool _isDisposed = false;

  void _listenForIncoming() {
    _wsSub = _connectionService.messages.listen((incoming) async {
      // Only handle messages from our conversation partner
      if (incoming.from != recipientUsername) return;

      // Message already saved to DB by ConnectionService._handleIncomingMessage
      // Just reload and decrypt
      await _loadMessages();
    });

    // Listen for typing indicators
    _typingSub = _connectionService.typing.listen((from) {
      if (from == recipientUsername) {
        state = state.copyWith(isRecipientTyping: true);
        // Auto-hide after 3 seconds
        _typingTimeout?.cancel();
        _typingTimeout = Timer(const Duration(seconds: 3), () {
          state = state.copyWith(isRecipientTyping: false);
        });
      }
    });

    // Listen for message deletions from other user
    _deleteSub = _connectionService.messageDeleted.listen((event) async {
      if (event.from == recipientUsername) {
        final matching = state.messages
            .where((m) => m.networkId == event.msgId && !m.isMine)
            .toList();
        for (final msg in matching) {
          await _chatRepository.deleteMessage(msg.id);
        }
        await _loadMessages();
      }
    });
  }

  /// Call when user starts typing
  void notifyTyping() {
    _connectionService.sendTyping(recipientUsername);
  }

  /// Call when user stops typing
  void notifyStopTyping() {
    _connectionService.sendStopTyping(recipientUsername);
  }

  /// Load initial messages (latest page)
  Future<void> _loadMessages() => _enqueue(_reloadMessages);

  Future<void> _reloadMessages() async {
    try {
      state =
          state.copyWith(isLoading: state.messages.isEmpty, clearError: true);

      final requested = max(_pageSize, _loadedCount);
      final rawMessages = await _chatRepository.getMessages(
        conversationId,
        limit: requested,
        offset: 0,
      );
      // A new message shifts OFFSET pagination. Extend the fetched window until
      // the oldest visible history is included, preserving the entire loaded range.
      final oldest =
          state.messages.length > _pageSize ? state.messages.first : null;
      var more = rawMessages.length >= requested;
      while (oldest != null &&
          more &&
          rawMessages.isNotEmpty &&
          !rawMessages.any((m) => m.id == oldest.id) &&
          !rawMessages.last.timestamp.isBefore(oldest.timestamp)) {
        final page = await _chatRepository.getMessages(conversationId,
            limit: _pageSize, offset: rawMessages.length);
        if (_isDisposed) return;
        rawMessages.addAll(page);
        more = page.length >= _pageSize;
      }

      final decrypted = await _chatRepository.decryptMessages(
        rawMessages,
        mySenderId: currentSenderId,
      );

      if (_isDisposed) return;
      _loadedCount = rawMessages.length;
      _hasMore = more;
      unawaited(_markDisplayedRead(rawMessages));
      if (_isDisposed) return;
      state = state.copyWith(
        messages: decrypted
            .map((d) => DisplayMessage(
                  id: d.id,
                  networkId: d.networkId,
                  status: d.status,
                  text: d.text,
                  timestamp: d.timestamp,
                  isMine: d.isMine,
                  decryptSuccess: d.decryptSuccess,
                  isImage: d.isImage,
                  imageData: d.imageData,
                  replyText: d.replyText,
                  replySender: d.replySender,
                ))
            .toList(),
        isLoading: false,
        hasMore: _hasMore,
      );
    } catch (e) {
      if (_isDisposed) return;
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
    }
  }

  Future<void> _markDisplayedRead(List<Message> messages) async {
    if (_isDisposed || !_connectionService.isConnected) return;
    final unread = messages
        .where((m) =>
            !(m.isOutgoing ?? (m.senderId == currentSenderId)) &&
            m.networkId != null &&
            !m.isRead)
        .toList();
    if (unread.isEmpty) return;
    final confirmed = await _connectionService.sendMessageStatus(
        'read', recipientUsername,
        msgIds: unread.map((m) => m.networkId!).toList());
    if (confirmed) {
      await _chatRepository.markRead(
          conversationId, unread.map((m) => m.id).toList());
    }
  }

  /// Load more messages (older) for pagination
  Future<void> loadMoreMessages() async {
    if (_isLoadingMore || !_hasMore || _isDisposed) return;
    _isLoadingMore = true;
    return _enqueue(_loadOlderMessages);
  }

  Future<void> _loadOlderMessages() async {
    try {
      state = state.copyWith(isLoadingMore: true, clearPaginationError: true);

      final rawMessages = await _chatRepository.getMessages(
        conversationId,
        limit: _pageSize,
        offset: _loadedCount,
      );

      if (rawMessages.isEmpty) {
        _hasMore = false;
        return;
      }

      final hasMore = rawMessages.length >= _pageSize;

      final decrypted = await _chatRepository.decryptMessages(
        rawMessages,
        mySenderId: currentSenderId,
      );

      if (_isDisposed) return;
      unawaited(_markDisplayedRead(rawMessages));
      final newMessages = decrypted
          .map((d) => DisplayMessage(
                id: d.id,
                networkId: d.networkId,
                status: d.status,
                text: d.text,
                timestamp: d.timestamp,
                isMine: d.isMine,
                decryptSuccess: d.decryptSuccess,
                isImage: d.isImage,
                imageData: d.imageData,
                replyText: d.replyText,
                replySender: d.replySender,
              ))
          .toList();

      _loadedCount += rawMessages.length;
      _hasMore = hasMore;
      final existing = state.messages.map((m) => m.id).toSet();
      // Prepend older messages to the beginning
      state = state.copyWith(
        messages: [
          ...newMessages.where((m) => !existing.contains(m.id)),
          ...state.messages
        ],
      );
    } catch (e) {
      if (!_isDisposed) {
        state = state.copyWith(paginationError: 'Не удалось загрузить историю');
      }
    } finally {
      _isLoadingMore = false;
      if (!_isDisposed) {
        state = state.copyWith(
            isLoadingMore: false,
            hasMore: _hasMore,
            paginationError: state.paginationError);
      }
    }
  }

  /// Both payload copies are encrypted before committing. A durable outbox
  /// prevents a temporary disconnect from silently losing a message.
  Future<bool> _sendPayload(String payload) async {
    try {
      final myPublicKey = await _cryptoService.getPublicKey();
      if (myPublicKey == null) throw StateError('No public key');
      final isSelfChat = recipientPublicKey == myPublicKey;
      final recipientCopy =
          await _cryptoService.encryptData(payload, recipientPublicKey);
      if (utf8.encode(recipientCopy).length > 10 * 1024 * 1024) {
        throw StateError(
            'Фото слишком большое. Выберите изображение поменьше.');
      }
      final localCopy = isSelfChat
          ? recipientCopy
          : await _cryptoService.encryptData(payload, myPublicKey);
      final random = Random.secure();
      final networkId =
          base64UrlEncode(List.generate(24, (_) => random.nextInt(256)))
              .replaceAll('=', '');
      await _chatRepository.sendMessage(
        conversationId: conversationId,
        senderId: currentSenderId,
        encryptedContent: localCopy,
        conversationName: recipientUsername,
        networkId: networkId,
        networkSender: currentUsername,
        status: isSelfChat ? 'read' : 'queued',
        recipient: isSelfChat ? null : recipientUsername,
        networkPayload: isSelfChat ? null : recipientCopy,
      );
      if (_isDisposed) return true;
      state = state.copyWith(clearReply: true, clearError: true);
      await _loadMessages();
      unawaited(_connectionService.flushOutbox());
      return true;
    } catch (e) {
      if (!_isDisposed) {
        state = state.copyWith(
            error: 'Не удалось отправить сообщение. Попробуйте ещё раз.');
      }
      return false;
    }
  }

  Future<bool> sendAndEncrypt(String plainText) async {
    if (plainText.trim().isEmpty) return false;
    final reply = state.replyTo;
    return _sendPayload(reply == null
        ? plainText
        : jsonEncode({
            't': plainText,
            'r': {
              's': reply.isMine ? currentUsername : recipientUsername,
              't': reply.isImage ? 'Фото' : reply.text
            },
          }));
  }

  Future<void> refresh() => _loadMessages();
  Future<bool> sendImage(List<int> imageBytes) =>
      _sendPayload('IMG:${base64Encode(imageBytes)}');

  /// Deletes a message locally and optionally for everyone.
  Future<void> deleteMessage(int msgId, {required bool forEveryone}) async {
    final message = state.messages.where((m) => m.id == msgId).firstOrNull;
    if (message == null) return;
    if (forEveryone) {
      if (!message.isMine ||
          message.networkId == null ||
          message.status == 'queued') {
        state = state.copyWith(
            error:
                'Ожидающее отправки сообщение можно отменить локальным удалением.');
        return;
      }
      final confirmed = await _connectionService.sendDeleteMessage(
          recipientUsername, message.networkId!);
      if (_isDisposed) return;
      if (!confirmed) {
        state = state.copyWith(
            error:
                'Сервер не подтвердил удаление для всех. Проверьте сеть и повторите.');
        return;
      }
    }
    await _chatRepository.deleteMessage(msgId);
    if (!_isDisposed) {
      state = state.copyWith(
          messages: state.messages.where((m) => m.id != msgId).toList());
    }
  }

  /// Set message to reply to.
  void setReply(DisplayMessage msg) {
    state = state.copyWith(replyTo: msg);
  }

  /// Clear reply.
  void clearReply() {
    state = state.copyWith(clearReply: true);
  }

  @override
  void dispose() {
    _isDisposed = true;
    _connectionService.unwatchUser(recipientUsername);
    _statusSub?.cancel();
    _connectionSub?.cancel();
    _deleteSub?.cancel();
    _messageStatusSub?.cancel();
    _wsSub?.cancel();
    _typingSub?.cancel();
    _typingTimeout?.cancel();
    super.dispose();
  }
}

/// Family provider for the chat messages state.
final chatMessagesProvider = StateNotifierProvider.autoDispose
    .family<ChatMessagesNotifier, ChatMessagesState, ChatMessagesParams>(
  (ref, params) {
    return ChatMessagesNotifier(
      conversationId: params.conversationId,
      currentSenderId: params.currentSenderId,
      recipientPublicKey: params.recipientPublicKey,
      recipientUsername: params.recipientUsername,
      currentUsername: params.currentUsername,
      chatRepository: ref.watch(chatRepositoryProvider),
      cryptoService: ref.watch(cryptoServiceProvider),
      connectionService: ref.watch(connectionServiceProvider),
    );
  },
);

class ChatMessagesParams {
  final int conversationId;
  final int currentSenderId;
  final String recipientPublicKey;
  final String recipientUsername;
  final String currentUsername;

  const ChatMessagesParams({
    required this.conversationId,
    required this.currentSenderId,
    required this.recipientPublicKey,
    required this.recipientUsername,
    required this.currentUsername,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatMessagesParams &&
          conversationId == other.conversationId &&
          currentSenderId == other.currentSenderId;

  @override
  int get hashCode => Object.hash(conversationId, currentSenderId);
}

/// Full-screen chat view with Telegram-style bubbles.
class ChatScreen extends ConsumerWidget {
  final int conversationId;
  final ChatScreenArgs args;

  const ChatScreen({
    super.key,
    required this.conversationId,
    required this.args,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(
        chatMessagesProvider(ChatMessagesParams(
            conversationId: conversationId,
            currentSenderId:
                (ref.read(authNotifierProvider).nickname ?? '').hashCode.abs(),
            recipientPublicKey: args.recipientPublicKey,
            recipientUsername: args.recipientUsername,
            currentUsername: ref.read(authNotifierProvider).nickname ?? '')),
        (previous, next) {
      if (previous?.messages != next.messages) {
        ref.invalidate(conversationsProvider);
      }
    });

    final authState = ref.watch(authNotifierProvider);
    final currentUsername = authState.nickname ?? '';
    final senderId = currentUsername.hashCode.abs();

    final params = ChatMessagesParams(
      conversationId: conversationId,
      currentSenderId: senderId,
      recipientPublicKey: args.recipientPublicKey,
      recipientUsername: args.recipientUsername,
      currentUsername: currentUsername,
    );

    final messagesState = ref.watch(chatMessagesProvider(params));
    final notifier = ref.read(chatMessagesProvider(params).notifier);

    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: Colors.black,
        toolbarHeight:
            68 + max(0, MediaQuery.textScalerOf(context).scale(16) - 16) * 2,
        shape: const Border(bottom: BorderSide(color: Color(0xFF1C1C1F))),
        leading: const BackButton(),
        leadingWidth: 48,
        titleSpacing: 0,
        title: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: args.conversationName == 'Избранное'
                ? null
                : () => context.push(
                    '/peer/${Uri.encodeComponent(args.recipientUsername)}',
                    extra: args.recipientPublicKey),
            child: Row(children: [
              Hero(
                  tag: 'chat-avatar-${args.recipientUsername}',
                  child: ShadeAvatar(
                      name: args.conversationName,
                      username: args.recipientUsername,
                      online: messagesState.userStatus?.online == true,
                      size: 40,
                      saved: args.conversationName == 'Избранное')),
              const SizedBox(width: 12),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(args.conversationName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    AnimatedSwitcher(
                        duration: ShadeMotion.duration(context, 160),
                        child: Text(
                            messagesState.isRecipientTyping
                                ? 'печатает…'
                                : (messagesState.userStatus?.displayText ??
                                    (args.conversationName == 'Избранное'
                                        ? 'Ваши личные заметки'
                                        : 'Личная переписка')),
                            key: ValueKey(messagesState.isRecipientTyping),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w400,
                                color:
                                    messagesState.userStatus?.online == true ||
                                            messagesState.isRecipientTyping
                                        ? ShadeColors.greenAccent
                                        : ShadeColors.textSecondary))),
                  ])),
            ])),
        actions: [
          IconButton(
              tooltip: 'Обновить переписку',
              icon: const Icon(Icons.refresh_rounded, size: 22),
              onPressed: () => notifier.refresh()),
          const SizedBox(width: 8)
        ],
      ),
      body: Column(
        children: [
          // Messages area
          Expanded(
            child: ShadeConversationBackground(
                child: _MessagesArea(
              messagesState: messagesState,
              onRefresh: () => notifier.refresh(),
              notifier: notifier,
              conversationId: conversationId,
              recipientUsername: args.recipientUsername,
              onReply: (msg) => notifier.setReply(msg),
            )),
          ),
          if (messagesState.error != null && messagesState.messages.isNotEmpty)
            Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                child: Text(
                    'Не удалось выполнить действие. Проверьте подключение и повторите.',
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12))),
          // Reply preview
          if (messagesState.replyTo != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: ShadeColors.surfaceElevated,
              child: Row(
                children: [
                  Container(width: 3, height: 40, color: ShadeColors.cyan),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          messagesState.replyTo!.isMine
                              ? 'Вы'
                              : args.recipientUsername,
                          style: const TextStyle(
                            color: ShadeColors.cyan,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          messagesState.replyTo!.isImage
                              ? 'Фото'
                              : messagesState.replyTo!.text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: ShadeColors.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded,
                        size: 18, color: ShadeColors.textMuted),
                    tooltip: 'Отменить ответ',
                    onPressed: () => notifier.clearReply(),
                  ),
                ],
              ),
            ),
          // Input area
          MessageInput(
            onSend: (text) async {
              if (!await notifier.sendAndEncrypt(text)) {
                throw StateError('Send failed');
              }
            },
            onImageSelected: (bytes) async {
              if (!await notifier.sendImage(bytes)) {
                throw StateError('Send failed');
              }
            },
            onTyping: () => notifier.notifyTyping(),
            onStopTyping: () => notifier.notifyStopTyping(),
          ),
        ],
      ),
    );
  }
}

class _MessagesArea extends StatefulWidget {
  final ChatMessagesState messagesState;
  final VoidCallback onRefresh;
  final ChatMessagesNotifier notifier;
  final int conversationId;
  final String recipientUsername;
  final ValueChanged<DisplayMessage>? onReply;

  const _MessagesArea({
    required this.messagesState,
    required this.onRefresh,
    required this.notifier,
    required this.conversationId,
    required this.recipientUsername,
    this.onReply,
  });

  @override
  State<_MessagesArea> createState() => _MessagesAreaState();
}

class _MessagesAreaState extends State<_MessagesArea> {
  final _scroll = ScrollController();
  final Set<int> _arrivals = {};
  final Map<int, GlobalKey> _anchors = {};
  int _unseen = 0;
  bool _away = false;

  @override
  void initState() {
    super.initState();
    NotificationService.cancelForConversation(widget.conversationId.toString());
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
    if (_scroll.position.extentAfter < 180 &&
        widget.messagesState.paginationError == null) {
      widget.notifier.loadMoreMessages();
    }
  }

  @override
  void didUpdateWidget(covariant _MessagesArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    final before = oldWidget.messagesState.messages;
    final after = widget.messagesState.messages;
    if (before.isEmpty || after.isEmpty || before.last.id == after.last.id) {
      return;
    }
    final known = before.map((m) => m.id).toSet();
    final anchor = after.indexWhere((m) => m.id == before.last.id);
    final added = anchor < 0
        ? <DisplayMessage>[]
        : after.skip(anchor + 1).where((m) => !known.contains(m.id)).toList();
    if (added.isEmpty) return;
    if (!_away) _arrivals.addAll(added.map((m) => m.id));
    if (_away && added.any((m) => m.isMine)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _toLatest();
      });
    } else if (_away && _scroll.hasClients) {
      _unseen += added.where((m) => !m.isMine).length;
      GlobalKey? anchorKey;
      double? anchorY;
      final area = context.findRenderObject() as RenderBox?;
      if (area != null && area.hasSize) {
        final bounds = area.localToGlobal(Offset.zero) & area.size;
        for (final key in _anchors.values) {
          final box = key.currentContext?.findRenderObject() as RenderBox?;
          if (box == null || !box.hasSize) continue;
          final y = box.localToGlobal(Offset.zero).dy;
          if (y >= bounds.top && y < bounds.bottom) {
            anchorKey = key;
            anchorY = y;
            break;
          }
        }
      }
      if (anchorKey != null && anchorY != null) {
        final key = anchorKey, y = anchorY;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scroll.hasClients) return;
          final box = key.currentContext?.findRenderObject() as RenderBox?;
          if (box == null || !box.hasSize) return;
          final delta = y - box.localToGlobal(Offset.zero).dy;
          _scroll.jumpTo((_scroll.offset + delta)
              .clamp(0, _scroll.position.maxScrollExtent));
        });
      }
    }

    final active = after.map((m) => m.id).toSet();
    _arrivals.removeWhere((id) => !active.contains(id));
    _anchors.removeWhere((id, _) => !active.contains(id));
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

  @override
  Widget build(BuildContext context) {
    final state = widget.messagesState;
    final msgs = state.messages;
    if (state.isLoading && msgs.isEmpty) {
      return const Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox.square(
            dimension: 24, child: ShadeLoadingIndicator(strokeWidth: 2)),
        SizedBox(height: 16),
        Text('Открываем переписку',
            style: TextStyle(color: ShadeColors.textSecondary)),
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
                  onPressed: widget.onRefresh,
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
    final hasTyping = state.isRecipientTyping;
    final offset = hasTyping ? 1 : 0;
    final indexes = <int, int>{
      for (var i = 0; i < msgs.length; i++)
        msgs[i].id: msgs.length - 1 - i + offset
    };
    bool grouped(DisplayMessage a, DisplayMessage b) =>
        a.isMine == b.isMine &&
        a.timestamp.year == b.timestamp.year &&
        a.timestamp.month == b.timestamp.month &&
        a.timestamp.day == b.timestamp.day &&
        b.timestamp.difference(a.timestamp).inMinutes.abs() < 5;
    return Stack(children: [
      ListView.builder(
          key: PageStorageKey('messages-${widget.conversationId}'),
          controller: _scroll,
          reverse: true,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.only(top: 8, bottom: 12),
          itemCount: msgs.length + offset + 1,
          findChildIndexCallback: (key) =>
              key is ValueKey<int> ? indexes[key.value] : null,
          itemBuilder: (context, index) {
            if (hasTyping && index == 0) return const _TypingBubble();
            final reversedIndex = msgs.length - 1 - (index - offset);
            if (reversedIndex < 0) {
              if (state.isLoadingMore) {
                return const Padding(
                    padding: EdgeInsets.all(18),
                    child: Center(
                        child: SizedBox.square(
                            dimension: 20,
                            child: ShadeLoadingIndicator(strokeWidth: 2))));
              }
              if (state.paginationError != null) {
                return Center(
                    child: TextButton.icon(
                        onPressed: widget.notifier.loadMoreMessages,
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('Загрузить историю ещё раз')));
              }
              return Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: 20, horizontal: 32),
                  child: Text(
                      state.hasMore
                          ? 'Потяните к началу переписки'
                          : 'Начало переписки',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 11, color: ShadeColors.textMuted)));
            }
            final msg = msgs[reversedIndex];
            final previous = reversedIndex > 0 ? msgs[reversedIndex - 1] : null;
            final next = reversedIndex + 1 < msgs.length
                ? msgs[reversedIndex + 1]
                : null;
            final startsDay = previous == null ||
                previous.timestamp.year != msg.timestamp.year ||
                previous.timestamp.month != msg.timestamp.month ||
                previous.timestamp.day != msg.timestamp.day;
            return Column(
                key: ValueKey(msg.id),
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (startsDay) ShadeDateSeparator(date: msg.timestamp),
                  ShadeMessageArrival(
                      key: ValueKey('arrival-${msg.id}'),
                      animate: _arrivals.remove(msg.id),
                      child: MessageBubble(
                          key: _anchors.putIfAbsent(msg.id, () => GlobalKey()),
                          text: msg.text,
                          timestamp: msg.timestamp,
                          isMine: msg.isMine,
                          isEncrypted: msg.decryptSuccess,
                          isImage: msg.isImage,
                          imageData: msg.imageData,
                          status: msg.status,
                          groupedWithPrevious:
                              previous != null && grouped(previous, msg),
                          groupedWithNext: next != null && grouped(msg, next),
                          onLongPress: () =>
                              _showDeleteMenu(context, msg, widget.notifier),
                          replyText: msg.replyText,
                          replySender: msg.replySender))
                ]);
          }),
      if (_away)
        Positioned(
            right: 16,
            bottom: 12,
            child: FloatingActionButton.small(
                key: const Key('jump-to-latest'),
                heroTag: 'latest-${widget.conversationId}',
                tooltip: _unseen > 0
                    ? 'Новых сообщений: $_unseen. К последним'
                    : 'К последним сообщениям',
                backgroundColor: const Color(0xFF29292D),
                onPressed: _toLatest,
                child: _unseen > 0
                    ? Text('$_unseen',
                        style: const TextStyle(fontWeight: FontWeight.w700))
                    : const Icon(Icons.arrow_downward_rounded, size: 21)))
    ]);
  }

  void _showDeleteMenu(
      BuildContext context, DisplayMessage msg, ChatMessagesNotifier notifier) {
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
                notifier.setReply(msg);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded,
                  color: ShadeColors.textSecondary),
              title: const Text('Удалить у себя',
                  style: TextStyle(color: ShadeColors.textPrimary)),
              onTap: () {
                Navigator.pop(ctx);
                notifier.deleteMessage(msg.id, forEveryone: false);
              },
            ),
            if (msg.isMine && msg.status != 'queued' && msg.networkId != null)
              ListTile(
                leading: const Icon(Icons.delete_forever_rounded,
                    color: Color(0xFFEF4444)),
                title: const Text('Удалить у всех',
                    style: TextStyle(color: Color(0xFFEF4444))),
                onTap: () {
                  Navigator.pop(ctx);
                  notifier.deleteMessage(msg.id, forEveryone: true);
                },
              ),
          ],
        )),
      ),
    );
  }
}

/// Animated typing bubble with three bouncing dots.
class _TypingBubble extends StatefulWidget {
  const _TypingBubble();

  @override
  State<_TypingBubble> createState() => _TypingBubbleState();
}

class _TypingBubbleState extends State<_TypingBubble>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
      _controller.value = .5;
    } else {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          color: ShadeColors.surfaceElevated,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(3, (i) {
                final delay = i * 0.2;
                final value = (_controller.value - delay) % 1.0;
                final bounce = (value < 0.5)
                    ? Curves.easeOut.transform(value * 2)
                    : Curves.easeIn.transform(2 - value * 2);
                return Container(
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  child: Transform.translate(
                    offset: Offset(0, -bounce * 6),
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: ShadeColors.violet
                            .withValues(alpha: 0.6 + bounce * 0.4),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                );
              }),
            );
          },
        ),
      ),
    );
  }
}

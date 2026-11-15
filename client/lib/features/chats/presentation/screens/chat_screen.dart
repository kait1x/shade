import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:math';
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
  final String? error;
  final bool isRecipientTyping;
  final UserStatus? userStatus;
  final DisplayMessage? replyTo;

  const ChatMessagesState({
    this.messages = const [],
    this.isLoading = true,
    this.error,
    this.isRecipientTyping = false,
    this.userStatus,
    this.replyTo,
  });

  ChatMessagesState copyWith({
    List<DisplayMessage>? messages,
    bool? isLoading,
    String? error,
    bool? isRecipientTyping,
    UserStatus? userStatus,
    DisplayMessage? replyTo,
    bool clearReply = false,
  }) {
    return ChatMessagesState(
      messages: messages ?? this.messages,
      isLoading: isLoading ?? this.isLoading,
      error: error,
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
  Future<void> _loadMessages() async {
    try {
      state = state.copyWith(isLoading: state.messages.isEmpty, error: null);

      final rawMessages = await _chatRepository.getMessages(
        conversationId,
        limit: _pageSize,
        offset: 0,
      );
      _loadedCount = rawMessages.length;
      _hasMore = _loadedCount >= _pageSize;

      final decrypted = await _chatRepository.decryptMessages(
        rawMessages,
        mySenderId: currentSenderId,
      );

      if (_isDisposed) return;
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
    if (_isLoadingMore || !_hasMore) return;

    try {
      _isLoadingMore = true;

      final rawMessages = await _chatRepository.getMessages(
        conversationId,
        limit: _pageSize,
        offset: _loadedCount,
      );

      if (rawMessages.isEmpty) {
        _hasMore = false;
        return;
      }

      _loadedCount += rawMessages.length;
      _hasMore = rawMessages.length >= _pageSize;

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

      // Prepend older messages to the beginning
      state = state.copyWith(
        messages: [...newMessages, ...state.messages],
      );
    } catch (e) {
      debugPrint('Error loading more messages: $e');
    } finally {
      _isLoadingMore = false;
    }
  }

  /// Both payload copies are encrypted before committing. A durable outbox
  /// prevents a temporary disconnect from silently losing a message.
  Future<void> _sendPayload(String payload) async {
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
      if (_isDisposed) return;
      state = state.copyWith(clearReply: true);
      await _loadMessages();
      unawaited(_connectionService.flushOutbox());
    } catch (e) {
      if (!_isDisposed) state = state.copyWith(error: e.toString());
    }
  }

  Future<void> sendAndEncrypt(String plainText) async {
    if (plainText.trim().isEmpty) return;
    final reply = state.replyTo;
    await _sendPayload(reply == null
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
  Future<void> sendImage(List<int> imageBytes) =>
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
        (_, __) {
      ref.invalidate(conversationsProvider);
    });
    // Clear notifications for this conversation
    NotificationService.cancelForConversation(conversationId.toString());

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
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
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
              ShadeAvatar(
                  name: args.conversationName,
                  size: 40,
                  saved: args.conversationName == 'Избранное'),
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
                    Text(
                        messagesState.isRecipientTyping
                            ? 'печатает…'
                            : (messagesState.userStatus?.displayText ??
                                (args.conversationName == 'Избранное'
                                    ? 'Ваши личные заметки'
                                    : 'Личная переписка')),
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w400,
                            color: messagesState.userStatus?.online == true ||
                                    messagesState.isRecipientTyping
                                ? ShadeColors.greenAccent
                                : ShadeColors.textSecondary)),
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
                child: Text(messagesState.error!,
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
                    onPressed: () => notifier.clearReply(),
                  ),
                ],
              ),
            ),
          // Input area
          MessageInput(
            onSend: (text) => notifier.sendAndEncrypt(text),
            onImageSelected: (bytes) => notifier.sendImage(bytes),
            onTyping: () => notifier.notifyTyping(),
            onStopTyping: () => notifier.notifyStopTyping(),
          ),
        ],
      ),
    );
  }
}

class _MessagesArea extends StatelessWidget {
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
  Widget build(BuildContext context) {
    // Show messages immediately, even while decrypting new ones
    final msgs = messagesState.messages;

    if (messagesState.error != null && msgs.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 48,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 12),
              const Text(
                'Loading Error',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: ShadeColors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                messagesState.error!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 13,
                  color: ShadeColors.textMuted,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (msgs.isEmpty) {
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
                Icons.lock_outline_rounded,
                size: 36,
                color: ShadeColors.violet,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Начните разговор',
              style: TextStyle(
                fontSize: 15,
                color: ShadeColors.textSecondary,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Напишите что-нибудь хорошее.',
              style: TextStyle(
                fontSize: 12,
                color: ShadeColors.textMuted,
              ),
            ),
          ],
        ),
      );
    }

    final hasTyping = messagesState.isRecipientTyping;
    final msgCount = msgs.length;

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        // Load more messages when scrolling to the top
        if (notification is ScrollUpdateNotification &&
            notification.metrics.extentAfter < 100) {
          notifier.loadMoreMessages();
          return true;
        }
        return false;
      },
      child: ListView.builder(
        reverse: true,
        padding: const EdgeInsets.only(top: 8, bottom: 8),
        itemCount:
            msgCount + (hasTyping ? 1 : 0) + (_isLoadingMoreIndicator ? 1 : 0),
        itemBuilder: (context, index) {
          // Loading indicator at the top
          if (_isLoadingMoreIndicator && index == 0) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 12.0),
              child: Center(
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          }

          // Typing bubble at the bottom (index 0 in reversed list)
          final adjustedIndex = _isLoadingMoreIndicator ? index - 1 : index;
          if (hasTyping && adjustedIndex == 0) {
            return const _TypingBubble();
          }
          final msgIndex = hasTyping ? adjustedIndex - 1 : adjustedIndex;
          final reversedIndex = msgCount - 1 - msgIndex;

          if (reversedIndex < 0 || reversedIndex >= msgCount) {
            return const SizedBox.shrink();
          }

          final msg = msgs[reversedIndex];
          final previous =
              reversedIndex > 0 ? msgs[reversedIndex - 1].timestamp : null;
          final startsDay = previous == null ||
              previous.year != msg.timestamp.year ||
              previous.month != msg.timestamp.month ||
              previous.day != msg.timestamp.day;
          return Column(
              key: ValueKey(msg.id),
              mainAxisSize: MainAxisSize.min,
              children: [
                if (startsDay) ShadeDateSeparator(date: msg.timestamp),
                MessageBubble(
                  text: msg.text,
                  timestamp: msg.timestamp,
                  isMine: msg.isMine,
                  isEncrypted: msg.decryptSuccess,
                  isImage: msg.isImage,
                  imageData: msg.imageData,
                  status: msg.status,
                  onLongPress: () => _showDeleteMenu(context, msg, notifier),
                  replyText: msg.replyText,
                  replySender: msg.replySender,
                )
              ]);
        },
      ),
    );
  }

  bool get _isLoadingMoreIndicator => false; // Will be handled by state

  void _showDeleteMenu(
      BuildContext context, DisplayMessage msg, ChatMessagesNotifier notifier) {
    showModalBottomSheet(
      context: context,
      backgroundColor: ShadeColors.surfaceCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
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
            if (msg.isMine)
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
        ),
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
    )..repeat();
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

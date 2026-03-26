import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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
  final int id;
  final String text;
  final DateTime timestamp;
  final bool isMine;
  final bool decryptSuccess;
  final bool isImage;
  final Uint8List? imageData;
  final String status; // 'sent', 'delivered', 'read'

  const DisplayMessage({
    required this.id,
    required this.text,
    required this.timestamp,
    required this.isMine,
    this.decryptSuccess = true,
    this.isImage = false,
    this.imageData,
    this.status = 'sent',
  });
}

/// State for the chat screen messages.
class ChatMessagesState {
  final List<DisplayMessage> messages;
  final bool isLoading;
  final String? error;
  final bool isRecipientTyping;
  final UserStatus? userStatus;

  const ChatMessagesState({
    this.messages = const [],
    this.isLoading = true,
    this.error,
    this.isRecipientTyping = false,
    this.userStatus,
  });

  ChatMessagesState copyWith({
    List<DisplayMessage>? messages,
    bool? isLoading,
    String? error,
    bool? isRecipientTyping,
    UserStatus? userStatus,
  }) {
    return ChatMessagesState(
      messages: messages ?? this.messages,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      isRecipientTyping: isRecipientTyping ?? this.isRecipientTyping,
      userStatus: userStatus ?? this.userStatus,
    );
  }
}

/// Notifier that loads, decrypts, and manages chat messages.
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
  Timer? _typingTimeout;

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

    // Send read receipt for all messages from this user
    if (recipientUsername != currentUsername &&
        _connectionService.isConnected) {
      _connectionService.sendMessageStatus('read', recipientUsername);
    }
  }

  StreamSubscription? _statusSub;

  void _watchUserStatus() {
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

      // Send delivered receipt
      if (_connectionService.isConnected) {
        _connectionService.sendMessageStatus('delivered', incoming.from);
      }

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
    _deleteSub = _connectionService.messageDeleted.listen((event) {
      if (event.from == recipientUsername) {
        final msgId = int.tryParse(event.msgId);
        if (msgId != null) {
          final updated = state.messages.where((m) => m.id != msgId).toList();
          state = state.copyWith(messages: updated);
          _chatRepository.deleteMessage(msgId);
        }
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

  Future<void> _loadMessages() async {
    try {
      state = state.copyWith(isLoading: true, error: null);

      final rawMessages = await _chatRepository.getMessages(conversationId);
      final decrypted = await _chatRepository.decryptMessages(
        rawMessages,
        mySenderId: currentSenderId,
      );

      state = state.copyWith(
        messages: decrypted
            .map((d) => DisplayMessage(
                  id: d.id,
                  text: d.text,
                  timestamp: d.timestamp,
                  isMine: d.isMine,
                  decryptSuccess: d.decryptSuccess,
                  isImage: d.isImage,
                  imageData: d.imageData,
                ))
            .toList(),
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
    }
  }

  /// Encrypts [plainText], persists locally, and sends via WebSocket.
  Future<void> sendAndEncrypt(String plainText) async {
    try {
      final myPublicKey = await _cryptoService.getPublicKey();
      if (myPublicKey == null) throw StateError('No public key');

      final isSelfChat = recipientPublicKey == myPublicKey;

      // Encrypt for recipient (for network transmission)
      final encryptedForRecipient = await _cryptoService.encryptData(
        plainText,
        recipientPublicKey,
      );

      // Encrypt for self (for local display)
      final encryptedForSelf = isSelfChat
          ? encryptedForRecipient // same key — reuse
          : await _cryptoService.encryptData(plainText, myPublicKey);

      // Save locally
      await _chatRepository.sendMessage(
        conversationId: conversationId,
        senderId: currentSenderId,
        encryptedContent: encryptedForSelf,
        conversationName: recipientUsername,
      );

      // Send recipient-encrypted version over the network (skip for self-chat)
      if (!isSelfChat) {
        try {
          if (_connectionService.isConnected) {
            _connectionService.sendMessage(
                recipientUsername, encryptedForRecipient);
          }
        } catch (_) {
          debugPrint('[ChatMessages] WS send failed, message saved locally');
        }
      }

      // Add sent message to UI immediately (no full reload)
      final newMsg = DisplayMessage(
        id: DateTime.now().millisecondsSinceEpoch,
        text: plainText,
        timestamp: DateTime.now(),
        isMine: true,
        decryptSuccess: true,
      );
      state = state.copyWith(
        messages: [...state.messages, newMsg],
      );
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  /// Reloads messages from the database.
  Future<void> refresh() => _loadMessages();

  /// Encrypts and sends an image.
  Future<void> sendImage(List<int> imageBytes) async {
    try {
      final myPublicKey = await _cryptoService.getPublicKey();
      if (myPublicKey == null) throw StateError('No public key');

      final isSelfChat = recipientPublicKey == myPublicKey;
      final b64 = base64.encode(imageBytes);
      final payload = 'IMG:$b64';

      // Encrypt for recipient
      final encryptedForRecipient = await _cryptoService.encryptData(
        payload,
        recipientPublicKey,
      );

      // Encrypt for self
      final encryptedForSelf = isSelfChat
          ? encryptedForRecipient
          : await _cryptoService.encryptData(payload, myPublicKey);

      // Save locally
      await _chatRepository.sendMessage(
        conversationId: conversationId,
        senderId: currentSenderId,
        encryptedContent: encryptedForSelf,
        conversationName: recipientUsername,
      );

      // Send via WebSocket
      if (!isSelfChat) {
        try {
          if (_connectionService.isConnected) {
            _connectionService.sendMessage(
                recipientUsername, encryptedForRecipient);
          }
        } catch (_) {}
      }

      // Add to UI
      final newMsg = DisplayMessage(
        id: DateTime.now().millisecondsSinceEpoch,
        text: '',
        timestamp: DateTime.now(),
        isMine: true,
        decryptSuccess: true,
        isImage: true,
        imageData: Uint8List.fromList(imageBytes),
      );
      state = state.copyWith(
        messages: [...state.messages, newMsg],
      );
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  /// Deletes a message locally and optionally for everyone.
  Future<void> deleteMessage(int msgId, {required bool forEveryone}) async {
    // Remove from local state
    final updated = state.messages.where((m) => m.id != msgId).toList();
    state = state.copyWith(messages: updated);

    // Remove from database
    await _chatRepository.deleteMessage(msgId);

    // If for everyone, notify via server
    if (forEveryone && _connectionService.isConnected) {
      _connectionService.sendDeleteMessage(recipientUsername, msgId.toString());
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _connectionService.unwatchUser(recipientUsername);
    _statusSub?.cancel();
    _deleteSub?.cancel();
    _wsSub?.cancel();
    _typingSub?.cancel();
    _typingTimeout?.cancel();
    super.dispose();
  }
}

/// Family provider for the chat messages state.
final chatMessagesProvider = StateNotifierProvider.family<ChatMessagesNotifier,
    ChatMessagesState, ChatMessagesParams>(
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
        leadingWidth: 56,
        title: Row(
          children: [
            // Avatar
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    ShadeColors.violet.withOpacity(0.7),
                    ShadeColors.cyan.withOpacity(0.4),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Center(
                child: Text(
                  args.conversationName.isNotEmpty
                      ? args.conversationName[0].toUpperCase()
                      : '?',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            // Name + status
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    args.conversationName,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (messagesState.userStatus != null)
                    Text(
                      messagesState.userStatus!.displayText,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: messagesState.userStatus!.online
                                ? ShadeColors.greenAccent
                                : ShadeColors.textMuted,
                          ),
                    )
                  else
                    Text(
                      'E2EE · RSA 4096',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: ShadeColors.greenAccent,
                          ),
                    ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, size: 20),
            tooltip: 'Обновить',
            onPressed: () => notifier.refresh(),
          ),
          const SizedBox(width: 8),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(
            height: 0.5,
            color: ShadeColors.greyBorder,
          ),
        ),
      ),
      body: Column(
        children: [
          // Messages area
          Expanded(
            child: _MessagesArea(
              messagesState: messagesState,
              onRefresh: () => notifier.refresh(),
              notifier: notifier,
              conversationId: conversationId,
              recipientUsername: args.recipientUsername,
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

  const _MessagesArea({
    required this.messagesState,
    required this.onRefresh,
    required this.notifier,
    required this.conversationId,
    required this.recipientUsername,
  });

  @override
  Widget build(BuildContext context) {
    // Show messages immediately, even while decrypting new ones
    final msgs = messagesState.messages;

    if (messagesState.error != null) {
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
              'Start an encrypted conversation',
              style: TextStyle(
                fontSize: 15,
                color: ShadeColors.textSecondary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Messages are end-to-end encrypted',
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

    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      itemCount: msgCount + (hasTyping ? 1 : 0),
      itemBuilder: (context, index) {
        // Typing bubble at the bottom (index 0 in reversed list)
        if (hasTyping && index == 0) {
          return const _TypingBubble();
        }
        final msgIndex = hasTyping ? index - 1 : index;
        final reversedIndex = msgCount - 1 - msgIndex;
        final msg = msgs[reversedIndex];
        return MessageBubble(
          key: ValueKey(msg.id),
          text: msg.text,
          timestamp: msg.timestamp,
          isMine: msg.isMine,
          isEncrypted: msg.decryptSuccess,
          isImage: msg.isImage,
          imageData: msg.imageData,
          status: msg.status,
          onLongPress: () => _showDeleteMenu(context, msg, notifier),
        );
      },
    );
  }

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
              color: Colors.black.withOpacity(0.3),
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
                        color:
                            ShadeColors.violet.withOpacity(0.6 + bounce * 0.4),
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

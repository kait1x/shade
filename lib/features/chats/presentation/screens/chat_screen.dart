import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shade/core/services/connection_service.dart';
import 'package:shade/core/services/crypto_service.dart';
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

  const DisplayMessage({
    required this.id,
    required this.text,
    required this.timestamp,
    required this.isMine,
    this.decryptSuccess = true,
  });
}

/// State for the chat screen messages.
class ChatMessagesState {
  final List<DisplayMessage> messages;
  final bool isLoading;
  final String? error;
  final bool isRecipientTyping;

  const ChatMessagesState({
    this.messages = const [],
    this.isLoading = true,
    this.error,
    this.isRecipientTyping = false,
  });

  ChatMessagesState copyWith({
    List<DisplayMessage>? messages,
    bool? isLoading,
    String? error,
    bool? isRecipientTyping,
  }) {
    return ChatMessagesState(
      messages: messages ?? this.messages,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      isRecipientTyping: isRecipientTyping ?? this.isRecipientTyping,
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
  }

  void _listenForIncoming() {
    _wsSub = _connectionService.messages.listen((incoming) async {
      // Only handle messages from our conversation partner
      if (incoming.from != recipientUsername) return;

      try {
        // Persist encrypted message locally
        await _chatRepository.sendMessage(
          conversationId: conversationId,
          senderId: recipientUsername.hashCode,
          encryptedContent: incoming.data,
          conversationName: recipientUsername,
        );
        // Reload and decrypt
        await _loadMessages();
      } catch (e) {
        debugPrint('[ChatMessages] incoming error: $e');
      }
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
      final decrypted = await _decryptMessages(rawMessages);

      state = state.copyWith(messages: decrypted, isLoading: false);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
    }
  }

  Future<List<DisplayMessage>> _decryptMessages(
    List<Message> rawMessages,
  ) async {
    final result = <DisplayMessage>[];
    for (final msg in rawMessages) {
      try {
        final plainText = await _cryptoService.decryptMessage(
          msg.encryptedContent,
        );
        result.add(DisplayMessage(
          id: msg.id,
          text: plainText,
          timestamp: msg.timestamp,
          isMine: msg.senderId == currentSenderId,
        ));
      } catch (e) {
        debugPrint('[ChatMessages] decrypt error: $e');
        result.add(DisplayMessage(
          id: msg.id,
          text: '[Не удалось расшифровать]',
          timestamp: msg.timestamp,
          isMine: msg.senderId == currentSenderId,
          decryptSuccess: false,
        ));
      }
    }
    return result;
  }

  /// Encrypts [plainText], persists locally, and sends via WebSocket.
  Future<void> sendAndEncrypt(String plainText) async {
    try {
      final myPublicKey = await _cryptoService.getPublicKey();
      if (myPublicKey == null) throw StateError('No public key');

      // Encrypt for recipient (for network transmission)
      final encryptedForRecipient = await _cryptoService.encryptData(
        plainText,
        recipientPublicKey,
      );

      // Encrypt for self (for local display)
      final encryptedForSelf = await _cryptoService.encryptData(
        plainText,
        myPublicKey,
      );

      // Save locally — use self-encrypted version so sender can read
      await _chatRepository.sendMessage(
        conversationId: conversationId,
        senderId: currentSenderId,
        encryptedContent: encryptedForSelf,
        conversationName: recipientUsername,
      );

      // Send recipient-encrypted version over the network
      try {
        if (_connectionService.isConnected) {
          _connectionService.sendMessage(
              recipientUsername, encryptedForRecipient);
        }
      } catch (_) {
        debugPrint('[ChatMessages] WS send failed, message saved locally');
      }

      await _loadMessages();
    } catch (e) {
      state = state.copyWith(error: e.toString());
    }
  }

  /// Reloads messages from the database.
  Future<void> refresh() => _loadMessages();

  @override
  @override
  void dispose() {
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
    final authState = ref.watch(authNotifierProvider);
    final senderId = authState.nickname?.hashCode ?? 1;
    final currentUsername = authState.nickname ?? '';

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
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(args.conversationName),
            Text(
              'E2EE · RSA 4096',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: ShadeColors.greenAccent,
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
            ),
          ),
          // Typing indicator
          if (messagesState.isRecipientTyping)
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 4),
              child: Row(
                children: [
                  Text(
                    '${args.conversationName} печатает',
                    style: TextStyle(
                      fontSize: 12,
                      color: ShadeColors.textMuted,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: ShadeColors.violet.withOpacity(0.5),
                    ),
                  ),
                ],
              ),
            ),
          // Input area
          MessageInput(
            onSend: (text) => notifier.sendAndEncrypt(text),
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

  const _MessagesArea({
    required this.messagesState,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    if (messagesState.isLoading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 32,
              height: 32,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            SizedBox(height: 16),
            Text(
              'Decrypting messages...',
              style: TextStyle(color: ShadeColors.textSecondary),
            ),
          ],
        ),
      );
    }

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

    if (messagesState.messages.isEmpty) {
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

    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      itemCount: messagesState.messages.length,
      itemBuilder: (context, index) {
        final reversedIndex = messagesState.messages.length - 1 - index;
        final msg = messagesState.messages[reversedIndex];
        return MessageBubble(
          key: ValueKey(msg.id),
          text: msg.text,
          timestamp: msg.timestamp,
          isMine: msg.isMine,
          isEncrypted: msg.decryptSuccess,
        );
      },
    );
  }
}

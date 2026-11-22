import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../../../core/services/device_v2/protocol.dart';
import '../../../core/services/device_v2/transport.dart';
import '../../../core/theme/shade_theme.dart';
import '../../../core/widgets/shade_motion.dart';
import '../../../core/widgets/shade_logo.dart';
import '../../../core/widgets/shade_welcome.dart';
import '../../auth/data/repositories/auth_notifier.dart';
import '../../chats/presentation/widgets/message_bubble.dart';
import '../../chats/presentation/widgets/message_input.dart';
import '../data/alpha_v2_backend.dart';
import 'pairing_new_device_screen.dart';
import 'recovery_screen.dart' show saveNativeRecoveryFile;

/// Экран Alpha v2: явная enrollment legacy-устройства, сверка genesis digest
/// контакта и E2EE-чат с Web-устройствами через изолированный alpha-процесс.
/// Production v1-чаты не изменяются.
class AlphaV2Screen extends ConsumerStatefulWidget {
  final AlphaV2Backend? backend;
  final bool startWithGoogle;
  static const defaultOrigin = String.fromEnvironment(
    'ALPHA_ORIGIN',
    defaultValue: 'https://alpha.shadechat.ru',
  );

  const AlphaV2Screen({super.key, this.backend, this.startWithGoogle = false});

  @override
  ConsumerState<AlphaV2Screen> createState() => _AlphaV2ScreenState();
}

enum _Stage { loading, connect, register, pair, enroll, recovery, home, chat }

class _AlphaV2ScreenState extends ConsumerState<AlphaV2Screen> {
  late final AlphaV2Backend _backend;
  late final bool _ownedBackend;
  _Stage _stage = _Stage.loading;
  String? _error;
  bool _busy = false;
  bool _showRecoveryPhrase = false;
  final _origin = TextEditingController(text: AlphaV2Screen.defaultOrigin);
  final _nickname = TextEditingController();
  final _passphrase = TextEditingController();
  Map<String, dynamic>? _recovery;
  List<Map<String, dynamic>> _contacts = [];
  String? _peer;
  List<Map<String, dynamic>> _messages = [];
  bool _peerBlocked = false;
  final Map<String, List<Map<String, dynamic>>> _delivery = {};
  Timer? _chatTimer;
  Map<String, dynamic>? _replyTo;
  final ScrollController _scroll = ScrollController();
  bool _atBottom = true;
  int _newWhileAway = 0;
  String? _typingPeer;
  Timer? _typingTimer;
  final Map<String, bool> _presence = {};

  @override
  void initState() {
    super.initState();
    _ownedBackend = widget.backend == null;
    _backend = widget.backend ??
        RealAlphaV2Backend(
            crypto: ref.read(cryptoServiceProvider),
            database: ref.read(databaseServiceProvider));
    _scroll.addListener(_onScroll);
    _backend.onTyping = (account, until) {
      if (!mounted || _peer != account) return;
      _typingTimer?.cancel();
      setState(() => _typingPeer = account);
      final ms = until - DateTime.now().millisecondsSinceEpoch;
      _typingTimer = Timer(Duration(milliseconds: ms.clamp(0, 5000)), () {
        if (mounted) setState(() => _typingPeer = null);
      });
    };
    _backend.onPresence = (account, online) {
      if (mounted) setState(() => _presence[account] = online);
    };
    if (widget.startWithGoogle) {
      _stage = _Stage.connect;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _connect();
      });
    } else {
      _init();
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final atBottom =
        _scroll.position.pixels >= _scroll.position.maxScrollExtent - 40;
    if (atBottom != _atBottom) {
      setState(() {
        _atBottom = atBottom;
        if (atBottom) _newWhileAway = 0;
      });
    }
  }

  void _jumpToLatest() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(_scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    setState(() {
      _atBottom = true;
      _newWhileAway = 0;
    });
  }

  @override
  void dispose() {
    _chatTimer?.cancel();
    _typingTimer?.cancel();
    _origin.dispose();
    _nickname.dispose();
    _passphrase.dispose();
    _scroll.dispose();
    if (_ownedBackend) _backend.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => _error = _errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _errorText(Object error) {
    if (!widget.startWithGoogle) return error.toString();
    if (error is GoogleSignInException) {
      if (error.code == GoogleSignInExceptionCode.canceled) return null;
      return 'Не удалось войти через Google. Попробуйте ещё раз или откройте Shade в браузере.';
    }
    if (error is SocketException || error is TimeoutException) {
      return 'Нет связи с Shade. Проверьте интернет и попробуйте снова.';
    }
    if (error is AlphaTransportException) {
      if (error.status == 429)
        return 'Слишком много попыток. Подождите немного и повторите.';
      if (error.status == 401)
        return 'Сессия истекла. Вернитесь назад и снова войдите через Google.';
      if (error.code == 'account_requires_linking')
        return 'Аккаунт уже есть. Вернитесь назад и выберите «Восстановить доступ».';
      if (_stage == _Stage.register && error.status == 409)
        return 'Никнейм занят. Выберите другой.';
    }
    if (error is StateError &&
        error.message.toString().contains('Recovery-фраза')) {
      return 'Введите ту же фразу, которую выбрали при первой попытке регистрации.';
    }
    if (error is StateError &&
        error.message.toString().contains('Аккаунт уже зарегистрирован')) {
      return 'Аккаунт уже есть. Вернитесь назад и выберите «Восстановить доступ».';
    }
    return 'Не получилось продолжить. Попробуйте снова или откройте Shade в браузере.';
  }

  Future<void> _init() async {
    await _run(() async {
      await _backend.initialize();
      if (!mounted) return;
      setState(() {
        _stage = _backend.hasSession
            ? (_backend.enrolled ? _Stage.home : _Stage.enroll)
            : _Stage.connect;
      });
      if (_stage == _Stage.home) await _loadContacts();
    });
  }

  Future<void> _loadContacts() async {
    final contacts = await _backend.contacts();
    for (final c in contacts) {
      if (c['confirmed'] == true) _backend.watch(c['account'] as String);
    }
    if (mounted) setState(() => _contacts = contacts);
  }

  Future<void> _connect() async {
    final origin = _origin.text.trim();
    if (origin.isEmpty || origin == 'https://') {
      setState(() => _error = 'Укажите origin alpha-сервера (https).');
      return;
    }
    await _run(() async {
      final idToken = await _backend.requestGoogleIdToken(origin);
      await _backend.connect(origin, idToken);
      if (!mounted) return;
      if (widget.startWithGoogle && _backend.enrolled) {
        Navigator.of(context).pop();
        return;
      }
      setState(() {
        if (_backend.registrationPending) {
          _nickname.text = _backend.account ?? '';
          _stage = _Stage.register;
        } else if (_backend.pairingRepository != null) {
          _stage = _Stage.pair;
        } else {
          _stage = _backend.enrolled ? _Stage.home : _Stage.enroll;
        }
      });
      if (_stage == _Stage.home) await _loadContacts();
    });
  }

  Future<void> _connectWithKey() async {
    final origin = _origin.text.trim();
    if (origin.isEmpty || origin == 'https://') {
      setState(() => _error = 'Укажите origin alpha-сервера (https).');
      return;
    }
    await _run(() async {
      await _backend.connectWithLegacyKey(origin);
      if (!mounted) return;
      setState(() => _stage = _backend.enrolled ? _Stage.home : _Stage.enroll);
      if (_stage == _Stage.home) await _loadContacts();
    });
  }

  void _generateRecoveryPhrase() {
    if (_passphrase.text.isNotEmpty) return;
    final random = Random.secure();
    const alphabet = 'abcdefghjkmnpqrstuvwxyz23456789';
    final groups = List.generate(
        6,
        (_) =>
            List.generate(5, (_) => alphabet[random.nextInt(alphabet.length)])
                .join());
    _passphrase.text = groups.join('-');
    setState(() {
      _showRecoveryPhrase = true;
      _error = null;
    });
  }

  Future<void> _copyRecoveryPhrase() async {
    if (_passphrase.text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _passphrase.text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Фраза восстановления скопирована')));
    }
  }

  Future<void> _register() async {
    final account = _nickname.text.trim().toLowerCase();
    if (!RegExp(r'^[a-z0-9_]{3,32}$').hasMatch(account)) {
      setState(() =>
          _error = 'Никнейм: 3–32 латинские буквы, цифры или подчёркивания.');
      return;
    }
    if (_passphrase.text.length < 24) {
      setState(() => _error = 'Recovery-фраза: минимум 24 символа.');
      return;
    }
    await _run(() async {
      final recovery = await _backend.register(account, _passphrase.text);
      if (!mounted) return;
      _passphrase.clear();
      setState(() {
        _recovery = recovery;
        _stage = _Stage.recovery;
      });
    });
  }

  Future<void> _enroll() async {
    if (_passphrase.text.length < 24) {
      setState(() => _error =
          'Recovery-фраза: минимум 24 символа. Она не покидает устройство.');
      return;
    }
    await _run(() async {
      final result = await _backend.enroll(_passphrase.text);
      if (!mounted) return;
      setState(() {
        _recovery = result['recovery'] as Map<String, dynamic>;
        _stage = _Stage.recovery;
      });
    });
  }

  Future<void> _addContact() async {
    final accountController = TextEditingController();
    final digestController = TextEditingController();
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
                backgroundColor: ShadeColors.surfaceCard,
                title: const Text('Сверка контакта',
                    style: TextStyle(
                        color: ShadeColors.textPrimary, fontSize: 17)),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text(
                      'Введите genesis digest собеседника, полученный по независимому доверенному каналу. До сверки отправка и ACK заблокированы.',
                      style: TextStyle(
                          color: ShadeColors.textSecondary,
                          fontSize: 13,
                          height: 1.4)),
                  const SizedBox(height: 16),
                  TextField(
                      controller: accountController,
                      autofocus: true,
                      style: const TextStyle(color: ShadeColors.textPrimary),
                      decoration: const InputDecoration(
                          labelText: 'Аккаунт', hintText: 'nickname')),
                  const SizedBox(height: 12),
                  TextField(
                      controller: digestController,
                      style: const TextStyle(
                          color: ShadeColors.textPrimary,
                          fontFamily: 'monospace',
                          fontSize: 12),
                      decoration: const InputDecoration(
                          labelText: 'Genesis digest (64 hex)')),
                ]),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Отмена')),
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Сверить')),
                ]));
    if (confirmed != true || !mounted) return;
    final account = accountController.text.trim();
    final digest = digestController.text.trim();
    if (!accountPattern.hasMatch(account)) {
      setState(() => _error = 'Аккаунт: 3–32 символа [a-z0-9_].');
      return;
    }
    if (!hex64Pattern.hasMatch(digest)) {
      setState(() => _error = 'Genesis digest: ровно 64 hex-символа.');
      return;
    }
    await _run(() async {
      await _backend.confirmContact(account, digest);
      await _loadContacts();
    });
  }

  Future<void> _openChat(String peer) async {
    await _run(() async {
      _peer = peer;
      _delivery.clear();
      _replyTo = null;
      _newWhileAway = 0;
      _atBottom = true;
      _typingPeer = null;
      await _loadMessages();
      if (!mounted) return;
      setState(() => _stage = _Stage.chat);
      _backend.watch(peer);
      WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToLatest());
      _chatTimer?.cancel();
      _chatTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
        try {
          await _backend.sync();
          await _loadMessages();
        } catch (_) {
          // Следующий периодический fetch повторит попытку.
        }
      });
    });
  }

  Future<void> _loadMessages() async {
    final peer = _peer;
    if (peer == null) return;
    final messages = await _backend.messages(peer);
    for (final m in messages) {
      if (m['direction'] == 'out') {
        try {
          _delivery[m['ref'] as String] =
              await _backend.delivery(m['ref'] as String);
        } catch (_) {
          // Статус доставки обновится при следующем опросе.
        }
      }
    }
    if (!mounted) return;
    final blocked = await _backend.peerUpgradeBlocked(peer);
    if (!mounted) return;
    final previousRefs = _messages.map((m) => m['ref']).toSet();
    final freshIncoming = messages
        .where(
            (m) => m['direction'] == 'in' && !previousRefs.contains(m['ref']))
        .length;
    setState(() {
      _messages = messages;
      _peerBlocked = blocked;
      if (!_atBottom) _newWhileAway += freshIncoming;
    });
    // Read-ACK: просмотренные входящие подтверждаются подписанной операцией.
    final unread = messages
        .where((m) => m['direction'] == 'in' && m['status'] != 'retracted')
        .map((m) => m['ref'] as String)
        .toList();
    if (unread.isNotEmpty) {
      _backend.markRead(unread).catchError((Object _) {});
    }
    if (_atBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  Future<void> _send(String text) async {
    final peer = _peer;
    if (peer == null || text.trim().isEmpty) return;
    final replyTo = _replyTo;
    final reply = replyTo == null
        ? null
        : {
            'ref': replyTo['ref'],
            'from': replyTo['direction'] == 'out' ? _backend.account : peer,
            'text': replyTo['text']
          };
    await _run(() async {
      await _backend.send(peer, text, reply: reply);
      if (mounted) setState(() => _replyTo = null);
      await _loadMessages();
      _jumpToLatest();
    });
  }

  Future<void> _messageMenu(Map<String, dynamic> message) async {
    final action = await showModalBottomSheet<String>(
        context: context,
        backgroundColor: ShadeColors.surfaceCard,
        builder: (ctx) => SafeArea(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(
                  leading: const Icon(Icons.reply_rounded,
                      color: ShadeColors.textPrimary),
                  title: const Text('Ответить',
                      style: TextStyle(color: ShadeColors.textPrimary)),
                  onTap: () => Navigator.pop(ctx, 'reply')),
              ListTile(
                  leading: const Icon(Icons.delete_outline_rounded,
                      color: Color(0xFFEF4444)),
                  title: const Text('Удалить у себя',
                      style: TextStyle(color: Color(0xFFEF4444))),
                  subtitle: const Text('Другие устройства сохранят свою копию',
                      style: TextStyle(
                          color: ShadeColors.textSecondary, fontSize: 12)),
                  onTap: () => Navigator.pop(ctx, 'delete')),
              if (message['direction'] == 'out' &&
                  message['status'] != 'retracted')
                ListTile(
                    leading: const Icon(Icons.undo_rounded,
                        color: Color(0xFFEF4444)),
                    title: const Text('Отозвать у всех',
                        style: TextStyle(color: Color(0xFFEF4444))),
                    subtitle: const Text(
                        'Недоставленные копии удаляются с сервера',
                        style: TextStyle(
                            color: ShadeColors.textSecondary, fontSize: 12)),
                    onTap: () => Navigator.pop(ctx, 'retract')),
            ])));
    if (!mounted || action == null) return;
    if (action == 'reply') {
      setState(() => _replyTo = message);
      return;
    }
    if (action == 'retract') {
      await _run(() async {
        await _backend.retract(message['ref'] as String);
        await _loadMessages();
      });
      return;
    }
    await _run(() async {
      await _backend.deleteLocal(message['ref'] as String);
      if (mounted && _replyTo?['ref'] == message['ref']) {
        setState(() => _replyTo = null);
      }
      await _loadMessages();
    });
  }

  void _leaveChat() {
    _chatTimer?.cancel();
    _typingTimer?.cancel();
    final peer = _peer;
    if (peer != null) _backend.unwatch(peer);
    setState(() {
      _stage = _Stage.home;
      _peer = null;
      _typingPeer = null;
    });
    _loadContacts();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.startWithGoogle && _stage == _Stage.connect) {
      return ShadeWelcomeLayout(
        fillScreen: true,
        card: (compact) => [
          const Text('Вход в Shade',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(_error ?? 'Выберите аккаунт Google, чтобы продолжить.',
              style: const TextStyle(
                  color: ShadeColors.textSecondary, height: 1.5)),
          const SizedBox(height: 16),
          ShadeGoogleButton(
            onPressed: _connect,
            progress: _busy ? 'Подключаем…' : null,
          ),
          TextButton.icon(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.arrow_back_rounded, size: 18),
            label: const Text('Вернуться ко входу'),
          ),
        ],
        footer: const [],
      );
    }
    return Scaffold(
        backgroundColor: ShadeColors.black,
        appBar: AppBar(
            backgroundColor: ShadeColors.black,
            title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                      _stage == _Stage.chat
                          ? (_peer == _backend.account
                              ? 'Избранное'
                              : _peer ?? '')
                          : 'Shade',
                      style: const TextStyle(
                          color: ShadeColors.textPrimary, fontSize: 17)),
                  if (_stage == _Stage.chat && _typingPeer == _peer)
                    const Text('печатает…',
                        style: TextStyle(
                            color: ShadeColors.textMuted, fontSize: 11)),
                ]),
            leading: _stage == _Stage.chat
                ? IconButton(
                    icon: const Icon(Icons.arrow_back_rounded,
                        color: ShadeColors.textPrimary),
                    onPressed: _leaveChat)
                : null),
        body: SafeArea(
            child: Center(
                child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: _buildStage()))));
  }

  Widget _buildStage() {
    if (_stage == _Stage.loading || (_busy && _stage == _Stage.loading)) {
      return const Center(child: ShadeLoadingIndicator());
    }
    return Column(children: [
      if (_error != null)
        Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: ShadeColors.surfaceCard,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: const Color(0xFFEF4444).withValues(alpha: .5))),
            child: Text(_error!,
                style: const TextStyle(
                    color: Color(0xFFEF4444), fontSize: 12.5, height: 1.4))),
      Expanded(
          child: switch (_stage) {
        _Stage.loading => const Center(child: ShadeLoadingIndicator()),
        _Stage.connect => _buildConnect(),
        _Stage.register => _buildRegister(),
        _Stage.pair => _buildPairing(),
        _Stage.enroll => _buildEnroll(),
        _Stage.recovery => _buildRecovery(),
        _Stage.home => _buildHome(),
        _Stage.chat => _buildChat(),
      }),
    ]);
  }

  Widget _field(TextEditingController controller, String label,
      {bool obscure = false,
      String? hint,
      Widget? suffix,
      ValueChanged<String>? onChanged}) {
    return TextField(
        controller: controller,
        obscureText: obscure,
        onChanged: onChanged,
        style: const TextStyle(color: ShadeColors.textPrimary, fontSize: 14),
        decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            suffixIcon: suffix,
            labelStyle: const TextStyle(color: ShadeColors.textSecondary),
            hintStyle: const TextStyle(color: ShadeColors.textMuted),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: ShadeColors.greyBorder)),
            focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: ShadeColors.textMuted))));
  }

  Widget _primaryButton(String label, VoidCallback? onPressed) {
    return SizedBox(
        width: double.infinity,
        height: 48,
        child: FilledButton(
            onPressed: _busy ? null : onPressed,
            style: FilledButton.styleFrom(
                backgroundColor: ShadeColors.surfaceElevated,
                foregroundColor: ShadeColors.textPrimary,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: const BorderSide(color: ShadeColors.greyBorder))),
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: ShadeColors.textSecondary))
                : Text(label, style: const TextStyle(fontSize: 14))));
  }

  Widget _buildConnect() {
    return ListView(padding: const EdgeInsets.all(20), children: [
      Text(widget.startWithGoogle ? 'Вход в Shade' : 'Подключение к Shade',
          style: const TextStyle(
              color: ShadeColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      const Text('Используйте Google, чтобы войти или создать аккаунт.',
          style: TextStyle(color: ShadeColors.textSecondary, height: 1.5)),
      const SizedBox(height: 20),
      if (!widget.startWithGoogle) ...[
        _field(_origin, 'Адрес сервера', hint: AlphaV2Screen.defaultOrigin),
        const SizedBox(height: 16),
      ],
      _primaryButton('Продолжить с Google', _connect),
      if (!widget.startWithGoogle) ...[
        const SizedBox(height: 12),
        TextButton(
          onPressed: _busy ? null : _connectWithKey,
          child: const Text('Войти ключом v1 (без Google)'),
        ),
      ],
    ]);
  }

  Widget _buildPairing() {
    return ListView(padding: const EdgeInsets.all(20), children: [
      const Text('Вход на новом устройстве',
          style: TextStyle(
              color: ShadeColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w600)),
      const SizedBox(height: 12),
      const Text(
        'На устройстве, где Shade уже открыт, перейдите в «Профиль → Устройства → Подключить другое устройство».',
        style: TextStyle(color: ShadeColors.textSecondary, height: 1.5),
      ),
      const SizedBox(height: 20),
      _primaryButton('Ввести код подключения', () async {
        final repo = _backend.pairingRepository;
        if (repo == null) return;
        final linked = await Navigator.of(context).push<bool>(MaterialPageRoute(
          builder: (_) => PairingNewDeviceScreen(repository: repo),
        ));
        if (!mounted || linked != true) return;
        if (widget.startWithGoogle) {
          Navigator.of(context).pop();
        } else {
          setState(() => _stage = _Stage.home);
          unawaited(_loadContacts());
        }
      }),
    ]);
  }

  Widget _buildRegister() {
    return ListView(padding: const EdgeInsets.all(24), children: [
      const Row(children: [
        ShadeLogo(size: 42),
        SizedBox(width: 12),
        Expanded(
          child: Text('Создать аккаунт Shade v2',
              style: TextStyle(
                  color: ShadeColors.textPrimary,
                  fontSize: 23,
                  fontWeight: FontWeight.w700)),
        ),
      ]),
      const SizedBox(height: 10),
      const Text('Придумайте никнейм и сохраните фразу восстановления.',
          style: TextStyle(color: ShadeColors.textSecondary, height: 1.5)),
      const SizedBox(height: 24),
      Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: ShadeColors.surfaceCard,
          border: Border.all(color: ShadeColors.greyBorder),
          borderRadius: BorderRadius.circular(24),
        ),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _field(_nickname, 'Никнейм', hint: 'например, mira_22'),
          const SizedBox(height: 6),
          const Text('3–32 символа: латиница, цифры и _',
              style: TextStyle(color: ShadeColors.textSecondary, fontSize: 12)),
          const SizedBox(height: 16),
          _field(_passphrase, 'Фраза для восстановления',
              obscure: !_showRecoveryPhrase,
              onChanged: (_) => setState(() {}),
              suffix: IconButton(
                tooltip:
                    _showRecoveryPhrase ? 'Скрыть фразу' : 'Показать фразу',
                onPressed: () =>
                    setState(() => _showRecoveryPhrase = !_showRecoveryPhrase),
                icon: Icon(_showRecoveryPhrase
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined),
              )),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: _passphrase.text.isEmpty
                ? TextButton.icon(
                    onPressed: _busy ? null : _generateRecoveryPhrase,
                    icon: const Icon(Icons.auto_awesome_outlined, size: 17),
                    label: const Text('Сгенерировать фразу'))
                : TextButton.icon(
                    onPressed: _busy ? null : _copyRecoveryPhrase,
                    icon: const Icon(Icons.copy_outlined, size: 17),
                    label: const Text('Скопировать фразу')),
          ),
          const Text(
              'Сохраните фразу в менеджере паролей. Если потеряете телефон, она и файл с последнего шага помогут вернуть доступ.',
              style: TextStyle(
                  color: ShadeColors.textSecondary, fontSize: 12, height: 1.5)),
          const SizedBox(height: 18),
          _primaryButton('Зарегистрироваться', _register),
        ]),
      ),
    ]);
  }

  Widget _buildEnroll() {
    return ListView(padding: const EdgeInsets.all(20), children: [
      const Text('Регистрация устройства',
          style: TextStyle(
              color: ShadeColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      Text(
          'Аккаунт @${_backend.account ?? ''} переводится в device-v2 явной подписью исходного RSA-ключа. Ключи, SQLCipher и v1-история не переписываются.',
          style: const TextStyle(
              color: ShadeColors.textSecondary, fontSize: 13, height: 1.5)),
      if (_backend.rotationPending) ...[
        const SizedBox(height: 12),
        Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: ShadeColors.surfaceCard,
                border: Border.all(color: ShadeColors.greyBorder),
                borderRadius: BorderRadius.circular(12)),
            child: const Text(
                'Требуется смена ключа: v1-ключ RSA-2048 не соответствует требованиям v2 (RSA-4096). '
                'Будет создан НОВЫЙ ключ RSA-4096; старый ключ останется на устройстве для расшифровки истории и сообщений от v1-собеседников. '
                'Это подтверждённая смена криптографической идентичности: собеседники смогут проверить аттестацию, подписанную старым ключом. '
                'Аккаунт, контакты и локальная история сохраняются.',
                style: TextStyle(
                    color: ShadeColors.textSecondary,
                    fontSize: 12.5,
                    height: 1.5))),
      ],
      const SizedBox(height: 16),
      const Text(
          'Придумайте отдельную recovery-фразу (24+ символа) и сохраните её вне устройства. Без неё восстановление членства после потери устройства невозможно.',
          style: TextStyle(
              color: ShadeColors.textMuted, fontSize: 12.5, height: 1.5)),
      const SizedBox(height: 16),
      _field(_passphrase, 'Recovery-фраза', obscure: true),
      const SizedBox(height: 16),
      _primaryButton(
          _backend.rotationPending
              ? 'Сменить ключ и зарегистрировать'
              : 'Зарегистрировать устройство',
          _enroll),
      const SizedBox(height: 12),
      TextButton(
        onPressed: _busy
            ? null
            : () => setState(() {
                  _error = null;
                  _passphrase.clear();
                  _stage = _Stage.connect;
                }),
        child: const Text('Создать новый аккаунт через Google'),
      ),
    ]);
  }

  Widget _buildRecovery() {
    final json = const JsonEncoder.withIndent('  ').convert(_recovery);
    return ListView(padding: const EdgeInsets.all(20), children: [
      const Text('Сохраните файл восстановления',
          style: TextStyle(
              color: ShadeColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      const Text(
          'Сохраните этот файл отдельно от фразы. Чтобы вернуть доступ на новом устройстве, понадобятся оба.',
          style: TextStyle(color: ShadeColors.textSecondary, height: 1.5)),
      const SizedBox(height: 20),
      _primaryButton('Сохранить файл', () async {
        try {
          final saved = await saveNativeRecoveryFile(json);
          if (mounted && saved == true) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Файл восстановления сохранён')),
            );
          }
        } on PlatformException {
          if (mounted)
            setState(() => _error =
                'Не удалось сохранить файл. Попробуйте снова или скопируйте его.');
        } on MissingPluginException {
          if (mounted)
            setState(
                () => _error = 'Здесь можно скопировать файл восстановления.');
        }
      }),
      const SizedBox(height: 8),
      TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: json));
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Файл восстановления скопирован')),
              );
            }
          },
          child: const Text('Скопировать содержимое')),
      const SizedBox(height: 16),
      OutlinedButton(
        onPressed: () {
          if (widget.startWithGoogle) {
            Navigator.of(context).pop();
          } else {
            setState(() => _stage = _Stage.home);
            unawaited(_loadContacts());
          }
        },
        child: const Text('Перейти к чатам'),
      ),
    ]);
  }

  Widget _buildHome() {
    final digest = _backend.ownGenesisDigest ?? '';
    final revision = _backend.catalogRevision;
    final lease = _backend.leaseExpiresAt;
    return ListView(padding: const EdgeInsets.all(20), children: [
      Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
              color: ShadeColors.surfaceCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: ShadeColors.greyBorder)),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('@${_backend.account ?? ''}',
                style: const TextStyle(
                    color: ShadeColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
                'Каталог rev ${revision ?? '—'} · lease до ${lease == null ? '—' : DateTime.fromMillisecondsSinceEpoch(lease).toLocal().toString().split('.').first}',
                style: const TextStyle(
                    color: ShadeColors.textSecondary, fontSize: 12)),
            const SizedBox(height: 10),
            const Text('Ваш genesis digest (передайте собеседнику лично):',
                style: TextStyle(color: ShadeColors.textMuted, fontSize: 12)),
            const SizedBox(height: 4),
            SelectableText(digest,
                style: const TextStyle(
                    color: ShadeColors.textSecondary,
                    fontFamily: 'monospace',
                    fontSize: 11,
                    height: 1.4)),
            const SizedBox(height: 8),
            Row(children: [
              TextButton(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: digest));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Genesis digest скопирован')));
                  },
                  child: const Text('Копировать')),
              TextButton(
                  onPressed:
                      _busy ? null : () => _run(() => _backend.renewLease()),
                  child: const Text('Продлить lease')),
            ]),
          ])),
      const SizedBox(height: 20),
      ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.bookmark_rounded,
              color: ShadeColors.textMuted, size: 22),
          title: const Text('Избранное',
              style: TextStyle(color: ShadeColors.textPrimary, fontSize: 14)),
          subtitle: const Text('Заметки себе — E2EE на все ваши устройства',
              style: TextStyle(color: ShadeColors.textSecondary, fontSize: 12)),
          trailing: const Icon(Icons.chevron_right_rounded,
              color: ShadeColors.textMuted),
          onTap: () => _openChat(_backend.account!)),
      const SizedBox(height: 8),
      Row(children: [
        const Expanded(
            child: Text('Контакты',
                style: TextStyle(
                    color: ShadeColors.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600))),
        TextButton.icon(
            onPressed: _busy ? null : _addContact,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Добавить')),
      ]),
      if (_contacts.isEmpty)
        const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text(
                'Пока нет подтверждённых контактов. Добавьте аккаунт и сверьте genesis digest по независимому каналу.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: ShadeColors.textMuted, fontSize: 12.5, height: 1.5)))
      else
        ..._contacts.map((c) => ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.verified_user_outlined,
                color: ShadeColors.textMuted, size: 22),
            title: Text('@${c['account']}',
                style: const TextStyle(
                    color: ShadeColors.textPrimary, fontSize: 14)),
            subtitle: Text(
                c['confirmed'] == true
                    ? '${_presence[c['account']] == true ? 'в сети' : 'не в сети'} · genesis сверен'
                    : 'не подтверждён',
                style: const TextStyle(
                    color: ShadeColors.textSecondary, fontSize: 12)),
            trailing: const Icon(Icons.chevron_right_rounded,
                color: ShadeColors.textMuted),
            onTap: c['confirmed'] == true
                ? () => _openChat(c['account'] as String)
                : null)),
    ]);
  }

  Widget _buildChat() {
    final replyTo = _replyTo;
    return Column(children: [
      if (_peerBlocked)
        Container(
            width: double.infinity,
            color: ShadeColors.surfaceCard,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: const Text(
                'Собеседник ещё не перешёл на Shade v2. Сообщения сохраняются в защищённой очереди и будут отправлены после его перехода.',
                style: TextStyle(
                    color: ShadeColors.textSecondary,
                    fontSize: 12,
                    height: 1.4))),
      Expanded(
          child: Stack(children: [
        Positioned.fill(
            child: _messages.isEmpty
                ? const Center(
                    child: Text('Сообщений пока нет',
                        style: TextStyle(
                            color: ShadeColors.textMuted, fontSize: 13)))
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final m = _messages[index];
                      final isMine = m['direction'] == 'out' ||
                          m['peer'] == _backend.account;
                      final devices = _delivery[m['ref']] ?? [];
                      final ack = devices
                          .where((d) => d['acknowledgedAt'] != null)
                          .length;
                      final readCount =
                          devices.where((d) => d['readAt'] != null).length;
                      final retracted = m['status'] == 'retracted';
                      final isImage = m['isImage'] == true;
                      final reply = m['reply'] as Map<String, dynamic>?;
                      return MessageBubble(
                          text: retracted
                              ? 'Сообщение отозвано отправителем'
                              : m['text'] as String,
                          timestamp: DateTime.fromMillisecondsSinceEpoch(
                              m['createdAt'] as int),
                          isMine: isMine,
                          isEncrypted: true,
                          isImage: isImage,
                          imageData:
                              isImage ? m['imageData'] as Uint8List? : null,
                          status: isMine
                              ? (retracted
                                  ? 'blocked'
                                  : devices.isNotEmpty &&
                                          readCount == devices.length
                                      ? 'read'
                                      : devices.isNotEmpty &&
                                              ack == devices.length
                                          ? 'delivered'
                                          : 'sent')
                              : 'read',
                          deliveryLabel: isMine && devices.isNotEmpty
                              ? (readCount == devices.length
                                  ? 'Прочитано'
                                  : 'Доставлено: $ack/${devices.length}')
                              : null,
                          replyText: reply?['text'] as String?,
                          replySender: reply?['from'] as String?,
                          onLongPress: () => _messageMenu(m));
                    })),
        if (!_atBottom && _newWhileAway > 0)
          Positioned(
              right: 16,
              bottom: 12,
              child: FloatingActionButton.extended(
                  backgroundColor: ShadeColors.surfaceElevated,
                  foregroundColor: ShadeColors.textPrimary,
                  onPressed: _jumpToLatest,
                  icon: const Icon(Icons.arrow_downward_rounded, size: 18),
                  label: Text('$_newWhileAway',
                      style: const TextStyle(fontSize: 13)))),
      ])),
      if (replyTo != null)
        Container(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            decoration: BoxDecoration(
                color: ShadeColors.surfaceCard,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: ShadeColors.greyBorder)),
            child: Row(children: [
              const Icon(Icons.reply_rounded,
                  size: 16, color: ShadeColors.textMuted),
              const SizedBox(width: 8),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(
                        replyTo['direction'] == 'out'
                            ? 'Вы'
                            : '@${replyTo['peer']}',
                        style: const TextStyle(
                            color: ShadeColors.textSecondary,
                            fontSize: 11,
                            fontWeight: FontWeight.w600)),
                    Text(replyTo['text'] as String,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: ShadeColors.textMuted, fontSize: 12)),
                  ])),
              IconButton(
                  icon: const Icon(Icons.close_rounded,
                      size: 16, color: ShadeColors.textMuted),
                  onPressed: () => setState(() => _replyTo = null)),
            ])),
      MessageInput(
          onSend: _send,
          onTyping: () {
            final peer = _peer;
            if (peer != null) _backend.sendTyping(peer);
          },
          onImageSelected: _sendMedia),
    ]);
  }

  Future<void> _sendMedia(List<int> bytes) async {
    final peer = _peer;
    if (peer == null || bytes.isEmpty) return;
    await _run(() async {
      await _backend.sendMedia(peer, bytes);
      await _loadMessages();
      _jumpToLatest();
    });
  }
}

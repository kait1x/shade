import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/device_v2/protocol.dart';
import '../../../core/theme/shade_theme.dart';
import '../../../core/widgets/shade_motion.dart';
import '../../auth/data/repositories/auth_notifier.dart';
import '../../chats/presentation/widgets/message_bubble.dart';
import '../../chats/presentation/widgets/message_input.dart';
import '../data/alpha_v2_backend.dart';

/// Экран Alpha v2: явная enrollment legacy-устройства, сверка genesis digest
/// контакта и E2EE-чат с Web-устройствами через изолированный alpha-процесс.
/// Production v1-чаты не изменяются.
class AlphaV2Screen extends ConsumerStatefulWidget {
  final AlphaV2Backend? backend;
  const AlphaV2Screen({super.key, this.backend});

  @override
  ConsumerState<AlphaV2Screen> createState() => _AlphaV2ScreenState();
}

enum _Stage { loading, connect, enroll, recovery, home, chat }

class _AlphaV2ScreenState extends ConsumerState<AlphaV2Screen> {
  late final AlphaV2Backend _backend;
  late final bool _ownedBackend;
  _Stage _stage = _Stage.loading;
  String? _error;
  bool _busy = false;
  final _origin = TextEditingController(text: 'https://');
  final _passphrase = TextEditingController();
  Map<String, dynamic>? _recovery;
  List<Map<String, dynamic>> _contacts = [];
  String? _peer;
  List<Map<String, dynamic>> _messages = [];
  final Map<String, List<Map<String, dynamic>>> _delivery = {};
  Timer? _chatTimer;
  Map<String, dynamic>? _replyTo;
  final ScrollController _scroll = ScrollController();
  bool _atBottom = true;
  int _newWhileAway = 0;

  @override
  void initState() {
    super.initState();
    _ownedBackend = widget.backend == null;
    _backend = widget.backend ??
        RealAlphaV2Backend(
            crypto: ref.read(cryptoServiceProvider),
            database: ref.read(databaseServiceProvider));
    _scroll.addListener(_onScroll);
    _init();
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
    _origin.dispose();
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
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
    if (mounted) setState(() => _contacts = contacts);
  }

  Future<void> _connect() async {
    final origin = _origin.text.trim();
    if (origin.isEmpty || origin == 'https://') {
      setState(() => _error = 'Укажите origin alpha-сервера (https).');
      return;
    }
    await _run(() async {
      final idToken = await _backend.requestGoogleIdToken();
      await _backend.connect(origin, idToken);
      if (!mounted) return;
      setState(() =>
          _stage = _backend.enrolled ? _Stage.home : _Stage.enroll);
      if (_stage == _Stage.home) await _loadContacts();
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
                style: TextStyle(color: ShadeColors.textPrimary, fontSize: 17)),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text(
                  'Введите genesis digest собеседника, полученный по независимому доверенному каналу. До сверки отправка и ACK заблокированы.',
                  style: TextStyle(
                      color: ShadeColors.textSecondary, fontSize: 13, height: 1.4)),
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
      await _loadMessages();
      if (!mounted) return;
      setState(() => _stage = _Stage.chat);
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
    final previousRefs = _messages.map((m) => m['ref']).toSet();
    final freshIncoming = messages
        .where((m) =>
            m['direction'] == 'in' && !previousRefs.contains(m['ref']))
        .length;
    setState(() {
      _messages = messages;
      if (!_atBottom) _newWhileAway += freshIncoming;
    });
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
            'from': replyTo['direction'] == 'out'
                ? _backend.account
                : peer,
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
                  subtitle: const Text(
                      'Другие устройства сохранят свою копию',
                      style: TextStyle(
                          color: ShadeColors.textSecondary, fontSize: 12)),
                  onTap: () => Navigator.pop(ctx, 'delete')),
            ])));
    if (!mounted || action == null) return;
    if (action == 'reply') {
      setState(() => _replyTo = message);
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
    setState(() {
      _stage = _Stage.home;
      _peer = null;
    });
    _loadContacts();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        backgroundColor: ShadeColors.black,
        appBar: AppBar(
            backgroundColor: ShadeColors.black,
            title: Text(
                _stage == _Stage.chat
                    ? (_peer == _backend.account ? 'Избранное' : _peer ?? '')
                    : 'Shade Alpha',
                style: const TextStyle(
                    color: ShadeColors.textPrimary, fontSize: 17)),
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
                border: Border.all(color: const Color(0xFFEF4444).withValues(alpha: .5))),
            child: Text(_error!,
                style: const TextStyle(
                    color: Color(0xFFEF4444), fontSize: 12.5, height: 1.4))),
      Expanded(child: switch (_stage) {
        _Stage.loading => const Center(child: ShadeLoadingIndicator()),
        _Stage.connect => _buildConnect(),
        _Stage.enroll => _buildEnroll(),
        _Stage.recovery => _buildRecovery(),
        _Stage.home => _buildHome(),
        _Stage.chat => _buildChat(),
      }),
    ]);
  }

  Widget _field(TextEditingController controller, String label,
      {bool obscure = false, String? hint}) {
    return TextField(
        controller: controller,
        obscureText: obscure,
        style: const TextStyle(color: ShadeColors.textPrimary, fontSize: 14),
        decoration: InputDecoration(
            labelText: label,
            hintText: hint,
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
      const Text('Android ↔ Web E2EE',
          style: TextStyle(
              color: ShadeColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      const Text(
          'Подключение к изолированному alpha-процессу device-v2. Исходные ключи этого устройства не заменяются; Google подтверждает только аккаунт.',
          style: TextStyle(
              color: ShadeColors.textSecondary, fontSize: 13, height: 1.5)),
      const SizedBox(height: 20),
      _field(_origin, 'Origin alpha-сервера', hint: 'https://alpha.example.com'),
      const SizedBox(height: 16),
      _primaryButton('Войти через Google', _connect),
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
      const SizedBox(height: 16),
      const Text(
          'Придумайте отдельную recovery-фразу (24+ символа) и сохраните её вне устройства. Без неё восстановление членства после потери устройства невозможно.',
          style: TextStyle(
              color: ShadeColors.textMuted, fontSize: 12.5, height: 1.5)),
      const SizedBox(height: 16),
      _field(_passphrase, 'Recovery-фраза', obscure: true),
      const SizedBox(height: 16),
      _primaryButton('Зарегистрировать устройство', _enroll),
    ]);
  }

  Widget _buildRecovery() {
    final json = const JsonEncoder.withIndent('  ').convert(_recovery);
    return ListView(padding: const EdgeInsets.all(20), children: [
      const Text('Сохраните recovery-пакет',
          style: TextStyle(
              color: ShadeColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      const Text(
          'Пакет содержит только зашифрованный независимый recovery-ключ. Храните его отдельно от recovery-фразы. Приватные ключи устройства в пакет не входят.',
          style: TextStyle(
              color: ShadeColors.textSecondary, fontSize: 13, height: 1.5)),
      const SizedBox(height: 16),
      Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: ShadeColors.surfaceCard,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: ShadeColors.greyBorder)),
          child: SelectableText(json,
              style: const TextStyle(
                  color: ShadeColors.textSecondary,
                  fontFamily: 'monospace',
                  fontSize: 11,
                  height: 1.4))),
      const SizedBox(height: 12),
      OutlinedButton.icon(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: json));
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('Recovery-пакет скопирован')));
          },
          icon: const Icon(Icons.copy_rounded, size: 18),
          label: const Text('Скопировать пакет')),
      const SizedBox(height: 16),
      _primaryButton('Я сохранил пакет и фразу', () {
        setState(() => _stage = _Stage.home);
        _loadContacts();
      }),
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
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
                  onPressed: _busy ? null : () => _run(() => _backend.renewLease()),
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
                c['confirmed'] == true ? 'genesis сверен' : 'не подтверждён',
                style: const TextStyle(
                    color: ShadeColors.textSecondary, fontSize: 12)),
            trailing: const Icon(Icons.chevron_right_rounded,
                color: ShadeColors.textMuted),
            onTap: c['confirmed'] == true ? () => _openChat(c['account'] as String) : null)),
    ]);
  }

  Widget _buildChat() {
    final replyTo = _replyTo;
    return Column(children: [
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
                      final reply = m['reply'] as Map<String, dynamic>?;
                      return MessageBubble(
                          text: m['text'] as String,
                          timestamp: DateTime.fromMillisecondsSinceEpoch(
                              m['createdAt'] as int),
                          isMine: isMine,
                          isEncrypted: true,
                          status: isMine
                              ? (devices.isNotEmpty && ack == devices.length
                                  ? 'delivered'
                                  : 'sent')
                              : 'read',
                          deliveryLabel: isMine && devices.isNotEmpty
                              ? 'Доставлено: $ack/${devices.length}'
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
      MessageInput(onSend: _send),
    ]);
  }
}
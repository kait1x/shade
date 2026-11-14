import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shade/core/services/connection_service.dart';
import 'package:shade/core/widgets/shade_ui.dart';
import 'package:shade/main.dart';

// Brighter secondary tones for better contrast on the dark background.
const _kSubtle = Color(0xFFB9B9C0);
const _kIcon = Color(0xFFD2D2D8);
const _kAmberText = Color(0xFFFFB92E);

/// Telegram-style profile: large collapsible header, quick actions,
/// info section and a visual encryption-key fingerprint.
class ProfileScreen extends ConsumerStatefulWidget {
  final String username;
  final String? viewerUsername;
  final String? displayName;
  final String? avatarUrl;
  final String? email;
  final String? publicKey;
  final bool isSelf;
  final VoidCallback? onSignOut;

  const ProfileScreen({
    super.key,
    required this.username,
    this.viewerUsername,
    this.displayName,
    this.avatarUrl,
    this.email,
    this.publicKey,
    this.isSelf = false,
    this.onSignOut,
  });

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final _scroll = ScrollController();
  bool _collapsed = false;
  UserStatus? _status;
  String _note = '';
  bool _verified = false;
  static const _amber = Color(0xFFF5A300);

  double get _headerHeight =>
      250 + (MediaQuery.textScalerOf(context).scale(27) - 27) * 2;

  String get _title => widget.displayName?.trim().isNotEmpty == true
      ? widget.displayName!.trim()
      : widget.username;

  String get _noteKey => 'contact_note_${widget.username}';

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      final collapsed = _scroll.hasClients &&
          _scroll.offset > _headerHeight - kToolbarHeight - 40;
      if (collapsed != _collapsed) setState(() => _collapsed = collapsed);
    });
    if (!widget.isSelf) {
      _loadStatus();
      _loadNote();
      _loadVerification();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  String? get _verificationKey => widget.viewerUsername == null
      ? null
      : 'verified_key:${widget.viewerUsername}:${widget.username}';

  String? get _fingerprintHex =>
      _fingerprint?.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  Future<void> _loadVerification() async {
    final key = _verificationKey, fingerprint = _fingerprintHex;
    if (key == null || fingerprint == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (mounted && key == _verificationKey && fingerprint == _fingerprintHex) {
      setState(() => _verified = prefs.getString(key) == fingerprint);
    }
  }

  Future<bool> _confirmKey(String key, String fingerprint) async {
    if (key != _verificationKey || fingerprint != _fingerprintHex) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = await prefs.setString(key, fingerprint);
      if (!mounted ||
          key != _verificationKey ||
          fingerprint != _fingerprintHex ||
          !saved) {
        return false;
      }
      setState(() => _verified = true);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void didUpdateWidget(covariant ProfileScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.publicKey != widget.publicKey ||
        oldWidget.username != widget.username ||
        oldWidget.viewerUsername != widget.viewerUsername) {
      _verified = false;
      _loadVerification();
    }
  }

  Future<void> _loadStatus() async {
    final status = await ref
        .read(connectionServiceProvider)
        .getUserStatus(widget.username);
    if (mounted) setState(() => _status = status);
  }

  Future<void> _loadNote() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) setState(() => _note = prefs.getString(_noteKey) ?? '');
  }

  Future<void> _editNote() async {
    final controller = TextEditingController(text: _note);
    final result = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('Заметка о контакте'),
              content: TextField(
                  controller: controller,
                  autofocus: true,
                  maxLines: 4,
                  maxLength: 200,
                  decoration: const InputDecoration(
                      hintText: 'Видна только вам и хранится на устройстве')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Отмена')),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, controller.text.trim()),
                    child: const Text('Сохранить')),
              ],
            ));
    controller.dispose();
    if (result == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (result.isEmpty) {
      await prefs.remove(_noteKey);
    } else {
      await prefs.setString(_noteKey, result);
    }
    if (mounted) setState(() => _note = result);
  }

  void _copy(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          content: Text('$label скопировано'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2)));
  }

  List<int>? get _fingerprint {
    final key = widget.publicKey;
    if (key == null || key.isEmpty) return null;
    // Normalize PEM whitespace so the same public key has the same fingerprint.
    final normalized = key
        .replaceAll(RegExp(r'-----[^-]+-----'), '')
        .replaceAll(RegExp(r'\s'), '');
    try {
      return sha256.convert(base64Decode(normalized)).bytes;
    } catch (_) {
      return sha256.convert(utf8.encode(key.trim())).bytes;
    }
  }

  void _showKey() {
    final bytes = _fingerprint;
    if (bytes == null) return;
    final fingerprint = _fingerprintHex!;
    final ownerKey = _verificationKey;
    var confirming = false;
    showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        backgroundColor: const Color(0xFF141414),
        builder: (ctx) => SafeArea(
            child: SingleChildScrollView(
                child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(widget.isSelf ? 'Мой ключ' : 'Сверка ключа',
                          style: const TextStyle(
                              fontSize: 20, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 5),
                      Text(
                          '@${widget.username} · ${widget.isSelf ? "ваш ключ" : (_verified ? "сверен" : "не сверен")}',
                          style: const TextStyle(
                              fontSize: 12, color: _kSubtle)),
                      const SizedBox(height: 20),
                      _KeyIdenticon(bytes: bytes, size: 176),
                      const SizedBox(height: 18),
                      Container(
                          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
                          decoration: BoxDecoration(
                              color: ShadeColors.black,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                  color: ShadeColors.greyBorder
                                      .withValues(alpha: .6))),
                          child: Row(children: [
                            Expanded(
                                child: _FingerprintText(
                                    bytes: bytes, fontSize: 12, groups: 16)),
                            IconButton(
                                tooltip: 'Копировать полный код',
                                icon: const Icon(Icons.copy_outlined, size: 19),
                                onPressed: () => _copy(
                                    fingerprint.toUpperCase(), 'Код ключа'))
                          ])),
                      const SizedBox(height: 16),
                      Text(
                          widget.isSelf
                              ? 'Покажите рисунок и полный код собеседнику для сравнения ключа.'
                              : 'Сравните рисунок и полный код с профилем на телефоне @${widget.username}. Подтверждение относится только к этому ключу.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: _kSubtle,
                              fontSize: 12,
                              height: 1.5)),
                      if (!widget.isSelf && _verificationKey != null) ...[
                        const SizedBox(height: 18),
                        SizedBox(
                            width: double.infinity,
                            height: 52,
                            child: FilledButton.icon(
                                style: FilledButton.styleFrom(
                                    backgroundColor: _amber,
                                    foregroundColor: Colors.black,
                                    elevation: 0,
                                    shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(14)),
                                    textStyle: Theme.of(ctx)
                                        .textTheme
                                        .labelLarge
                                        ?.copyWith(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: .2)),
                                onPressed: () async {
                                  if (confirming || ownerKey == null) return;
                                  confirming = true;
                                  final confirmed =
                                      await _confirmKey(ownerKey, fingerprint);
                                  if (ctx.mounted) Navigator.pop(ctx);
                                  if (!confirmed && mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                            content: Text(
                                                'Не удалось подтвердить ключ. Откройте сверку заново.')));
                                  }
                                },
                                icon: const Icon(Icons.verified_user_rounded, size: 20),
                                label: Text(_verified
                                    ? 'Подтверждено'
                                    : 'Ключ совпадает'))),
                      ],
                    ])))));
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = widget.isSelf
        ? 'это вы'
        : (_status?.displayText ?? 'загрузка статуса…');
    final online = _status?.online == true;
    return Scaffold(
      backgroundColor: ShadeColors.black,
      body: CustomScrollView(controller: _scroll, slivers: [
        SliverAppBar(
          pinned: true,
          leading: IconButton(
              tooltip: 'Назад',
              icon: const Icon(Icons.arrow_back_rounded, size: 22),
              onPressed: () => Navigator.maybePop(context)),
          stretch: true,
          expandedHeight: _headerHeight,
          backgroundColor: ShadeColors.surfaceDark,
          surfaceTintColor: Colors.transparent,
          title: AnimatedOpacity(
              opacity: _collapsed ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: Row(children: [
                ShadeAvatar(
                    name: widget.username,
                    imageUrl: widget.avatarUrl,
                    size: 34),
                const SizedBox(width: 10),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(_title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                      Text(subtitle,
                          style: const TextStyle(
                              fontSize: 12, color: ShadeColors.textSecondary)),
                    ])),
              ])),
          flexibleSpace: FlexibleSpaceBar(
            stretchModes: const [
              StretchMode.zoomBackground,
              StretchMode.fadeTitle
            ],
            background: _ProfileHeader(
                name: widget.username,
                title: _title,
                subtitle: subtitle,
                online: online,
                avatarUrl: widget.avatarUrl),
          ),
        ),
        SliverToBoxAdapter(
            child: Center(
                child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: Padding(
                        padding: EdgeInsets.fromLTRB(
                            16, 16, 16, 40 + MediaQuery.viewPaddingOf(context).bottom),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _buildActions(),
                              const SizedBox(height: 16),
                              _buildInfo(),
                              if (_fingerprint != null) ...[
                                const SizedBox(height: 16),
                                _buildKeySection(),
                              ],
                              if (widget.isSelf &&
                                  widget.onSignOut != null) ...[
                                const SizedBox(height: 16),
                                _Section(children: [
                                  _Tile(
                                      icon: Icons.logout_rounded,
                                      title: 'Выйти из профиля',
                                      danger: true,
                                      onTap: () {
                                        Navigator.pop(context);
                                        widget.onSignOut!();
                                      }),
                                ]),
                              ],
                              const SizedBox(height: 20),
                              const Text(
                                  'Сообщения защищены сквозным шифрованием.\nИстория и ключи хранятся только на этом устройстве.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      color: _kSubtle,
                                      fontSize: 12.5,
                                      height: 1.5)),
                            ]))))),
      ]),
    );
  }

  Widget _buildActions() {
    final actions = <Widget>[
      if (!widget.isSelf)
        _ActionButton(
            icon: Icons.chat_bubble_outline_rounded,
            label: 'Написать',
            onTap: () => Navigator.pop(context)),
      _ActionButton(
          icon: Icons.copy_outlined,
          label: 'Копировать',
          onTap: () => _copy('@${widget.username}', 'Имя пользователя')),
      if (_fingerprint != null)
        _ActionButton(
            icon: widget.isSelf
                ? Icons.qr_code_2_rounded
                : Icons.verified_user_outlined,
            accent: true,
            label: widget.isSelf ? 'Мой ключ' : 'Ключ',
            onTap: _showKey),
      if (!widget.isSelf)
        _ActionButton(
            icon: Icons.edit_note_rounded, label: 'Заметка', onTap: _editNote),
    ];
    return Row(children: [
      for (var i = 0; i < actions.length; i++) ...[
        if (i > 0) const SizedBox(width: 10),
        Expanded(child: actions[i]),
      ]
    ]);
  }

  Widget _buildInfo() => _Section(title: 'Информация', children: [
        _Tile(
            icon: Icons.alternate_email_rounded,
            title: '@${widget.username}',
            subtitle: 'Имя пользователя',
            onTap: () => _copy('@${widget.username}', 'Имя пользователя')),
        if (widget.isSelf && widget.email != null)
          _Tile(
              icon: Icons.mail_outline_rounded,
              title: widget.email!,
              subtitle: 'Google-аккаунт',
              onTap: () => _copy(widget.email!, 'Почта')),
        if (!widget.isSelf)
          _Tile(
              icon: Icons.sticky_note_2_outlined,
              title: _note.isEmpty ? 'Добавить заметку' : _note,
              subtitle: 'Заметка · видна только вам',
              muted: _note.isEmpty,
              onTap: _editNote),
        if (widget.isSelf)
          const _Tile(
              icon: Icons.phone_android_rounded,
              title: 'Это устройство',
              subtitle: 'Приватный ключ не покидает телефон'),
      ]);

  Widget _buildKeySection() {
    final bytes = _fingerprint!;
    return _Section(title: 'Шифрование', children: [
      InkWell(
          onTap: _showKey,
          child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                _KeyIdenticon(bytes: bytes, size: 52),
                const SizedBox(width: 12),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Row(children: [
                        const Expanded(
                            child: Text('Ключ шифрования',
                                style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600))),
                        Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                                color: widget.isSelf
                                    ? _amber.withValues(alpha: .2)
                                    : Colors.white.withValues(alpha: .12),
                                borderRadius: BorderRadius.circular(20)),
                            child: Text(
                                widget.isSelf
                                    ? 'Ваш'
                                    : (_verified ? 'Сверен' : 'Не сверен'),
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: widget.isSelf
                                        ? _kAmberText
                                        : ShadeColors.textPrimary))),
                      ]),
                      const SizedBox(height: 6),
                      _FingerprintText(bytes: bytes, fontSize: 12, groups: 4),
                      const SizedBox(height: 4),
                      Text(
                          widget.isSelf
                              ? 'Нажмите, чтобы показать код'
                              : 'Нажмите, чтобы сверить',
                          style: const TextStyle(
                              fontSize: 12, color: _kSubtle)),
                    ])),
                const Icon(Icons.chevron_right_rounded,
                    color: _kSubtle),
              ]))),
    ]);
  }
}

class _ProfileHeader extends StatelessWidget {
  final String name;
  final String title;
  final String subtitle;
  final bool online;
  final String? avatarUrl;
  const _ProfileHeader(
      {required this.name,
      required this.title,
      required this.subtitle,
      required this.online,
      this.avatarUrl});

  @override
  Widget build(BuildContext context) => DecoratedBox(
      decoration: const BoxDecoration(
          gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
            Color(0xFF181818),
            Color(0xFF101010),
            ShadeColors.black
          ])),
      child: SafeArea(
          bottom: false,
          child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 32, 24, 16),
              child:
                  Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: online
                                ? ShadeColors.violetLight
                                : Colors.white.withValues(alpha: .12),
                            width: 2),
                        boxShadow: [
                          BoxShadow(
                              color: Colors.black.withValues(alpha: .5),
                              blurRadius: 30,
                              offset: const Offset(0, 12))
                        ]),
                    child: ShadeAvatar(
                        name: name, imageUrl: avatarUrl, size: 108)),
                const SizedBox(height: 12),
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 27,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -.6)),
                const SizedBox(height: 6),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  if (online) ...[
                    Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: ShadeColors.violetLight)),
                    const SizedBox(width: 6),
                  ],
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 14,
                          color: online
                              ? ShadeColors.violetLight
                              : ShadeColors.textSecondary)),
                ]),
              ]))));
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool accent;
  final VoidCallback onTap;
  const _ActionButton(
      {required this.icon,
      required this.label,
      required this.onTap,
      this.accent = false});

  @override
  Widget build(BuildContext context) => Material(
      color: const Color(0xFF141414),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side:
              BorderSide(color: ShadeColors.greyBorder.withValues(alpha: .55))),
      child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon,
                    size: 20,
                    color: accent
                        ? const Color(0xFFF5A300)
                        : ShadeColors.violetLight),
                const SizedBox(height: 6),
                Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600)),
              ]))));
}

class _Section extends StatelessWidget {
  final String? title;
  final List<Widget> children;
  const _Section({this.title, required this.children});

  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (title != null)
          Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Text(title!,
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: _kSubtle))),
        ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Material(
                color: const Color(0xFF141414),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                    side: BorderSide(
                        color: ShadeColors.greyBorder.withValues(alpha: .55))),
                child: Column(children: [
                  for (var i = 0; i < children.length; i++) ...[
                    if (i > 0)
                      const Divider(
                          height: 1, indent: 56, color: ShadeColors.greyBorder),
                    children[i],
                  ]
                ]))),
      ]);
}

class _Tile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final bool danger;
  final bool muted;
  const _Tile(
      {required this.icon,
      required this.title,
      this.subtitle,
      this.onTap,
      this.danger = false,
      this.muted = false});

  @override
  Widget build(BuildContext context) {
    final color = danger
        ? const Color(0xFFEF4444)
        : (muted ? _kSubtle : ShadeColors.textPrimary);
    return ListTile(
        onTap: onTap,
        dense: true,
        minTileHeight: subtitle == null ? 48 : 64,
        minLeadingWidth: 20,
        horizontalTitleGap: 14,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        leading: Icon(icon,
            color: danger ? color : _kIcon, size: 22),
        title: Text(title,
            style: TextStyle(
                color: color, fontSize: 14, fontWeight: FontWeight.w500)),
        subtitle: subtitle == null
            ? null
            : Text(subtitle!,
                style: const TextStyle(
                    color: _kSubtle, fontSize: 12)));
  }
}

/// 8x8 grid derived from SHA-256 of the public key (like Telegram secret chats).
class _KeyIdenticon extends StatelessWidget {
  final List<int> bytes;
  final double size;
  const _KeyIdenticon({required this.bytes, required this.size});

  @override
  Widget build(BuildContext context) => ClipRRect(
      borderRadius: BorderRadius.circular(size * .12),
      child: CustomPaint(
          size: Size.square(size), painter: _IdenticonPainter(bytes)));
}

class _IdenticonPainter extends CustomPainter {
  final List<int> bytes;
  _IdenticonPainter(this.bytes);

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
      final byte = bytes[(i ~/ 2) % bytes.length];
      final nibble = i.isEven ? byte >> 4 : byte & 0x0F;
      paint.color = _colors[nibble & 0x03];
      canvas.drawRect(
          Rect.fromLTWH((i % 8) * cell, (i ~/ 8) * cell, cell + .5, cell + .5),
          paint);
    }
  }

  @override
  bool shouldRepaint(covariant _IdenticonPainter oldDelegate) =>
      oldDelegate.bytes != bytes;
}

class _FingerprintText extends StatelessWidget {
  final List<int> bytes;
  final double fontSize;
  final int groups;
  const _FingerprintText(
      {required this.bytes, required this.fontSize, this.groups = 8});

  @override
  Widget build(BuildContext context) {
    final hex = bytes
        .take(groups * 2)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    final parts = <String>[
      for (var i = 0; i < hex.length; i += 4) hex.substring(i, i + 4)
    ];
    final lines = <String>[
      for (var i = 0; i < parts.length; i += 4) parts.skip(i).take(4).join(' ')
    ];
    return Text(lines.join('\n'),
        textAlign: groups > 4 ? TextAlign.center : TextAlign.start,
        style: TextStyle(
            fontFamily: 'Roboto',
            fontSize: fontSize,
            letterSpacing: 1.2,
            height: 1.5,
            color: ShadeColors.textSecondary));
  }
}

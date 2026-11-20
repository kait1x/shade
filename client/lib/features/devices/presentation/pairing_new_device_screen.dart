import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/services/device_v2/protocol.dart';
import '../../../core/services/device_v2/repository.dart';
import '../../../core/theme/shade_theme.dart';
import 'pairing_common.dart';

/// Экран НОВОГО устройства: ввод одноразового кода с доверенного экрана,
/// подписанный offer с эхом challenge (свежий, ≤5 минут) для копирования,
/// ожидание подтверждения и завершение подключения против каталога сервера.
///
/// Самодостаточен: принимает V2ChatRepository.pairing(...) до enrollment.
/// Ключи устройства создаются долговечно до offer; прерванная попытка
/// возобновляется тем же ключом. Точка входа не переключается (D2).
class PairingNewDeviceScreen extends StatefulWidget {
  final V2ChatRepository repository;
  const PairingNewDeviceScreen({super.key, required this.repository});

  @override
  State<PairingNewDeviceScreen> createState() => _PairingNewDeviceScreenState();
}

enum _NewStage { code, offer, done }

class _PairingNewDeviceScreenState extends State<PairingNewDeviceScreen> {
  _NewStage _stage = _NewStage.code;
  String? _error;
  bool _busy = false;
  String? _offerText;
  String? _challengeEcho;
  int? _offerExpiresAt;
  int? _revision;
  Timer? _ticker;
  int _now = DateTime.now().millisecondsSinceEpoch;
  final _codeInput = TextEditingController();
  final _confirmationInput = TextEditingController();

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now().millisecondsSinceEpoch);
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _codeInput.dispose();
    _confirmationInput.dispose();
    super.dispose();
  }

  bool get _offerExpired =>
      _offerExpiresAt != null && _now >= _offerExpiresAt!;

  Future<void> _createOffer() async {
    final code = _codeInput.text.trim();
    if (code.isEmpty) {
      setState(() =>
          _error = 'Введите код подключения с доверенного устройства.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result =
          await widget.repository.startPairing(challengeCode: code);
      if (!mounted) return;
      setState(() {
        _stage = _NewStage.offer;
        _offerText = result['offerText'] as String;
        _challengeEcho = result['challengeEcho'] as String;
        _offerExpiresAt = result['expiresAt'] as int;
        _confirmationInput.clear();
      });
    } catch (e) {
      if (mounted) setState(() => _error = pairingErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _complete() async {
    final text = _confirmationInput.text.trim();
    if (text.isEmpty) {
      setState(() => _error =
          'Вставьте подтверждение с доверенного устройства.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.repository.completePairing(text);
      if (!mounted) return;
      // Долговечная фиксация origin/account/cookie: restore() после перезапуска
      // поднимает вторичное устройство без v1-профиля (как recovery-экран).
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('alpha_v2_origin', widget.repository.transport.origin);
      await prefs.setString(
          'alpha_v2_account', result['account'] as String? ?? widget.repository.account);
      const secure = FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true));
      final cookie = widget.repository.transport.sessionCookie;
      if (cookie != null) await secure.write(key: 'alpha_v2_cookie', value: cookie);
      if (!mounted) return;
      setState(() {
        _stage = _NewStage.done;
        _revision = result['revision'] as int?;
      });
    } catch (e) {
      if (mounted) setState(() => _error = pairingErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? get _genesisFingerprint {
    final genesis =
        widget.repository.accountSnapshot?['genesis'] as Map<String, dynamic>?;
    if (genesis == null) return null;
    final firstDevice = genesis['firstDevice'] as Map<String, dynamic>;
    return spkiFingerprint(firstDevice['signingKey'] as String);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        backgroundColor: ShadeColors.black,
        appBar: AppBar(
            backgroundColor: ShadeColors.black,
            title: const Text('Новое устройство',
                style: TextStyle(color: ShadeColors.textPrimary, fontSize: 17))),
        body: SafeArea(
            child: Center(
                child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: ListView(padding: const EdgeInsets.all(20), children: [
                      if (_error != null) PairingErrorBanner(_error!),
                      switch (_stage) {
                        _NewStage.code => _buildCode(),
                        _NewStage.offer => _buildOffer(),
                        _NewStage.done => _buildDone(),
                      }
                    ])))));
  }

  Widget _buildCode() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const PairingHeading(
          title: 'Подключение к аккаунту',
          description:
              'Введите одноразовый код с экрана доверенного устройства '
              '(24 символа, действует 5 минут). Ключи этого устройства '
              'создаются локально и никуда не отправляются; запрос '
              'подключения будет подписан и привязан к коду.'),
      TextField(
          controller: _codeInput,
          enabled: !_busy,
          style: const TextStyle(
              color: ShadeColors.textPrimary,
              fontFamily: 'monospace',
              fontSize: 15),
          decoration: pairingInputDecoration('Код подключения',
              hint: 'XXXXXX-XXXXXX-XXXXXX-XXXXXX')),
      const SizedBox(height: 16),
      PairingPrimaryButton(
          label: 'Создать запрос', busy: _busy, onPressed: _createOffer),
    ]);
  }

  Widget _buildOffer() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const PairingHeading(
          title: 'Запрос подключения',
          description:
              'Скопируйте запрос на доверенное устройство. Сверьте эхо кода '
              'с кодом на его экране: несовпадение означает, что запрос '
              'подменён. Доверенное устройство вернёт подтверждение — '
              'вставьте его ниже.'),
      if (_offerText != null)
        PairingCodeCard(
            label: 'Запрос подключения (скопируйте на доверенное устройство)',
            value: _offerText!,
            fontSize: 11.5),
      if (_challengeEcho != null)
        PairingCodeCard(
            label: 'Эхо кода подключения (сверьте с доверенным экраном)',
            value: _challengeEcho!,
            fontSize: 16),
      Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Text(
              _offerExpired
                  ? 'Срок запроса истёк. Создайте запрос заново с новым кодом подключения.'
                  : 'Запрос действует ещё ${pairingRemaining(_offerExpiresAt!, _now)}',
              semanticsLabel: 'Оставшееся время действия запроса',
              style: TextStyle(
                  color: _offerExpired
                      ? const Color(0xFFEF4444)
                      : ShadeColors.textMuted,
                  fontSize: 12.5))),
      if (_offerExpired)
        Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: PairingPrimaryButton(
                label: 'Создать новый запрос',
                onPressed: () => setState(() {
                      _stage = _NewStage.code;
                      _error = null;
                      _offerText = null;
                      _offerExpiresAt = null;
                    }))),
      TextField(
          controller: _confirmationInput,
          enabled: !_offerExpired && !_busy,
          maxLines: 4,
          minLines: 2,
          style: const TextStyle(
              color: ShadeColors.textPrimary,
              fontFamily: 'monospace',
              fontSize: 12.5),
          decoration: pairingInputDecoration('Подтверждение',
              hint: 'shade-pair-confirm-v1:…')),
      const SizedBox(height: 16),
      PairingPrimaryButton(
          label: 'Завершить подключение',
          busy: _busy,
          onPressed: _offerExpired ? null : _complete),
    ]);
  }

  Widget _buildDone() {
    final fingerprint = _genesisFingerprint;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      PairingHeading(
          title: 'Устройство подключено',
          description: _revision != null
              ? 'Каталог сервера проверен против закреплённого genesis '
                  '(ревизия $_revision). Ключи устройства и состояние '
                  'аккаунта сохранены на этом устройстве.'
              : 'Подключение уже было завершено ранее. Ключи устройства и '
                  'состояние аккаунта сохранены на этом устройстве.'),
      if (fingerprint != null)
        PairingCodeCard(
            label: 'Отпечаток genesis (сверьте с доверенным устройством)',
            value: fingerprint),
    ]);
  }
}
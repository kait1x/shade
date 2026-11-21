import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/services/device_v2/protocol.dart';
import '../../../core/services/device_v2/repository.dart';
import '../../../core/theme/shade_theme.dart';
import '../../../core/widgets/shade_motion.dart';
import 'pairing_common.dart';

/// Экран ДОВЕРЕННОГО устройства: одноразовый код подключения (5 минут),
/// проверка вставленного offer (подпись/аккаунт/challenge), явное подтверждение
/// с отпечатком genesis и выдача confirmation для нового устройства.
///
/// Самодостаточен: принимает уже загруженный (enrolled) V2ChatRepository.
/// Точка входа не переключается — проводка в навигацию остаётся за владельцем.
class PairingApproveScreen extends StatefulWidget {
  final V2ChatRepository repository;
  const PairingApproveScreen({super.key, required this.repository});

  @override
  State<PairingApproveScreen> createState() => _PairingApproveScreenState();
}

enum _ApproveStage { challenge, review, done }

class _PairingApproveScreenState extends State<PairingApproveScreen> {
  _ApproveStage _stage = _ApproveStage.challenge;
  String? _error;
  bool _busy = false;
  String? _code;
  int? _challengeExpiresAt;
  int? _offerExpiresAt;
  String? _deviceId;
  String? _offerText;
  String? _confirmationText;
  Timer? _ticker;
  int _now = DateTime.now().millisecondsSinceEpoch;
  final _offerInput = TextEditingController();

  @override
  void initState() {
    super.initState();
    _newChallenge();
    // Тик раз в секунду: countdown кода/запроса и переход в expired-состояние.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now().millisecondsSinceEpoch);
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _offerInput.dispose();
    super.dispose();
  }

  void _newChallenge() {
    final challenge = widget.repository.pairingChallenge();
    setState(() {
      _code = challenge['code'] as String;
      _challengeExpiresAt = challenge['expiresAt'] as int;
      _stage = _ApproveStage.challenge;
      _error = null;
      _deviceId = null;
      _offerText = null;
      _offerExpiresAt = null;
      _confirmationText = null;
      _offerInput.clear();
    });
  }

  bool get _challengeExpired =>
      _challengeExpiresAt != null && _now >= _challengeExpiresAt!;

  Future<void> _review() async {
    final text = _offerInput.text.trim();
    if (text.isEmpty) {
      setState(() =>
          _error = 'Вставьте запрос подключения с нового устройства.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final review = await widget.repository.reviewPairingOffer(text);
      if (!mounted) return;
      setState(() {
        _stage = _ApproveStage.review;
        _deviceId = review['deviceId'] as String;
        _offerExpiresAt = review['expiresAt'] as int;
        _offerText = text;
      });
    } catch (e) {
      if (mounted) setState(() => _error = pairingErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _approve() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final confirmation =
          await widget.repository.approvePairing(_offerText!);
      if (!mounted) return;
      setState(() {
        _stage = _ApproveStage.done;
        _confirmationText = confirmation;
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
            title: const Text('Подключение устройства',
                style: TextStyle(color: ShadeColors.textPrimary, fontSize: 17))),
        body: SafeArea(
            child: Center(
                child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: _busy && _stage == _ApproveStage.challenge && _code == null
                        ? const Center(child: ShadeLoadingIndicator())
                        : ListView(padding: const EdgeInsets.all(20), children: [
                            if (_error != null) PairingErrorBanner(_error!),
                            switch (_stage) {
                              _ApproveStage.challenge => _buildChallenge(),
                              _ApproveStage.review => _buildReview(),
                              _ApproveStage.done => _buildDone(),
                            }
                          ])))));
  }

  Widget _buildChallenge() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const PairingHeading(
          title: 'Код подключения',
          description:
              'Покажите этот код новому устройству. Запрос подключения обязан '
              'эхом подтвердить код — запрос, созданный без этого экрана, '
              'будет отклонён. Код одноразовый и действует 5 минут.'),
      if (_code != null)
        PairingCodeCard(label: 'Код подключения', value: _code!, fontSize: 18),
      if (!_challengeExpired)
        Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: Text('Код действует ещё ${pairingRemaining(_challengeExpiresAt!, _now)}',
                semanticsLabel: 'Оставшееся время действия кода подключения',
                style: const TextStyle(
                    color: ShadeColors.textMuted, fontSize: 12.5)))
      else ...[
        const PairingErrorBanner(
            'Код подключения истёк. Сгенерируйте новый код и создайте запрос '
            'на новом устройстве заново.'),
        Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: PairingPrimaryButton(
                label: 'Сгенерировать новый код', onPressed: _newChallenge)),
      ],
      TextField(
          controller: _offerInput,
          enabled: !_challengeExpired && !_busy,
          maxLines: 4,
          minLines: 2,
          style: const TextStyle(
              color: ShadeColors.textPrimary,
              fontFamily: 'monospace',
              fontSize: 12.5),
          decoration: pairingInputDecoration('Запрос подключения',
              hint: 'shade-pair-v2:…')),
      const SizedBox(height: 16),
      PairingPrimaryButton(
          label: 'Проверить запрос',
          busy: _busy,
          onPressed: _challengeExpired ? null : _review),
    ]);
  }

  Widget _buildReview() {
    final fingerprint = _genesisFingerprint;
    final offerExpired = _offerExpiresAt != null && _now >= _offerExpiresAt!;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const PairingHeading(
          title: 'Сверьте перед подтверждением',
          description:
              'Подпись запроса действительна, аккаунт и код подключения '
              'совпадают. Подтверждение добавит устройство в ростер аккаунта '
              'и откроет ему доступ к переписке. Убедитесь, что запрос создан '
              'на вашем новом устройстве.'),
      if (_deviceId != null)
        PairingCodeCard(label: 'Идентификатор устройства', value: _deviceId!),
      if (fingerprint != null)
        PairingCodeCard(label: 'Отпечаток genesis аккаунта', value: fingerprint),
      Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Text(
              offerExpired
                  ? 'Срок запроса истёк. Создайте запрос на новом устройстве заново.'
                  : 'Запрос действует ещё ${pairingRemaining(_offerExpiresAt!, _now)}',
              semanticsLabel: 'Оставшееся время действия запроса',
              style: TextStyle(
                  color: offerExpired
                      ? const Color(0xFFEF4444)
                      : ShadeColors.textMuted,
                  fontSize: 12.5))),
      PairingPrimaryButton(
          label: 'Подключить устройство',
          busy: _busy,
          onPressed: offerExpired ? null : _approve),
      const SizedBox(height: 12),
      SizedBox(
          width: double.infinity,
          height: 44,
          child: TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _stage = _ApproveStage.challenge;
                        _error = null;
                      }),
              child: const Text('Отмена',
                  style: TextStyle(
                      color: ShadeColors.textSecondary, fontSize: 14)))),
    ]);
  }

  Widget _buildDone() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const PairingHeading(
          title: 'Устройство подключено',
          description:
              'Передайте подтверждение на новое устройство: оно завершит '
              'подключение и само проверит полный каталог сервера против '
              'закреплённого genesis. Код подключения использован — для '
              'следующего устройства сгенерируйте новый.'),
      if (_confirmationText != null)
        PairingCodeCard(
            label: 'Подтверждение для нового устройства',
            value: _confirmationText!,
            fontSize: 11.5),
      PairingPrimaryButton(
          label: 'Подключить ещё устройство', onPressed: _newChallenge),
    ]);
  }
}
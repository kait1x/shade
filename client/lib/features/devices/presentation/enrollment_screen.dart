/// Продакшн-экран перехода legacy v1 → device-v2 (native).
///
/// Мастер из четырёх шагов: challenge (legacy-сессия исходным ключом) →
/// enrollment (enrollLegacy тем же RSA) → импорт локальной истории (опционален,
/// но предложен) → готово. Честные объяснения что переносится и что нет,
/// русские ошибки, идемпотентное состояние «уже enrolled»: повторное открытие
/// не пересоздаёт ключи и не дублирует каталог.
///
/// Навигационная точка экспортируется отсюда ([enrollmentRoute]); проводку в
/// entry (v2-connect/роутер) выполняет lead отдельно. Экран зависит только от
/// [EnrollmentBackend] — widget-тестируется фейком без сети и SQLCipher.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/database/database_service.dart';
import '../../../core/services/crypto_service.dart';
import '../../../core/services/device_v2/history_import.dart';
import '../../../core/services/device_v2/protocol.dart';
import '../../../core/services/device_v2/repository.dart';
import '../../../core/services/device_v2/transport.dart';
import '../../../core/theme/shade_theme.dart';
import 'pairing_common.dart';

/// Шаги мастера перехода.
enum EnrollmentStep { challenge, enrollment, history, done }

/// Аккаунт подготовлен как rotation_required (v1 RSA-2048): legacy-сессия
/// невозможна до смены ключа. Экран сообщает об этом честно, без тихой ротации.
class RotationRequiredException implements Exception {
  final String message;
  RotationRequiredException(this.message);
  @override
  String toString() => message;
}

/// Шаги enrollment, отделённые от реализации для widget-тестов.
abstract class EnrollmentBackend {
  String get account;

  /// Аккаунт уже зарегистрирован локально (идемпотентный повтор).
  bool get enrolled;

  /// Legacy-сессия уже открыта (cookie восстановлено из хранилища).
  bool get hasSession;

  /// Challenge → подпись исходным ключом → legacy-сессия.
  Future<void> openLegacySession();

  /// enrollLegacy: тот же RSA подписывает genesis; recovery шифруется фразой.
  Future<Map<String, dynamic>> enroll(String recoveryPassphrase);

  /// Импорт истории уже завершён ранее.
  Future<bool> historyImportCompleted();

  /// Локальный импорт истории v1 → v2 (ничего не отправляет на сервер).
  Future<HistoryImportResult> importHistory(
      {HistoryImportProgress? onProgress});
}

/// Реальная связка поверх существующих репозитория/транспорта/хранилища.
class RepositoryEnrollmentBackend implements EnrollmentBackend {
  final V2ChatRepository repository;
  final AlphaTransport transport;
  final CryptoService crypto;
  final DatabaseService database;

  RepositoryEnrollmentBackend({
    required this.repository,
    required this.transport,
    required this.crypto,
    required this.database,
  });

  @override
  String get account => repository.account;

  @override
  bool get enrolled => repository.enrolled;

  @override
  bool get hasSession => transport.hasSession;

  @override
  Future<void> openLegacySession() async {
    if (transport.hasSession) return;
    final account = repository.account;
    Object? sessionError;
    try {
      final nonce = await transport.legacyChallenge(account);
      final operation = operationDigest('legacy-session', null);
      final proof = await crypto.signData(
          requestText(account, 'primary', nonce, operation),
          repository.privateKey);
      final session = await transport.legacySession(account, nonce, proof);
      if (session['account'] != account) {
        throw StateError('Сервер вернул другой аккаунт; вход отклонён.');
      }
    } catch (error) {
      sessionError = error;
    }
    if (sessionError != null) {
      // Отличаем rotation_required от сетевого сбоя: rotation-challenge
      // отвечает только у подготовленных rotation-аккаунтов.
      try {
        await transport.rotationChallenge(account);
      } catch (_) {
        throw sessionError;
      }
      throw RotationRequiredException(
          'Этот аккаунт использует ключ RSA-2048 и требует смены ключа '
          '(rotation) перед переходом на v2. Выполните rotation на экране '
          'Alpha v2, затем повторите регистрацию здесь.');
    }
  }

  @override
  Future<Map<String, dynamic>> enroll(String recoveryPassphrase) async {
    final result =
        await repository.enrollLegacy(recoveryPassphrase: recoveryPassphrase);
    // Как в RealAlphaV2Backend.enroll: оживляем доставку после регистрации.
    repository.attachWake();
    transport.startPolling();
    try {
      await transport.connectSocket(
          account: repository.account,
          id: 'primary',
          privateKey: repository.privateKey);
    } catch (_) {
      // Потерянный socket чинится периодическим подписанным fetch.
    }
    return result;
  }

  @override
  Future<bool> historyImportCompleted() =>
      V1HistoryImporter.forRepository(repository, database: database)
          .completed();

  @override
  Future<HistoryImportResult> importHistory(
          {HistoryImportProgress? onProgress}) =>
      V1HistoryImporter.forRepository(repository, database: database)
          .run(onProgress: onProgress);
}

/// Текст ошибки для пользователя: причины протокола уже русские; служебные
/// коды транспорта переводятся без выдуманных деталей.
String enrollmentErrorText(Object error) {
  if (error is RotationRequiredException) return error.message;
  if (error is ProtocolException) return error.reason;
  if (error is StateError) return error.message;
  if (error is AlphaTransportException) {
    switch (error.code) {
      case 'login_required':
        return 'Сессия истекла. Подключите устройство заново.';
      case 'rate_limited':
        return 'Слишком много попыток. Подождите минуту и повторите.';
      default:
        return 'Сервер отклонил запрос (${error.code}). Повторите попытку.';
    }
  }
  if (error is SocketException ||
      error is HandshakeException ||
      error is TimeoutException) {
    return 'Нет связи с сервером. Проверьте сеть и повторите.';
  }
  return 'Не удалось выполнить шаг: $error';
}

class EnrollmentScreen extends StatefulWidget {
  const EnrollmentScreen({super.key, required this.backend, this.onFinished});

  final EnrollmentBackend backend;

  /// Вызывается по «Завершить»; если null — экран просто закрывается.
  final VoidCallback? onFinished;

  @override
  State<EnrollmentScreen> createState() => _EnrollmentScreenState();
}

/// Навигационная точка мастера enrollment для проводки в entry.
Route<void> enrollmentRoute(EnrollmentBackend backend,
        {VoidCallback? onFinished}) =>
    MaterialPageRoute<void>(
        builder: (_) =>
            EnrollmentScreen(backend: backend, onFinished: onFinished));

class _EnrollmentScreenState extends State<EnrollmentScreen> {
  final _passphrase = TextEditingController();
  EnrollmentStep _step = EnrollmentStep.challenge;
  bool _booting = true;
  bool _busy = false;
  bool _obscure = true;
  bool _alreadyEnrolled = false;
  bool _historyDone = false;
  bool _skippedImport = false;
  String? _error;
  int _processed = 0;
  int _total = 0;
  HistoryImportResult? _result;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _passphrase.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      final enrolled = widget.backend.enrolled;
      final hasSession = widget.backend.hasSession;
      var historyDone = false;
      if (enrolled) {
        historyDone = await widget.backend.historyImportCompleted();
      }
      if (!mounted) return;
      setState(() {
        _alreadyEnrolled = enrolled;
        _historyDone = historyDone;
        _step = enrolled
            ? (historyDone ? EnrollmentStep.done : EnrollmentStep.history)
            : (hasSession
                ? EnrollmentStep.enrollment
                : EnrollmentStep.challenge);
        _booting = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _booting = false;
        _error = enrollmentErrorText(error);
      });
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = enrollmentErrorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect() => _run(() async {
        await widget.backend.openLegacySession();
        if (!mounted) return;
        setState(() => _step = EnrollmentStep.enrollment);
      });

  Future<void> _enroll() async {
    final phrase = _passphrase.text;
    if (phrase.length < 24) {
      setState(() => _error =
          'Recovery-фраза: минимум 24 символа. Она не покидает устройство.');
      return;
    }
    await _run(() async {
      // alreadyEnrolled — идемпотентный повтор: ключи не пересоздаются.
      await widget.backend.enroll(phrase);
      if (!mounted) return;
      setState(() {
        _alreadyEnrolled = true;
        _step = EnrollmentStep.history;
      });
    });
  }

  Future<void> _importHistory() => _run(() async {
        final result =
            await widget.backend.importHistory(onProgress: (processed, total) {
          if (mounted) {
            setState(() {
              _processed = processed;
              _total = total;
            });
          }
        });
        if (!mounted) return;
        setState(() {
          _result = result;
          _historyDone = true;
          _step = EnrollmentStep.done;
        });
      });

  void _skipImport() {
    setState(() {
      _skippedImport = true;
      _step = EnrollmentStep.done;
    });
  }

  void _finish() {
    final onFinished = widget.onFinished;
    if (onFinished != null) {
      onFinished();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        backgroundColor: ShadeColors.black,
        appBar: AppBar(
            backgroundColor: ShadeColors.black,
            elevation: 0,
            scrolledUnderElevation: 0,
            title: const Text('Переход на Shade v2',
                style: TextStyle(color: ShadeColors.textPrimary, fontSize: 17))),
        body: _booting
            ? const Center(
                child: CircularProgressIndicator(color: ShadeColors.textSecondary))
            : SafeArea(
                child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _stepBar(),
                          const SizedBox(height: 20),
                          if (_error != null) PairingErrorBanner(_error!),
                          switch (_step) {
                            EnrollmentStep.challenge => _challengeView(),
                            EnrollmentStep.enrollment => _enrollmentView(),
                            EnrollmentStep.history => _historyView(),
                            EnrollmentStep.done => _doneView(),
                          },
                        ]))));
  }

  // ── Индикатор шагов ─────────────────────────────────────────────────────

  Widget _stepBar() {
    const labels = ['Подключение', 'Регистрация', 'История', 'Готово'];
    const icons = [
      Icons.link_rounded,
      Icons.phonelink_lock_rounded,
      Icons.history_rounded,
      Icons.check_circle_rounded
    ];
    const keys = [
      Key('enrollment-step-challenge'),
      Key('enrollment-step-enrollment'),
      Key('enrollment-step-history'),
      Key('enrollment-step-done')
    ];
    final current = _step.index;
    return Row(
        children: [
      for (var i = 0; i < labels.length; i++) ...[
        if (i > 0)
          Expanded(
              child: Container(
                  height: 1,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  color: i <= current
                      ? ShadeColors.textMuted
                      : ShadeColors.greyBorder)),
        _stepChip(keys[i], icons[i], labels[i],
            done: i < current, active: i == current),
      ]
    ]);
  }

  Widget _stepChip(Key key, IconData icon, String label,
      {required bool done, required bool active}) {
    final color = done || active
        ? ShadeColors.textPrimary
        : ShadeColors.textMuted;
    return Semantics(
        label: 'Шаг: $label${done ? ', выполнен' : active ? ', текущий' : ''}',
        container: true,
        // Фиксированная ширина + scaleDown: индикатор не переполняется на
        // узких экранах и при крупном системном шрифте.
        child: SizedBox(
            width: 62,
            child: Column(key: key, mainAxisSize: MainAxisSize.min, children: [
              Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                      color: active
                          ? ShadeColors.surfaceElevated
                          : ShadeColors.surfaceCard,
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: active
                              ? ShadeColors.textMuted
                              : ShadeColors.greyBorder)),
                  child: Icon(done ? Icons.check_rounded : icon,
                      size: 17, color: color)),
              const SizedBox(height: 5),
              FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(label,
                      maxLines: 1,
                      style: TextStyle(
                          color: color,
                          fontSize: 10.5,
                          fontWeight:
                              active ? FontWeight.w600 : FontWeight.w400))),
            ])));
  }

  // ── Шаг 1: challenge → legacy-сессия ────────────────────────────────────

  Widget _challengeView() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const PairingHeading(
          title: 'Подключение к серверу',
          description:
              'Устройство подтвердит владение исходным ключом v1: сервер выдаст '
              'одноразовый challenge, подпись создаётся локально. Приватный '
              'ключ не покидает устройство.'),
      PairingPrimaryButton(
          key: const Key('enrollment-connect'),
          label: 'Подключиться',
          busy: _busy,
          onPressed: _connect),
    ]);
  }

  // ── Шаг 2: enrollment тем же RSA ────────────────────────────────────────

  Widget _enrollmentView() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const PairingHeading(
          title: 'Регистрация устройства',
          description:
              'Исходный RSA-ключ подписывает genesis и остаётся ключом '
              'устройства: крипто-идентичность не меняется.'),
      _transferCard(),
      const SizedBox(height: 16),
      TextField(
          key: const Key('enrollment-passphrase'),
          controller: _passphrase,
          obscureText: _obscure,
          autocorrect: false,
          enableSuggestions: false,
          style: const TextStyle(color: ShadeColors.textPrimary, fontSize: 14),
          decoration: pairingInputDecoration('Recovery-фраза',
                  hint: 'Минимум 24 символа')
              .copyWith(
                  suffixIcon: IconButton(
                      tooltip: _obscure ? 'Показать фразу' : 'Скрыть фразу',
                      icon: Icon(
                          _obscure
                              ? Icons.visibility_rounded
                              : Icons.visibility_off_rounded,
                          size: 18,
                          color: ShadeColors.textSecondary),
                      onPressed: () =>
                          setState(() => _obscure = !_obscure)))),
      const SizedBox(height: 8),
      const Text(
          'Фраза шифрует независимый ключ восстановления. Она не покидает '
          'устройство и не отправляется на сервер. Запишите её: без фразы '
          'recovery-ключ не разблокировать.',
          style: TextStyle(
              color: ShadeColors.textSecondary, fontSize: 12, height: 1.45)),
      const SizedBox(height: 16),
      PairingPrimaryButton(
          key: const Key('enrollment-enroll'),
          label: 'Зарегистрировать устройство',
          busy: _busy,
          onPressed: _enroll),
    ]);
  }

  /// Честный список что переносится и что нет.
  Widget _transferCard() {
    return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: ShadeColors.surfaceCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: ShadeColors.greyBorder)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Что переносится',
              style: TextStyle(
                  color: ShadeColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          _bullet(
              'Личность и аккаунт — тем же RSA-ключом: контакты и ключи не '
              'меняются.'),
          _bullet(
              'Локальная история сообщений — в новое хранилище на этом '
              'устройстве (следующий шаг, по желанию).'),
          const SizedBox(height: 10),
          const Text('Что не переносится сразу',
              style: TextStyle(
                  color: ShadeColors.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          _bullet(
              'Недоставленные сообщения останутся в очередях v1, пока мост '
              'их не доставит.'),
        ]));
  }

  Widget _bullet(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('•  ',
            style: TextStyle(color: ShadeColors.textMuted, fontSize: 12.5)),
        Expanded(
            child: Text(text,
                style: const TextStyle(
                    color: ShadeColors.textSecondary,
                    fontSize: 12.5,
                    height: 1.4))),
      ]));

  // ── Шаг 3: импорт истории (опционален, но предложен) ────────────────────

  Widget _historyView() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const PairingHeading(
          title: 'История сообщений',
          description:
              'Локальная история v1 будет перешифрована в хранилище v2 на '
              'этом устройстве. Оригиналы остаются в v1 без изменений; '
              'plaintext не отправляется на сервер. Импорт можно пропустить '
              'и выполнить позже.'),
      if (_busy) ...[
        LinearProgressIndicator(
            key: const Key('enrollment-import-progress'),
            value: _total > 0 ? (_processed / _total).clamp(0.0, 1.0) : null,
            backgroundColor: ShadeColors.surfaceElevated,
            color: ShadeColors.textMuted),
        const SizedBox(height: 8),
        Text('Перенесено $_processed из $_total',
            style: const TextStyle(
                color: ShadeColors.textSecondary, fontSize: 12)),
        const SizedBox(height: 16),
      ],
      PairingPrimaryButton(
          key: const Key('enrollment-import'),
          label: 'Перенести историю',
          busy: _busy,
          onPressed: _importHistory),
      const SizedBox(height: 8),
      SizedBox(
          width: double.infinity,
          height: 44,
          child: TextButton(
              key: const Key('enrollment-skip-import'),
              onPressed: _busy ? null : _skipImport,
              child: const Text('Пропустить',
                  style: TextStyle(
                      color: ShadeColors.textSecondary, fontSize: 13.5)))),
    ]);
  }

  // ── Шаг 4: готово ───────────────────────────────────────────────────────

  Widget _doneView() {
    final result = _result;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      PairingHeading(
          title: 'Готово',
          description: _alreadyEnrolled && result == null && !_skippedImport
              ? 'Устройство уже зарегистрировано на v2 с тем же ключом.'
              : 'Устройство зарегистрировано на v2 с тем же RSA-ключом.'),
      if (_skippedImport)
        _note(
            'Импорт истории пропущен. Его можно выполнить позже, открыв этот '
            'экран снова: повторный импорт не создаёт дублей.')
      else if (result != null) ...[
        _note('Перенесено сообщений: ${result.imported}.'),
        if (result.duplicates > 0)
          _note('Повторно встречено и пропущено (дедуп): ${result.duplicates}.'),
        if (result.pendingLeft > 0)
          _note(
              'Недоставленных осталось в очередях v1: ${result.pendingLeft}. '
              'Мост доставит их отдельно.'),
        if (result.failed > 0)
          _warning(
              'Не удалось расшифровать записей: ${result.failed}. Они '
              'остались в хранилище v1 без изменений.'),
      ] else if (_historyDone)
        _note('История уже перенесена ранее.'),
      const SizedBox(height: 16),
      PairingPrimaryButton(
          key: const Key('enrollment-finish'),
          label: 'Завершить',
          onPressed: _finish),
    ]);
  }

  Widget _note(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text,
          style: const TextStyle(
              color: ShadeColors.textSecondary, fontSize: 13, height: 1.45)));

  Widget _warning(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text,
          style: const TextStyle(
              color: Color(0xFFEF4444), fontSize: 13, height: 1.45)));
}
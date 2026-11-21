import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shade/core/services/picked_file.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart' show InvalidCipherTextException;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/services/device_v2/protocol.dart';
import '../../../core/services/device_v2/repository.dart';
import '../../../core/services/device_v2/transport.dart';
import '../../../core/theme/shade_theme.dart';
import 'pairing_common.dart';

/// Нативный экран восстановления с recovery-пакетом (PRF_RECOVERY_BLOCKER §3).
///
/// Зеркало web-flow recoverWithBackup: криптография и сеть живут в
/// V2ChatRepository, экран — поля, шаги и честные ошибки. Все устройства
/// аккаунта утрачены; старые ключи НЕ возвращаются, создаются новые.
///
/// Самодостаточен: принимает [repository] (до enrollment — с аккаунтом '').
/// Защита новых ключей на нативе — шифрованное хранилище устройства
/// (SQLCipher с device-bound ключом, как у completePairing): локальная
/// разблокировка не требует фразы устройства, поэтому фразовый gate не
/// показывается. Recovery-фраза реально расшифровывает пакет. Переносимый
/// vault-экспорт для web и PRF-проводка — отдельные задачи после беты.
class NativeRecoveryScreen extends StatefulWidget {
  final V2ChatRepository repository;

  /// Инъекция выбора файла для тестов; по умолчанию — системный file picker.
  final Future<PickedFile?> Function()? pickPackage;

  const NativeRecoveryScreen(
      {super.key, required this.repository, this.pickPackage});

  @override
  State<NativeRecoveryScreen> createState() => _NativeRecoveryScreenState();
}

Future<bool> saveNativeRecoveryFile(String json) async =>
    await const MethodChannel('com.shade.app/security')
        .invokeMethod<bool>('saveRecoveryPackage', {'json': json}) ??
    false;

enum _RecoveryStage { form, done }

/// Честные русские тексты ошибок восстановления (зеркало recoveryErrors
/// client/web/alpha-ui.mjs): ни одна причина не замалчивается.
String recoveryErrorText(Object error) {
  if (error is ProtocolException) {
    const translations = {
      'bad_package_json':
          'Файл не похож на recovery-пакет Shade: не удалось разобрать JSON.',
      'bad_package_shape':
          'Файл не похож на recovery-пакет Shade: ожидается JSON с полями backup и genesis.',
      'Recovery identity mismatch':
          'Recovery-пакет не соответствует аккаунту: ключ или отпечаток не совпадают. Возможно, файл повреждён или это чужой пакет.',
      'Recovery backup must pin the exact account genesis':
          'Пакет не привязан к genesis аккаунта: он не завершён или подменён. Используйте пакет, скачанный при регистрации.',
      'Genesis digest mismatch':
          'Genesis аккаунта на сервере не совпадает с пакетом. Восстановление остановлено; ключи не заменены.',
      'Recovery key mismatch':
          'Recovery-ключ аккаунта на сервере не совпадает с пакетом. Восстановление остановлено; ключи не заменены.',
      'Invalid recovery proof':
          'Сервер отклонил подпись recovery-ключа. Проверьте пакет и фразу.',
      'Invalid or replayed challenge':
          'Challenge восстановления истёк или уже использован. Повторите попытку.',
      'Account is not enrolled': 'Аккаунт из пакета не найден на сервере.',
      'Invalid account': 'Некорректный аккаунт в recovery-пакете.',
      'Challenge quota reached':
          'Слишком много запросов challenge. Подождите минуту и повторите.',
      'Recovery capacity reached':
          'Сервер перегружен попытками восстановления. Повторите позже.',
      'Recovery key validation failed':
          'Recovery-пакет повреждён: данные не соответствуют формату Shade. Проверьте файл.',
      'Invalid protocol data':
          'Recovery-пакет повреждён: данные не соответствуют формату Shade. Проверьте файл.',
      'Unexpected fields':
          'Recovery-пакет повреждён: данные не соответствуют формату Shade. Проверьте файл.',
      'Unsupported RSA key':
          'Recovery-пакет повреждён: данные не соответствуют формату Shade. Проверьте файл.',
      'Каталог сервера не совпадает с recovery-пакетом':
          'Каталог сервера не совпадает с recovery-пакетом. Восстановление остановлено; ключи не заменены.',
      'Recovery-пакет принадлежит другому аккаунту':
          'Recovery-пакет принадлежит другому аккаунту. Подключите это устройство к аккаунту пакета.',
    };
    return translations[error.reason] ?? error.reason;
  }
  // Сбой AES-GCM при расшифровке пакета: неверная фраза либо битый ciphertext.
  if (error is InvalidCipherTextException) {
    return 'Неверная recovery-фраза или повреждённый пакет. Проверьте фразу и файл.';
  }
  if (error is AlphaTransportException) {
    if (error.status == 429 || error.code == 'rate_limited') {
      return 'Слишком много попыток, подожди час';
    }
    switch (error.code) {
      case 'login_required':
        return 'Recovery-сессия истекла. Повторите восстановление.';
      case 'operation_rejected':
        return 'Сервер отклонил операцию восстановления. Повторите попытку.';
      case 'origin_rejected':
        return 'Сервер отклонил origin приложения. Проверьте адрес alpha-сервера.';
      default:
        return 'Сервер недоступен (${error.code}). Проверьте соединение и повторите попытку.';
    }
  }
  if (error is SocketException) {
    return 'Нет сети. Подключитесь к интернету и повторите попытку.';
  }
  if (error is HandshakeException) {
    return 'Не удалось установить защищённое соединение с сервером. Проверьте адрес alpha-сервера.';
  }
  if (error is TimeoutException) {
    return 'Сервер не ответил вовремя. Повторите попытку.';
  }
  if (error is StateError) return error.message;
  return 'Не удалось выполнить восстановление: $error';
}

class _NativeRecoveryScreenState extends State<NativeRecoveryScreen> {
  _RecoveryStage _stage = _RecoveryStage.form;
  bool _busy = false;
  bool _picking = false;
  String? _stepId;
  String? _error;
  Map<String, dynamic>? _pkg;
  String? _fileName;
  String? _packageAccount;
  String? _recoveredAccount;
  final _recoveryPhrase = TextEditingController();
  bool _showRecoveryPhrase = false;

  // Честная плашка: старая история шифровалась под утраченные ключи и не
  // восстанавливается; возвращаются личность и доступ к новым сообщениям.
  static const _bannerForm =
      'Старая переписка недоступна: она шифровалась под утраченные ключи. '
      'Восстановление вернёт личность и доступ к новым сообщениям.';
  static const _bannerDone =
      'Старая переписка недоступна: она шифровалась под утраченные ключи. '
      'Восстановлена личность и доступ к новым сообщениям.';

  // Шаги потока recoverWithBackup (порядок веб-контракта).
  static const _steps = <(String, String)>[
    ('unlock', 'Проверяем recovery-пакет и фразу'),
    ('keys', 'Создаём новые ключи устройства'),
    ('session', 'Открываем recovery-сессию'),
    ('install', 'Обновляем список устройств аккаунта'),
    ('bootstrap', 'Открываем сессию нового устройства'),
  ];

  @override
  void dispose() {
    _recoveryPhrase.dispose();
    super.dispose();
  }

  Future<PickedFile?> _defaultPick() async {
    // Системный выбор файла через MainActivity (ACTION_OPEN_DOCUMENT):
    // без стороннего плагина file_picker (его Android-часть несовместима
    // с AGP 9 / built-in Kotlin конфигурацией проекта).
    final result = await const MethodChannel('com.shade.app/security')
        .invokeMethod<Map<dynamic, dynamic>>('pickRecoveryPackage');
    if (result == null) return null; // отмена выбора — не ошибка
    final bytes = Uint8List.fromList(List<int>.from(result['bytes'] as List));
    return PickedFile(
        name: result['name'] as String? ?? 'recovery-package.json',
        size: bytes.length,
        bytes: bytes);
  }

  /// Полная проверка формы genesis и полей пакета ДО ввода фразы:
  /// битый/чужой файл отсекается сразу с честным текстом (как recovery.pick
  /// в alpha-ui.mjs). Размер ≤1 МБ.
  Map<String, dynamic> _parsePackage(String name, Uint8List bytes) {
    check(bytes.length <= 1024 * 1024, 'bad_package_shape');
    final dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } catch (_) {
      throw ProtocolException('bad_package_json');
    }
    check(
        decoded is Map && decoded['backup'] is Map && decoded['genesis'] is Map,
        'bad_package_shape');
    final pkg = Map<String, dynamic>.from(decoded as Map);
    final genesis = Map<String, dynamic>.from(pkg['genesis'] as Map);
    final account = genesis['account'];
    check(account is String && accountPattern.hasMatch(account),
        'bad_package_shape');
    try {
      genesisText(genesis);
    } catch (_) {
      throw ProtocolException('bad_package_shape');
    }
    final backup = Map<String, dynamic>.from(pkg['backup'] as Map);
    check(
        backup['version'] == 2 &&
            backup['ciphertext'] is String &&
            backup['salt'] is String &&
            backup['iv'] is String &&
            backup['publicKey'] is String &&
            backup['rootFingerprint'] is String,
        'bad_package_shape');
    return {'backup': backup, 'genesis': genesis};
  }

  Future<void> _pick() async {
    if (_busy || _picking) return;
    setState(() => _picking = true);
    try {
      final file = await (widget.pickPackage?.call() ?? _defaultPick());
      if (!mounted || file == null) return; // отмена выбора — не ошибка
      // Размер отсекается ДО чтения содержимого (как recovery.pick в web).
      check(file.size <= 1024 * 1024, 'bad_package_shape');
      final bytes = file.bytes ??
          (file.path != null
              ? await File(file.path!).readAsBytes()
              : throw ProtocolException('bad_package_shape'));
      final pkg = _parsePackage(file.name, bytes);
      if (!mounted) return;
      setState(() {
        _pkg = pkg;
        _fileName = file.name;
        _packageAccount =
            (pkg['genesis'] as Map<String, dynamic>)['account'] as String;
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = recoveryErrorText(error));
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// Долговечная связка сессии — та же, что у RealAlphaV2Backend.connect:
  /// после перезапуска v2-стек восстановит доступ из этих ключей (restore()).
  Future<void> _persistSession(String account) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'alpha_v2_origin', widget.repository.transport.origin);
    await prefs.setString('alpha_v2_account', account);
    const secure = FlutterSecureStorage(
        aOptions: AndroidOptions(encryptedSharedPreferences: true));
    final cookie = widget.repository.transport.sessionCookie;
    if (cookie != null) {
      await secure.write(key: 'alpha_v2_cookie', value: cookie);
    }
  }

  Future<void> _submit() async {
    if (_busy) return;
    final pkg = _pkg;
    if (pkg == null) {
      setState(() => _error = 'Выберите файл recovery-пакета.');
      return;
    }
    final phrase = _recoveryPhrase.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (phrase.length < 24) {
      setState(() => _error =
          'Введите recovery-фразу из пакета: 8 слов, не менее 24 символов.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _stepId = 'unlock';
    });
    try {
      final result = await widget.repository.recoverWithBackup(pkg, phrase,
          onStep: (step) {
        if (mounted) setState(() => _stepId = step);
      });
      // Успех: секретные поля очищаются — фразы не остаются в памяти UI.
      _recoveryPhrase.clear();
      final account = result['account'] as String;
      await _persistSession(account);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _stepId = null;
        _recoveredAccount = account;
        _stage = _RecoveryStage.done;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _stepId = null;
          _error = recoveryErrorText(error);
        });
      }
    }
  }

  Widget _banner(String text) => Semantics(
      label: 'Важно о восстановлении',
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: ShadeColors.surfaceCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: ShadeColors.greyBorder, width: 0.5)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.info_outline,
              size: 18, color: ShadeColors.textSecondary),
          const SizedBox(width: 10),
          Expanded(
              child: Text(text,
                  style: const TextStyle(
                      fontSize: 12.5,
                      height: 1.5,
                      color: ShadeColors.textSecondary))),
        ]),
      ));

  Widget _errorBanner(String error) => Semantics(
      liveRegion: true,
      label: 'Ошибка восстановления',
      child: PairingErrorBanner(error));

  Widget _progress() {
    final active = _steps.indexWhere((s) => s.$1 == _stepId);
    return Semantics(
        liveRegion: true,
        label: 'Шаг восстановления',
        child: Column(children: [
          for (var i = 0; i < _steps.length; i++) ...[
            Row(children: [
              if (i < active)
                const Icon(Icons.check_circle_outline,
                    size: 16, color: ShadeColors.textSecondary)
              else if (i == active)
                const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
              else
                const Icon(Icons.circle_outlined,
                    size: 16, color: ShadeColors.greyBorder),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(_steps[i].$2,
                      style: TextStyle(
                          fontSize: 12.5,
                          height: 1.4,
                          color: i == active
                              ? ShadeColors.textPrimary
                              : ShadeColors.textSecondary))),
            ]),
            if (i < _steps.length - 1) const SizedBox(height: 10),
          ],
        ]));
  }

  Widget _buildForm() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const PairingHeading(
          title: 'Восстановление аккаунта',
          description:
              'Recovery-пакет вернёт вашу личность в Shade на этом устройстве. '
              'Ключи устройства создаются заново; фразы не покидают устройство.'),
      _banner(_bannerForm),
      const SizedBox(height: 16),
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: ShadeColors.surfaceCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: ShadeColors.greyBorder, width: 0.5)),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Recovery-пакет',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                  color: ShadeColors.textSecondary)),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _busy || _picking ? null : _pick,
            style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12))),
            icon: const Icon(Icons.upload_file_outlined, size: 18),
            label: Text(_fileName == null
                ? 'Выбрать файл пакета (JSON)'
                : 'Выбрать другой файл'),
          ),
          if (_fileName != null) ...[
            const SizedBox(height: 10),
            Semantics(
                label:
                    'Выбранный recovery-пакет: $_fileName, аккаунт ${_packageAccount ?? ''}',
                child: Row(children: [
                  const Icon(Icons.description_outlined,
                      size: 16, color: ShadeColors.textSecondary),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text('$_fileName · @$_packageAccount',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12.5,
                              color: ShadeColors.textSecondary))),
                ])),
          ],
          const SizedBox(height: 18),
          TextField(
            controller: _recoveryPhrase,
            enabled: !_busy,
            obscureText: !_showRecoveryPhrase,
            enableSuggestions: false,
            autocorrect: false,
            keyboardType: TextInputType.visiblePassword,
            textInputAction: TextInputAction.done,
            style:
                const TextStyle(color: ShadeColors.textPrimary, fontSize: 14),
            decoration: pairingInputDecoration('Recovery-фраза',
                hint: '8 слов, записанных при регистрации'),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
          Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () =>
                    setState(() => _showRecoveryPhrase = !_showRecoveryPhrase),
                icon: Icon(
                    _showRecoveryPhrase
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 18,
                    color: ShadeColors.textMuted),
                label: Text(
                    _showRecoveryPhrase ? 'Скрыть фразу' : 'Показать фразу',
                    style: const TextStyle(
                        fontSize: 12.5, color: ShadeColors.textMuted)),
              )),
          const SizedBox(height: 6),
          const Text('Защита новых ключей',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                  color: ShadeColors.textSecondary)),
          const SizedBox(height: 8),
          const Text(
              'Новые ключи защищены шифрованным хранилищем устройства '
              '(SQLCipher, ключ в Keystore); локальная разблокировка не требует '
              'фразы. Биометрическая защита (PRF) и переносимый vault-экспорт '
              'для web появятся позже.',
              style: TextStyle(
                  fontSize: 12, height: 1.5, color: ShadeColors.textMuted)),
          if (_error != null) ...[
            const SizedBox(height: 16),
            _errorBanner(_error!),
          ],
          const SizedBox(height: 20),
          PairingPrimaryButton(
              label: _busy ? 'Восстанавливаем…' : 'Восстановить аккаунт',
              busy: _busy,
              onPressed: _submit),
          if (_busy) ...[
            const SizedBox(height: 18),
            _progress(),
          ],
        ]),
      ),
    ]);
  }

  Widget _buildDone() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _banner(_bannerDone),
      const SizedBox(height: 16),
      Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
            color: ShadeColors.surfaceCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: ShadeColors.greyBorder, width: 0.5)),
        child: Column(children: [
          const Icon(Icons.check_circle_outline,
              size: 44, color: ShadeColors.textPrimary),
          const SizedBox(height: 12),
          const Text('Личность восстановлена',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: ShadeColors.textPrimary)),
          const SizedBox(height: 8),
          Text(
              'Аккаунт @$_recoveredAccount снова доступен на этом устройстве. '
              'Каталог сервера проверен против закреплённого genesis; ключи '
              'устройства и состояние сохранены в зашифрованном хранилище.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 13, height: 1.5, color: ShadeColors.textSecondary)),
          const SizedBox(height: 18),
          PairingPrimaryButton(
              label: 'Перейти в чаты',
              onPressed: () => Navigator.of(context).pop(true)),
        ]),
      ),
      const SizedBox(height: 12),
      const Text(
          'Recovery-пакет и фраза продолжают действовать — храните их вне устройства.',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 12, height: 1.5, color: ShadeColors.textMuted)),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    // Во время восстановления назад не уходим: поток должен завершиться
    // (успехом или честной ошибкой), ключи не фиксируются частично.
    return PopScope(
        canPop: !_busy,
        child: Scaffold(
            backgroundColor: ShadeColors.black,
            appBar: AppBar(
                backgroundColor: ShadeColors.black,
                title: const Text('Восстановление',
                    style: TextStyle(
                        color: ShadeColors.textPrimary, fontSize: 17))),
            body: SafeArea(
                child: Center(
                    child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 640),
                        child: ListView(
                            padding: const EdgeInsets.all(20),
                            children: [
                              if (_stage == _RecoveryStage.done)
                                _buildDone()
                              else
                                _buildForm(),
                            ]))))));
  }
}

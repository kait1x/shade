import 'package:flutter/material.dart';
import 'package:shade/core/theme/shade_theme.dart';
import 'package:shade/core/widgets/shade_logo.dart';
import 'alpha_controller.dart';

/// Экран «Восстановить с recovery-пакетом» (PRF_RECOVERY_BLOCKER §3).
/// Криптография, сеть и пакет живут в JS-ядре (alpha-ui.mjs / alpha-client.mjs);
/// этот экран — проекция через мост: поля, выбор защиты нового vault, шаги
/// восстановления и честные ошибки. Пакет и ключи в проекцию не передаются.
class RecoveryScreen extends StatefulWidget {
  const RecoveryScreen({super.key, required this.controller});
  final AlphaController controller;
  @override
  State<RecoveryScreen> createState() => _RecoveryScreenState();
}

class _RecoveryScreenState extends State<RecoveryScreen> {
  final _recoveryPhrase = TextEditingController();
  final _devicePhrase = TextEditingController();
  final _deviceConfirm = TextEditingController();
  String _protection = 'phrase';
  String? _localError;
  bool _showRecoveryPhrase = false;

  // Честная плашка: старая история шифровалась под утраченные ключи и не
  // восстанавливается; возвращаются личность и доступ к новым сообщениям.
  static const _bannerForm =
      'Старая переписка недоступна: она шифровалась под утраченные ключи. '
      'Восстановление вернёт личность и доступ к новым сообщениям.';
  static const _bannerDone =
      'Старая переписка недоступна: она шифровалась под утраченные ключи. '
      'Восстановлена личность и доступ к новым сообщениям.';

  // Шаги потока recoverWithBackup; binding добавляется только для PRF-пути.
  static const _steps = <(String, String)>[
    ('unlock', 'Проверяем recovery-пакет и фразу'),
    ('keys', 'Создаём новые ключи устройства'),
    ('session', 'Открываем recovery-сессию'),
    ('install', 'Обновляем список устройств аккаунта'),
    ('bootstrap', 'Открываем сессию нового устройства'),
  ];

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_projectionChanged);
  }

  // После успеха секретные поля очищаются: фразы не остаются в памяти UI.
  void _projectionChanged() {
    if (widget.controller.recovery?['step'] == 'done') {
      _recoveryPhrase.clear();
      _devicePhrase.clear();
      _deviceConfirm.clear();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_projectionChanged);
    _recoveryPhrase.dispose();
    _devicePhrase.dispose();
    _deviceConfirm.dispose();
    super.dispose();
  }

  // PRF может стать недоступным по ходу потока — выбор честно падает на фразу.
  String get _effectiveProtection =>
      _protection == 'prf' && widget.controller.recovery?['prfAvailable'] != true
          ? 'phrase'
          : _protection;

  void _act(String action, [Map<String, dynamic> payload = const {}]) {
    widget.controller.act(action, payload).catchError((Object error) {
      if (mounted) {
        setState(() =>
            _localError = error is StateError ? error.message : '$error');
      }
    });
  }

  void _submit() {
    final r = widget.controller.recovery ?? const <String, dynamic>{};
    if (r['busy'] == true) return;
    final protection = _effectiveProtection;
    String? problem;
    if (r['fileName'] == null) {
      problem = 'Выберите файл recovery-пакета.';
    } else if (_recoveryPhrase.text.trim().length < 24) {
      problem = 'Введите recovery-фразу из пакета: 8 слов, не менее 24 символов.';
    } else if (protection == 'phrase' && _devicePhrase.text.length < 16) {
      problem = 'Фраза устройства должна быть не короче 16 символов.';
    } else if (protection == 'phrase' &&
        _devicePhrase.text != _deviceConfirm.text) {
      problem = 'Фразы устройства не совпадают.';
    }
    if (problem != null) {
      setState(() => _localError = problem);
      return;
    }
    setState(() => _localError = null);
    _act('recovery.run', {
      'recoveryPhrase': _recoveryPhrase.text.trim(),
      'protection': protection,
      if (protection == 'phrase') 'devicePassphrase': _devicePhrase.text,
    });
  }

  InputDecoration _decoration(String label, {String? hint, Widget? suffix}) =>
      InputDecoration(
        labelText: label,
        hintText: hint,
        suffixIcon: suffix,
        fillColor: ShadeColors.black,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: ShadeColors.greyBorder)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: ShadeColors.greyBorder)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: const BorderSide(color: ShadeColors.violet, width: 1.5)),
      );

  Widget _sectionLabel(String text) => Text(text,
      style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
          color: ShadeColors.textSecondary));

  Widget _banner(String text) => Semantics(
      label: 'Важно о восстановлении',
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: ShadeColors.surfaceCard,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: ShadeColors.greyBorder, width: 0.5)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.info_outline, size: 18, color: ShadeColors.textSecondary),
          const SizedBox(width: 10),
          Expanded(
              child: Text(text,
                  style: const TextStyle(
                      fontSize: 12.5, height: 1.5, color: ShadeColors.textSecondary))),
        ]),
      ));

  Widget _errorBanner(String error) => Semantics(
      liveRegion: true,
      label: 'Ошибка восстановления',
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: ShadeColors.surfaceDark,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
                color: Theme.of(context).colorScheme.error.withValues(alpha: 0.5))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.error_outline, size: 18, color: Theme.of(context).colorScheme.error),
          const SizedBox(width: 10),
          Expanded(
              child: Text(error,
                  style: TextStyle(
                      fontSize: 12.5,
                      height: 1.5,
                      color: Theme.of(context).colorScheme.error))),
        ]),
      ));

  Widget _progress(String? stepId) {
    final steps = <(String, String)>[
      if (_effectiveProtection == 'prf')
        ('binding', 'Подтверждаем защиту устройства'),
      ..._steps,
    ];
    final active = steps.indexWhere((s) => s.$1 == stepId);
    return Semantics(
        liveRegion: true,
        label: 'Шаг восстановления',
        child: Column(children: [
          for (var i = 0; i < steps.length; i++) ...[
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
                  child: Text(steps[i].$2,
                      style: TextStyle(
                          fontSize: 12.5,
                          height: 1.4,
                          color: i == active
                              ? ShadeColors.textPrimary
                              : ShadeColors.textSecondary))),
            ]),
            if (i < steps.length - 1) const SizedBox(height: 10),
          ],
        ]));
  }

  List<Widget> _form({
    required bool busy,
    required String? stepId,
    required String? fileName,
    required String? packageAccount,
    required bool prfAvailable,
    required String? error,
  }) {
    final protection = _effectiveProtection;
    return [
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
            color: ShadeColors.surfaceCard,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: ShadeColors.greyBorder, width: 0.5)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _sectionLabel('Recovery-пакет'),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: busy ? null : () => _act('recovery.pick'),
            style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18))),
            icon: const Icon(Icons.upload_file_outlined, size: 18),
            label: Text(fileName == null
                ? 'Выбрать файл пакета (JSON)'
                : 'Выбрать другой файл'),
          ),
          if (fileName != null) ...[
            const SizedBox(height: 10),
            Semantics(
                label:
                    'Выбранный recovery-пакет: $fileName, аккаунт ${packageAccount ?? ''}',
                child: Row(children: [
                  const Icon(Icons.description_outlined,
                      size: 16, color: ShadeColors.textSecondary),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text(
                          fileName +
                              (packageAccount != null ? ' · @$packageAccount' : ''),
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12.5, color: ShadeColors.textSecondary))),
                ])),
          ],
          const SizedBox(height: 18),
          TextField(
            controller: _recoveryPhrase,
            obscureText: !_showRecoveryPhrase,
            enableSuggestions: false,
            autocorrect: false,
            keyboardType: TextInputType.visiblePassword,
            textInputAction: TextInputAction.next,
            decoration: _decoration('Recovery-фраза',
                hint: '8 слов, записанных при регистрации',
                suffix: IconButton(
                  onPressed: () =>
                      setState(() => _showRecoveryPhrase = !_showRecoveryPhrase),
                  tooltip: _showRecoveryPhrase ? 'Скрыть фразу' : 'Показать фразу',
                  icon: Icon(
                      _showRecoveryPhrase
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                      size: 20,
                      color: ShadeColors.textMuted),
                )),
            onChanged: (_) {
              if (_localError != null) setState(() => _localError = null);
            },
          ),
          const SizedBox(height: 18),
          _sectionLabel('Защита нового vault'),
          const SizedBox(height: 10),
          if (prfAvailable)
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'phrase', label: Text('Фраза устройства')),
                ButtonSegment(value: 'prf', label: Text('Биометрия (PRF)')),
              ],
              selected: {protection},
              showSelectedIcon: false,
              onSelectionChanged: busy
                  ? null
                  : (selection) => setState(() {
                        _protection = selection.first;
                        _localError = null;
                      }),
              style: SegmentedButton.styleFrom(
                  textStyle:
                      const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18))),
            )
          else
            const Text('Фраза устройства',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: ShadeColors.textPrimary)),
          if (!prfAvailable) ...[
            const SizedBox(height: 8),
            const Text(
                'Биометрическая защита (PRF) недоступна в этом браузере — используйте фразу устройства.',
                style: TextStyle(fontSize: 12, height: 1.4, color: ShadeColors.textMuted)),
          ] else if (protection == 'prf') ...[
            const SizedBox(height: 8),
            const Text(
                'Новый vault будет защищён биометрией этого устройства. При утрате passkey снова понадобится recovery-пакет.',
                style: TextStyle(fontSize: 12, height: 1.4, color: ShadeColors.textMuted)),
          ],
          if (protection == 'phrase') ...[
            const SizedBox(height: 14),
            TextField(
              controller: _devicePhrase,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              keyboardType: TextInputType.visiblePassword,
              textInputAction: TextInputAction.next,
              decoration: _decoration('Фраза устройства · от 16 символов'),
              onChanged: (_) {
                if (_localError != null) setState(() => _localError = null);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _deviceConfirm,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              keyboardType: TextInputType.visiblePassword,
              textInputAction: TextInputAction.done,
              decoration: _decoration('Повторите фразу устройства'),
              onChanged: (_) {
                if (_localError != null) setState(() => _localError = null);
              },
            ),
          ],
          if (error != null) ...[
            const SizedBox(height: 16),
            _errorBanner(error),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: busy ? null : _submit,
            style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18))),
            child: busy
                ? const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: ShadeColors.black)),
                    SizedBox(width: 10),
                    Text('Восстанавливаем…'),
                  ])
                : const Text('Восстановить аккаунт'),
          ),
          if (busy) ...[
            const SizedBox(height: 18),
            _progress(stepId),
          ],
        ]),
      ),
      const SizedBox(height: 8),
      TextButton(
        onPressed: busy ? null : () => _act('recovery.back'),
        child: const Text('Назад к разблокировке',
            style: TextStyle(fontSize: 13, color: ShadeColors.textMuted)),
      ),
    ];
  }

  List<Widget> _success(String? packageAccount) => [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
              color: ShadeColors.surfaceCard,
              borderRadius: BorderRadius.circular(18),
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
                'Аккаунт ${packageAccount != null ? '@$packageAccount' : ''} снова доступен на этом устройстве. Новые ключи защищены выбранным способом.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 13, height: 1.5, color: ShadeColors.textSecondary)),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: () => _act('recovery.finish'),
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18))),
              child: const Text('Открыть Shade'),
            ),
          ]),
        ),
        const SizedBox(height: 12),
        const Text(
            'Recovery-пакет и фраза продолжают действовать — храните их вне устройства.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, height: 1.5, color: ShadeColors.textMuted)),
      ];

  @override
  Widget build(BuildContext context) {
    final r = widget.controller.recovery ?? const <String, dynamic>{};
    final step = r['step'] as String? ?? 'form';
    final busy = r['busy'] == true;
    final error = (r['error'] as String?) ?? _localError;
    return Scaffold(
      backgroundColor: ShadeColors.black,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Row(children: [
                      ShadeLogo(size: 28),
                      SizedBox(width: 8),
                      Text('shade',
                          style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -1,
                              color: ShadeColors.textPrimary)),
                    ]),
                    const SizedBox(height: 24),
                    const Text('Восстановление аккаунта',
                        style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.5,
                            color: ShadeColors.textPrimary)),
                    const SizedBox(height: 8),
                    const Text(
                        'Recovery-пакет вернёт вашу личность в Shade на этом устройстве. Ключи устройства создаются заново; фразы не покидают браузер.',
                        style: TextStyle(
                            fontSize: 13.5,
                            height: 1.5,
                            color: ShadeColors.textSecondary)),
                    const SizedBox(height: 18),
                    _banner(step == 'done' ? _bannerDone : _bannerForm),
                    const SizedBox(height: 18),
                    if (step == 'done')
                      ..._success(r['packageAccount'] as String?)
                    else
                      ..._form(
                        busy: busy,
                        stepId: r['stepId'] as String?,
                        fileName: r['fileName'] as String?,
                        packageAccount: r['packageAccount'] as String?,
                        prfAvailable: r['prfAvailable'] == true,
                        error: error,
                      ),
                  ]),
            ),
          ),
        ),
      ),
    );
  }
}
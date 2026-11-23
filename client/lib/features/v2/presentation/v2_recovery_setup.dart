import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shade/core/services/device_v2/recovery_setup.dart';
import 'package:shade/core/services/device_v2/repository.dart';
import 'package:shade/features/devices/presentation/recovery_screen.dart'
    show saveNativeRecoveryFile;

class V2RecoverySetup extends StatefulWidget {
  const V2RecoverySetup({super.key, required this.repository});

  final V2ChatRepository repository;

  @override
  State<V2RecoverySetup> createState() => _V2RecoverySetupState();
}

class _V2RecoverySetupState extends State<V2RecoverySetup> {
  late final DeferredRecoveryPhrase _secret = DeferredRecoveryPhrase(
      widget.repository.transport.origin, widget.repository.account);
  late final Future<String?> _phrase = _secret.read();
  bool _revealed = false, _saved = false, _confirmed = false, _busy = false;
  bool _cloudSaved = false;

  @override
  void initState() {
    super.initState();
    _checkCloudStatus();
  }

  Future<void> _checkCloudStatus() async {
    try {
      final status = await widget.repository.transport.session();
      if (mounted &&
          status['account'] == widget.repository.account &&
          status['cloudRecoverySaved'] == true) {
        setState(() => _cloudSaved = true);
      }
    } catch (_) {
      // Export remains available offline.
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Не удалось завершить действие. Попробуйте снова.')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.repository.accountSnapshot!;
    return Scaffold(
      appBar: AppBar(title: const Text('Восстановление доступа')),
      body: FutureBuilder<String?>(
        future: _phrase,
        builder: (context, value) {
          if (value.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (value.hasError) {
            return const Center(
                child: Text('Не удалось открыть защищённое хранилище.'));
          }
          final phrase = value.data;
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(_cloudSaved
                  ? 'Зашифрованная копия сохранена на сервере Shade. Для восстановления после входа через Google введите пароль, который задали, или прежнюю фразу.'
                  : 'Копию можно загрузить на сервер Shade или скачать как файл. Храните пароль или прежнюю фразу отдельно.'),
              const SizedBox(height: 16),
              if (phrase != null) ...[
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() => _revealed = !_revealed),
                  child: Text(_revealed ? 'Скрыть фразу' : 'Показать фразу'),
                ),
                if (_revealed) ...[
                  SelectableText(phrase, textAlign: TextAlign.center),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                              await Clipboard.setData(
                                  ClipboardData(text: phrase));
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text('Фраза скопирована')),
                                );
                              }
                            }),
                    child: const Text('Скопировать фразу'),
                  ),
                ],
                const SizedBox(height: 12),
              ],
              if (!_cloudSaved && snapshot['genesis']['legacy'] == false)
                FilledButton.icon(
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                            await widget.repository.saveCloudRecoveryBackup();
                            if (mounted) setState(() => _cloudSaved = true);
                          }),
                  icon: const Icon(Icons.cloud_upload_outlined),
                  label: const Text('Сохранить копию на сервере'),
                ),
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                          final saved =
                              await saveNativeRecoveryFile(jsonEncode({
                            'backup': snapshot['recovery'],
                            'genesis': snapshot['genesis'],
                          }));
                          if (mounted && saved) {
                            setState(() => _saved = true);
                          }
                        }),
                icon: const Icon(Icons.download_outlined),
                label: Text(_saved ? 'Файл сохранён' : 'Сохранить файл'),
              ),
              if (phrase != null) ...[
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Я сохранил фразу отдельно от файла'),
                  value: _confirmed,
                  onChanged: !_revealed || _busy
                      ? null
                      : (value) => setState(() => _confirmed = value ?? false),
                ),
                TextButton(
                  onPressed: (!_saved && !_cloudSaved) || !_confirmed || _busy
                      ? null
                      : () => _run(() async {
                            await _secret.complete();
                            if (context.mounted) Navigator.pop(context);
                          }),
                  child: const Text('Готово'),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

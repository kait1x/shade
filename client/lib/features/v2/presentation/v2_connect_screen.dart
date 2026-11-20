/// Экран подключения native v2: честное состояние без сессии/enrollment.
///
/// Подключение (Google/ключ v1) и enrollment переиспользуют существующий
/// проверенный AlphaV2Screen импортом; после возврата сессия восстанавливается
/// из долговечных ключей. Продакшн-UI enrollment — отдельная задача.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shade/core/services/device_v2/repository.dart';
import 'package:shade/core/services/device_v2/store.dart';
import 'package:shade/core/services/device_v2/transport.dart';
import 'package:shade/core/theme/shade_theme.dart';
import 'package:shade/core/widgets/shade_ui.dart';
import 'package:shade/features/auth/data/repositories/auth_notifier.dart'
    show cryptoServiceProvider, databaseServiceProvider;
import 'package:shade/features/devices/presentation/alpha_v2_screen.dart';
import 'package:shade/features/devices/presentation/recovery_screen.dart';

import 'v2_providers.dart';

class V2ConnectScreen extends ConsumerWidget {
  const V2ConnectScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(v2SessionProvider);
    final notifier = ref.read(v2SessionProvider.notifier);

    final String title;
    final String description;
    final IconData icon;
    switch (session.status) {
      case V2SessionStatus.needsEnrollment:
        icon = Icons.phonelink_lock_rounded;
        title = 'Требуется регистрация устройства';
        description =
            'Аккаунт @${session.account ?? ''} подключён. Завершите enrollment: исходный RSA подписывает genesis, recovery-ключ шифруется вашей фразой. Ключи и история v1 не изменяются.';
      case V2SessionStatus.error:
        icon = Icons.cloud_off_rounded;
        title = 'Не удалось открыть Shade v2';
        description = session.error ??
            'Сессия не восстановлена. Попробуйте ещё раз или подключите устройство заново.';
      default:
        icon = Icons.phonelink_rounded;
        title = 'Shade v2 не подключён';
        description = session.error ??
            'Подключите это устройство к alpha-процессу Shade: вход через Google или ключом v1. Локальные ключи и история остаются на устройстве.';
    }

    return Scaffold(
        appBar: AppBar(title: const Text('Shade')),
        body: SingleChildScrollView(
            child: ShadeEmptyState(
                icon: icon,
                title: title,
                description: description,
                action: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FilledButton.icon(
                          key: const Key('v2-connect-open'),
                          onPressed: () async {
                            await Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                    builder: (_) => const AlphaV2Screen()));
                            await notifier.refresh();
                          },
                          icon: const Icon(Icons.login_rounded),
                          label: Text(session.status ==
                                  V2SessionStatus.needsEnrollment
                              ? 'Продолжить регистрацию'
                              : 'Подключить устройство')),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                          onPressed: notifier.refresh,
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('Повторить')),
                      const SizedBox(height: 12),
                      // Восстановление при утрате всех устройств: пакет +
                      // recovery-фраза заменяют enrollment. Экран самодостаточен
                      // параметром repository; после успеха сессия фиксируется
                      // и стек восстанавливается через refresh().
                      OutlinedButton.icon(
                          key: const Key('v2-connect-recovery'),
                          onPressed: () => _openRecovery(context, ref),
                          icon: const Icon(Icons.settings_backup_restore_rounded),
                          label: const Text('Восстановить с recovery-пакетом')),
                      const SizedBox(height: 12),
                      // Продакшн-мастер переноса v1→v2: та же личность,
                      // локальный импорт истории; недоставленное остаётся в v1.
                      OutlinedButton.icon(
                          key: const Key('v2-connect-enrollment'),
                          onPressed: () => context.push('/enrollment'),
                          icon: const Icon(Icons.move_down_rounded),
                          label: const Text('Перенести аккаунт из Shade v1')),
                    ]))));
  }

  Future<void> _openRecovery(BuildContext context, WidgetRef ref) async {
    final notifier = ref.read(v2SessionProvider.notifier);
    var repository = notifier.repository;
    // Собственный транспорт создаётся только при отсутствии стека; после
    // возврата он освобождается (успех поднимет новый стек через refresh()).
    final owned = repository == null;
    repository ??= await _buildRecoveryRepository(context, ref);
    if (repository == null || !context.mounted) return;
    final done = await Navigator.of(context).push<bool>(MaterialPageRoute(
        builder: (_) => NativeRecoveryScreen(repository: repository!)));
    if (owned) repository.transport.dispose();
    if (done == true) await notifier.refresh();
  }

  /// Репозиторий для восстановления: подключённый стек, либо долговечные
  /// origin/account/cookie (как restore()), либо явно указанный origin —
  /// recovery-сессия не требует Google-входа.
  Future<V2ChatRepository?> _buildRecoveryRepository(
      BuildContext context, WidgetRef ref) async {
    final prefs = await SharedPreferences.getInstance();
    var origin = prefs.getString('alpha_v2_origin');
    if (!context.mounted) return null;
    if (origin == null || origin.isEmpty) {
      origin = await _askOrigin(context);
      if (origin == null || origin.isEmpty) return null;
    }
    try {
      final crypto = ref.read(cryptoServiceProvider);
      final transport = AlphaTransport(origin, crypto);
      const secure = FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true));
      transport.sessionCookie = await secure.read(key: 'alpha_v2_cookie');
      return V2ChatRepository.pairing(
          transport: transport,
          crypto: crypto,
          store: V2Store(ref.read(databaseServiceProvider)),
          account: prefs.getString('alpha_v2_account') ?? '');
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Неверный адрес alpha-сервера: нужен https (или http localhost для отладки).')));
      }
      return null;
    }
  }

  Future<String?> _askOrigin(BuildContext context) async {
    final controller = TextEditingController(text: 'https://');
    final origin = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
            backgroundColor: ShadeColors.surfaceCard,
            title: const Text('Адрес alpha-сервера',
                style: TextStyle(color: ShadeColors.textPrimary, fontSize: 17)),
            content: TextField(
                controller: controller,
                autofocus: true,
                style: const TextStyle(color: ShadeColors.textPrimary),
                decoration: const InputDecoration(
                    labelText: 'Origin', hintText: 'https://alpha.example.com')),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Отмена')),
              TextButton(
                  onPressed: () => Navigator.pop(ctx, controller.text.trim()),
                  child: const Text('Продолжить')),
            ]));
    controller.dispose();
    return origin;
  }
}
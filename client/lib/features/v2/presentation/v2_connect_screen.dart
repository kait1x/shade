/// Экран подключения native v2: честное состояние без сессии/enrollment.
///
/// Подключение (Google/ключ v1) и enrollment переиспользуют существующий
/// проверенный AlphaV2Screen импортом; после возврата сессия восстанавливается
/// из долговечных ключей. Продакшн-UI enrollment — отдельная задача.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:shade/core/widgets/shade_ui.dart';
import 'package:shade/features/devices/presentation/alpha_v2_screen.dart';

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
                    ]))));
  }
}
/// Экран подключения native v2: честное состояние без сессии/enrollment.
///
/// Подключение (Google/ключ v1) и enrollment переиспользуют существующий
/// проверенный AlphaV2Screen импортом; после возврата сессия восстанавливается
/// из долговечных ключей. Продакшн-UI enrollment — отдельная задача.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shade/core/services/device_v2/repository.dart';
import 'package:shade/core/services/device_v2/store.dart';
import 'package:shade/core/services/device_v2/transport.dart';
import 'package:shade/core/theme/shade_theme.dart';
import 'package:shade/core/widgets/shade_welcome.dart';
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

    final failed = session.status == V2SessionStatus.error;

    return ShadeWelcomeLayout(
      fillScreen: true,
      card: (compact) => [
        Text(failed ? 'Не удалось открыть чаты' : 'Давайте познакомимся',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 7),
        Text(
          failed
              ? 'Проверьте подключение и попробуйте снова.'
              : 'Войдите через Google. Если вы здесь впервые, выберите никнейм после входа.',
          style: TextStyle(
              color: context.shadeColor(ShadeColors.textSecondary),
              fontSize: 12,
              height: 1.5),
        ),
        SizedBox(height: compact ? 10 : 16),
        ShadeGoogleButton(
          key: const Key('v2-connect-open'),
          onPressed: () async {
            await Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => const AlphaV2Screen(startWithGoogle: true),
            ));
            if (context.mounted) await notifier.refresh();
          },
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          key: const Key('v2-connect-recovery'),
          onPressed: () => _openRecovery(context, ref),
          icon: const Icon(Icons.key_rounded, size: 18),
          label: const Text('Восстановить доступ'),
        ),
        if (failed)
          TextButton(
              onPressed: notifier.refresh, child: const Text('Повторить')),
      ],
      footer: [
        Container(
          decoration: BoxDecoration(
            color: context.shadeColor(ShadeColors.surfaceCard),
            border:
                Border.all(color: context.shadeColor(ShadeColors.greyBorder)),
            borderRadius: BorderRadius.circular(16),
          ),
          child: ExpansionTile(
            leading: Icon(Icons.shield_outlined,
                size: 20, color: context.shadeColor(ShadeColors.textSecondary)),
            title: Text('Как используется Google-аккаунт',
                style: TextStyle(
                    fontSize: 12,
                    color: context.shadeColor(ShadeColors.textSecondary))),
            dense: true,
            shape: Border(),
            collapsedShape: Border(),
            childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              Text(
                  'Google подтверждает аккаунт. Ключи шифрования переписки создаются на устройстве.',
                  style: TextStyle(
                      fontSize: 12,
                      color: context.shadeColor(ShadeColors.textSecondary),
                      height: 1.6)),
            ],
          ),
        ),
      ],
    );
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
    final origin =
        prefs.getString('alpha_v2_origin') ?? AlphaV2Screen.defaultOrigin;
    if (!context.mounted) return null;
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
                'Не удалось открыть восстановление. Проверьте подключение и попробуйте снова.')));
      }
      return null;
    }
  }
}

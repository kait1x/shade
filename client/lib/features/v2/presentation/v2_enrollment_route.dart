/// Точка входа enrollment-мастера native v2: backend собирается из долговечной
/// v1-идентичности (профиль SQLCipher + ключи Keystore), мастер импортирует
/// историю локально; после успеха сессия v2 восстанавливается штатно.
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
import 'package:shade/core/widgets/shade_motion.dart';
import 'package:shade/features/auth/data/repositories/auth_notifier.dart'
    show cryptoServiceProvider, databaseServiceProvider;
import 'package:shade/features/devices/presentation/enrollment_screen.dart';

import 'v2_providers.dart';

class V2EnrollmentRoute extends ConsumerStatefulWidget {
  const V2EnrollmentRoute({super.key});

  @override
  ConsumerState<V2EnrollmentRoute> createState() => _V2EnrollmentRouteState();
}

class _V2EnrollmentRouteState extends ConsumerState<V2EnrollmentRoute> {
  EnrollmentBackend? _backend;
  AlphaTransport? _owned;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final origin = prefs.getString('alpha_v2_origin') ?? '';
      final database = ref.read(databaseServiceProvider);
      final crypto = ref.read(cryptoServiceProvider);
      final profile = await database.getCurrentUserProfile();
      final nickname = (profile?['nickname'] as String?) ?? '';
      if (!mounted) return;
      if (origin.isEmpty || nickname.isEmpty) {
        setState(() {
          _loading = false;
          _error = origin.isEmpty
              ? 'Сначала укажите адрес сервера на экране подключения.'
              : 'На устройстве нет профиля Shade v1: переносить нечего. '
                  'Зарегистрируйтесь или войдите в Shade v2.';
        });
        return;
      }
      final transport = AlphaTransport(origin, crypto);
      const secure = FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true));
      transport.sessionCookie = await secure.read(key: 'alpha_v2_cookie');
      final root = (profile?['public_key'] as String?) ??
          await crypto.getPublicKey() ??
          '';
      final privateKey = await crypto.getPrivateKey() ?? '';
      final repository = V2ChatRepository(
          transport: transport,
          crypto: crypto,
          store: V2Store(database),
          account: nickname,
          root: root,
          privateKey: privateKey);
      if (!mounted) {
        transport.dispose();
        return;
      }
      setState(() {
        _owned = transport;
        _backend = RepositoryEnrollmentBackend(
            repository: repository,
            transport: transport,
            crypto: crypto,
            database: database);
        _loading = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Не удалось подготовить перенос: $error';
        });
      }
    }
  }

  @override
  void dispose() {
    _owned?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(body: Center(child: ShadeLoadingIndicator()));
    }
    if (_error != null) {
      return Scaffold(
          appBar: AppBar(title: const Text('Перенос из Shade v1')),
          body: Center(
              child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: context
                              .shadeColor(ShadeColors.textSecondary))))));
    }
    return EnrollmentScreen(
        backend: _backend!,
        onFinished: () async {
          await ref.read(v2SessionProvider.notifier).refresh();
          if (context.mounted) context.go('/');
        });
  }
}

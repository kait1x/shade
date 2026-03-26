import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shade/core/services/crypto_service.dart';
import 'package:shade/core/services/connection_service.dart';
import 'package:shade/core/services/notification_service.dart';
import 'package:shade/core/database/database_service.dart';

/// Authentication state
enum AuthStatus {
  initial,
  generatingKeys,
  authenticated,
  error,
}

/// Auth state holder
class AuthState {
  final AuthStatus status;
  final String? nickname;
  final String? publicKey;
  final int? userId;
  final String? error;

  const AuthState({
    this.status = AuthStatus.initial,
    this.nickname,
    this.publicKey,
    this.userId,
    this.error,
  });

  AuthState copyWith({
    AuthStatus? status,
    String? nickname,
    String? publicKey,
    int? userId,
    String? error,
  }) {
    return AuthState(
      status: status ?? this.status,
      nickname: nickname ?? this.nickname,
      publicKey: publicKey ?? this.publicKey,
      userId: userId ?? this.userId,
      error: error ?? this.error,
    );
  }
}

/// Auth notifier for managing authentication state and logic
class AuthNotifier extends StateNotifier<AuthState> {
  final CryptoService _cryptoService;
  final DatabaseService _databaseService;
  final ConnectionService _connectionService;

  AuthNotifier(
    this._cryptoService,
    this._databaseService,
    this._connectionService,
  ) : super(const AuthState()) {
    _restoreSession();
  }

  /// Automatically restores the previous session on first build.
  Future<void> _restoreSession() async {
    try {
      final restored = await checkExistingProfile();
      if (!restored && state.status == AuthStatus.initial) {
        // No profile — just go to welcome, no error
        state = state.copyWith(status: AuthStatus.error);
      }
    } catch (e) {
      state = state.copyWith(
        status: AuthStatus.error,
        error: 'Ошибка запуска: $e',
      );
    }
  }

  /// Generates identity keys, registers on server, and saves user profile.
  Future<bool> createSecureProfile(String nickname) async {
    try {
      state = state.copyWith(status: AuthStatus.generatingKeys);
      debugPrint('[Auth] Generating keys...');

      // Generate 4096-bit RSA key pair
      final keys = await _cryptoService.generateIdentityKeys();
      final publicKey = keys['publicKey']!;
      debugPrint('[Auth] Keys generated');

      // Save profile to encrypted database
      final userId =
          await _databaseService.saveUserProfile(nickname, publicKey);
      debugPrint('[Auth] Profile saved, userId=$userId');

      // Register on relay server (signs the key automatically)
      try {
        debugPrint('[Auth] Registering on server...');
        await _connectionService.register(nickname);
        debugPrint('[Auth] Registered, connecting...');
        _connectionService.connect(nickname);
        debugPrint('Registered and connected to server');

        // Initialize notifications (local + FCM)
        await NotificationService.init();
        await NotificationService.registerToken(
          _connectionService.serverUrl,
          nickname,
        );
      } catch (e) {
        final errorStr = e.toString();
        debugPrint('[Auth] Register error: $errorStr');
        if (errorStr.contains('Username already taken') ||
            errorStr.contains('409') ||
            errorStr.contains('Никнейм уже занят')) {
          state = state.copyWith(
            status: AuthStatus.error,
            error: 'Этот никнейм уже занят. Выберите другой.',
          );
          return false;
        }
        // Server registration is non-fatal — local E2EE still works
        debugPrint('Server registration skipped: $e');
      }

      state = state.copyWith(
        status: AuthStatus.authenticated,
        nickname: nickname,
        publicKey: publicKey,
        userId: userId,
      );

      // Set flag for fast startup
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('has_profile', true);

      debugPrint('Secure profile created');
      return true;
    } catch (e) {
      state = state.copyWith(
        status: AuthStatus.error,
        error: e.toString(),
      );
      debugPrint('Error creating secure profile: $e');
      return false;
    }
  }

  /// Checks if user already has a profile and reconnects to server.
  Future<bool> checkExistingProfile() async {
    final hasProfileInDb = await _databaseService.hasUserProfile();
    if (hasProfileInDb) {
      // Set flag for fast startup on next launch
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('has_profile', true);

      final profile = await _databaseService.getCurrentUserProfile();
      final publicKey = await _cryptoService.getPublicKey();

      if (profile != null && publicKey != null) {
        final nickname = profile['nickname'] as String;
        final userId = profile['id'] as int;

        // Reconnect to server in background
        // Always connect even if register fails (user already exists)
        try {
          await _connectionService.register(nickname).catchError((e) {
            debugPrint('Register skipped (already exists): $e');
          });
        } catch (_) {}

        _connectionService.connect(nickname);
        await NotificationService.init();
        await NotificationService.registerToken(
          _connectionService.serverUrl,
          nickname,
        );
        debugPrint('Reconnected to server');

        state = state.copyWith(
          status: AuthStatus.authenticated,
          nickname: nickname,
          publicKey: publicKey,
          userId: userId,
        );
        return true;
      }
    }
    return false;
  }

  /// Account is permanently bound to device — logout is disabled.
}

/// Provider for CryptoService
final cryptoServiceProvider = Provider<CryptoService>((ref) {
  return CryptoService();
});

/// Provider for DatabaseService
final databaseServiceProvider = Provider<DatabaseService>((ref) {
  return DatabaseService();
});

/// Provider for AuthNotifier
final authNotifierProvider =
    StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  final cryptoService = ref.watch(cryptoServiceProvider);
  final databaseService = ref.watch(databaseServiceProvider);
  final connectionService = ref.watch(connectionServiceProvider);
  return AuthNotifier(cryptoService, databaseService, connectionService);
});

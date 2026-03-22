import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:shade/core/services/crypto_service.dart';
import 'package:shade/core/services/connection_service.dart';
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
  final String? error;

  const AuthState({
    this.status = AuthStatus.initial,
    this.nickname,
    this.publicKey,
    this.error,
  });

  AuthState copyWith({
    AuthStatus? status,
    String? nickname,
    String? publicKey,
    String? error,
  }) {
    return AuthState(
      status: status ?? this.status,
      nickname: nickname ?? this.nickname,
      publicKey: publicKey ?? this.publicKey,
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
    await checkExistingProfile();
  }

  /// Generates identity keys, registers on server, and saves user profile.
  Future<bool> createSecureProfile(String nickname) async {
    try {
      state = state.copyWith(status: AuthStatus.generatingKeys);

      // Generate 4096-bit RSA key pair
      final keys = await _cryptoService.generateIdentityKeys();
      final publicKey = keys['publicKey']!;

      // Save profile to encrypted database
      await _databaseService.saveUserProfile(nickname, publicKey);

      // Register on relay server (signs the key automatically)
      try {
        await _connectionService.register(nickname);
        _connectionService.connect(nickname);
        debugPrint('Registered and connected to server as: $nickname');
      } catch (e) {
        final errorStr = e.toString();
        if (errorStr.contains('Username already taken') ||
            errorStr.contains('409')) {
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
      );

      debugPrint('Secure profile created for: $nickname');
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
    final hasProfile = await _databaseService.hasUserProfile();
    if (hasProfile) {
      final profile = await _databaseService.getCurrentUserProfile();
      final publicKey = await _cryptoService.getPublicKey();

      if (profile != null && publicKey != null) {
        final nickname = profile['nickname'] as String;

        // Reconnect to server in background
        try {
          _connectionService.register(nickname).then((_) {
            _connectionService.connect(nickname);
            debugPrint('Reconnected to server as: $nickname');
          }).catchError((e) {
            debugPrint('Server reconnect skipped: $e');
          });
        } catch (_) {}

        state = state.copyWith(
          status: AuthStatus.authenticated,
          nickname: nickname,
          publicKey: publicKey,
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
final authNotifierProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  final cryptoService = ref.watch(cryptoServiceProvider);
  final databaseService = ref.watch(databaseServiceProvider);
  final connectionService = ref.watch(connectionServiceProvider);
  return AuthNotifier(cryptoService, databaseService, connectionService);
});

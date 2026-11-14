import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
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
  final String? email;
  final String? displayName;
  final String? avatarUrl;

  const AuthState({
    this.status = AuthStatus.initial,
    this.nickname,
    this.publicKey,
    this.userId,
    this.error,
    this.email,
    this.displayName,
    this.avatarUrl,
  });

  AuthState copyWith({
    AuthStatus? status,
    String? nickname,
    String? publicKey,
    int? userId,
    String? error,
    String? email,
    String? displayName,
    String? avatarUrl,
  }) {
    return AuthState(
      status: status ?? this.status,
      nickname: nickname ?? this.nickname,
      publicKey: publicKey ?? this.publicKey,
      userId: userId ?? this.userId,
      error: error,
      email: email ?? this.email,
      displayName: displayName ?? this.displayName,
      avatarUrl: avatarUrl ?? this.avatarUrl,
    );
  }
}

/// Auth notifier for managing authentication state and logic
class AuthNotifier extends StateNotifier<AuthState> {
  final CryptoService _cryptoService;
  final DatabaseService _databaseService;
  final ConnectionService _connectionService;
  int _authEpoch = 0;

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
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('signed_out') == true) {
        final profile = await _databaseService.getCurrentUserProfile();
        state = AuthState(
            status: AuthStatus.error,
            nickname: profile?['nickname'] as String?);
        return;
      }
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

  static Future<void>? _googleInit;

  /// Google establishes the account identity; the relay validates its ID token.
  /// Private encryption keys stay on this installation, independently of Google.
  Future<bool> createSecureProfile(String nickname) async {
    final epoch = ++_authEpoch;
    try {
      state = state.copyWith(status: AuthStatus.generatingKeys);
      const clientId = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');
      if (clientId.isEmpty) {
        throw StateError(
            'Google-вход ещё не настроен: нужен OAuth Web Client ID.');
      }
      final previous = await _databaseService.getCurrentUserProfile();
      if (previous != null && previous['nickname'] != nickname) {
        throw StateError(
            'На устройстве уже есть профиль @${previous['nickname']}. Используйте этот никнейм, чтобы сохранить историю.');
      }
      _googleInit ??=
          GoogleSignIn.instance.initialize(serverClientId: clientId);
      await _googleInit;
      final account = await GoogleSignIn.instance.authenticate();
      final idToken = account.authentication.idToken;
      if (idToken == null) {
        throw StateError(
            'Google не вернул ID token. Проверьте OAuth-настройки APK.');
      }
      var publicKey = await _cryptoService.getPublicKey();
      publicKey ??= (await _cryptoService.generateIdentityKeys())['publicKey']!;
      // Save an authenticated profile only AFTER server validation succeeds.
      final profile =
          await _connectionService.register(nickname, googleIdToken: idToken);
      if (!mounted || epoch != _authEpoch) return false;
      final userId = await _databaseService.saveUserProfile(nickname, publicKey,
          profile: profile);
      if (!mounted || epoch != _authEpoch) return false;
      _connectionService.connect(nickname);
      state = AuthState(
          status: AuthStatus.authenticated,
          nickname: nickname,
          publicKey: publicKey,
          userId: userId,
          email: profile['email'] as String?,
          displayName: profile['displayName'] as String?,
          avatarUrl: profile['avatarUrl'] as String?);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('has_profile', true);
      await prefs.setBool('signed_out', false);
      try {
        await NotificationService.init();
        await NotificationService.registerToken(_connectionService.serverUrl,
            nickname, _connectionService.sessionToken);
      } catch (e) {
        debugPrint('Notifications unavailable: $e');
      }
      return true;
    } on GoogleSignInException catch (e) {
      state = state.copyWith(
          status: AuthStatus.error,
          error: e.code == GoogleSignInExceptionCode.canceled
              ? 'Вход отменён. Можно попробовать снова.'
              : 'Google-вход недоступен. Проверьте сеть и настройки OAuth.');
      return false;
    } catch (e) {
      state = state.copyWith(status: AuthStatus.error, error: e.toString());
      return false;
    }
  }

  /// Checks if user already has a profile and reconnects to server.
  Future<bool> checkExistingProfile() async {
    final epoch = _authEpoch;
    final hasProfileInDb = await _databaseService.hasUserProfile();
    if (!mounted || epoch != _authEpoch) return false;
    if (hasProfileInDb) {
      // Set flag for fast startup on next launch
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('has_profile', true);

      final profile = await _databaseService.getCurrentUserProfile();
      final publicKey = await _cryptoService.getPublicKey();

      if (!mounted || epoch != _authEpoch) return false;
      if (profile != null && publicKey != null) {
        final nickname = profile['nickname'] as String;
        final userId = profile['id'] as int;

        // Cached history is immediately available even without a network.
        state = AuthState(
            status: AuthStatus.authenticated,
            nickname: nickname,
            userId: userId,
            publicKey: publicKey,
            email: profile['email'] as String?,
            displayName: profile['display_name'] as String?,
            avatarUrl: profile['avatar_url'] as String?);
        // Reconnect to server in background
        // Always connect even if register fails (user already exists)
        try {
          await _connectionService.register(nickname);
        } catch (_) {}

        if (!mounted || epoch != _authEpoch) return false;
        _connectionService.connect(nickname);
        try {
          await NotificationService.init();
        } catch (_) {}
        await NotificationService.registerToken(
          _connectionService.serverUrl,
          nickname,
          _connectionService.sessionToken,
        );
        debugPrint('Reconnected to server');

        if (!mounted || epoch != _authEpoch) return false;
        state = state.copyWith(
          status: AuthStatus.authenticated,
          nickname: nickname,
          publicKey: publicKey,
          userId: userId,
          email: profile['email'] as String?,
          displayName: profile['display_name'] as String?,
          avatarUrl: profile['avatar_url'] as String?,
        );
        return true;
      }
    }
    return false;
  }

  /// Sign out preserves the device's private keys and encrypted history.
  /// Deleting an identity is a separate destructive action, not ordinary logout.
  Future<void> logout() async {
    _authEpoch++;
    final nickname = state.nickname;
    await NotificationService.unregisterToken(
        _connectionService.serverUrl, nickname);
    await _connectionService.signOut();
    if (_googleInit != null) {
      try {
        await GoogleSignIn.instance.signOut();
      } catch (_) {}
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('signed_out', true);
    try {
      await NotificationService.dispose();
    } catch (_) {}
    state = AuthState(status: AuthStatus.error, nickname: nickname);
  }

  /// Check if server key needs user confirmation (TOFU)
  Future<ServerKeyFingerprintResult?> checkServerKeyConfirmation() async {
    return await _connectionService.checkServerKeyForConfirmation();
  }

  /// Trust the server key after user confirms
  Future<void> trustServerKey(String fingerprint) async {
    await _connectionService.trustServerKey(fingerprint);
  }
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

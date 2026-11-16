import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shade/core/services/connection_service.dart';
import 'package:shade/features/auth/data/repositories/auth_notifier.dart';

import 'package:shade/core/widgets/avatar_frame.dart';
export 'package:shade/core/widgets/avatar_frame.dart';

class AvatarProfile {
  final Uint8List? image;
  final String? imageUrl;
  final String displayName;
  final AvatarFrame frame;
  final int revision;
  const AvatarProfile(
      {this.image,
      this.imageUrl,
      required this.displayName,
      this.frame = AvatarFrame.none,
      this.revision = 0});
  factory AvatarProfile.fromJson(Map<String, dynamic> data) => AvatarProfile(
      image: data['image'] is String ? base64Decode(data['image']) : null,
      imageUrl: data['imageUrl'] as String?,
      displayName: data['displayName'] as String? ?? '',
      frame: AvatarFrame.values.firstWhere((v) => v.name == data['frame'],
          orElse: () => AvatarFrame.none),
      revision: data['revision'] as int? ?? 0);
}

final avatarProfileProvider = StateNotifierProvider.autoDispose
    .family<AvatarController, AsyncValue<AvatarProfile>, String>(
        (ref, username) {
  final conn = ref.watch(connectionServiceProvider);
  // Recreate private in-memory state when the signed-in account changes.
  final authUser = ref.watch(authNotifierProvider.select((s) => s.nickname));
  final controller = AvatarController(conn, username,
      currentOwner: () => authUser ?? conn.profileOwner,
      readCache: (owner) => ref
          .read(databaseServiceProvider)
          .readAvatarProfile(owner, conn.serverUrl, username),
      writeCache: (owner, data) => ref
          .read(databaseServiceProvider)
          .cacheAvatarProfile(owner, conn.serverUrl, username, data));
  conn.retainProfile(username);
  final updates = conn.avatarUpdates
      .where((n) => n == username)
      .listen((_) => controller.load());
  final reconnect = conn.connectionChanges
      .where((online) => online)
      .listen((_) => controller.load());
  ref.onDispose(() {
    updates.cancel();
    reconnect.cancel();
    conn.releaseProfile(username);
  });
  return controller;
});

class AvatarController extends StateNotifier<AsyncValue<AvatarProfile>> {
  final ConnectionService conn;
  final String username;
  final String? Function()? currentOwner;
  final Future<Map<String, dynamic>?> Function(String) readCache;
  final Future<void> Function(String, Map<String, dynamic>) writeCache;
  int _epoch = 0;
  bool _saving = false;
  bool _reloadAfterSave = false;
  AvatarController(this.conn, this.username,
      {required this.readCache, required this.writeCache, this.currentOwner})
      : super(const AsyncLoading()) {
    unawaited(load());
  }

  Future<void> load() async {
    if (_saving) {
      _reloadAfterSave = true;
      return;
    }
    final epoch = ++_epoch, owner = currentOwner?.call() ?? conn.profileOwner;
    if (!state.hasValue && owner != null) {
      try {
        final cached = await readCache(owner);
        if (!mounted || epoch != _epoch) return;
        if (cached != null) state = AsyncData(AvatarProfile.fromJson(cached));
      } catch (_) {/* Cache failure must not prevent fetching the profile. */}
    }
    try {
      final data = await conn.profileRequest(
          'GET', '/user/${Uri.encodeComponent(username)}/avatar');
      if (!mounted || epoch != _epoch) return;
      state = AsyncData(AvatarProfile.fromJson(data));
      final cacheOwner = currentOwner?.call() ?? conn.profileOwner;
      if (cacheOwner != null) {
        try {
          await writeCache(cacheOwner, data);
        } catch (_) {/* Readable for this session. */}
      }
    } catch (e, st) {
      if (mounted && epoch == _epoch && !state.hasValue) {
        state = AsyncError(e, st);
      }
    }
  }

  Future<void> save(
      {required int revision,
      required AvatarFrame frame,
      bool replaceImage = false,
      Uint8List? image,
      void Function(double)? onProgress}) async {
    if (_saving) throw StateError('Сохранение уже выполняется');
    _saving = true;
    ++_epoch; // A slower pre-save fetch must never put the old photo back.
    final owner = conn.profileOwner;
    try {
      final data = await conn.saveAvatarProfile({
        'revision': revision,
        'frame': frame.name,
        if (replaceImage) 'image': image == null ? null : base64Encode(image),
      }, onProgress: onProgress);
      if (!mounted) return;
      state = AsyncData(AvatarProfile.fromJson(data));
      if (owner != null && conn.profileOwner == owner) {
        try {
          await writeCache(owner, data);
        } catch (_) {/* Server commit succeeded. */}
      }
    } catch (_) {
      // Resolve timeouts/conflicts against server state; the editor keeps its draft.
      _saving = false;
      await load();
      rethrow;
    } finally {
      _saving = false;
      if (_reloadAfterSave && mounted) {
        _reloadAfterSave = false;
        unawaited(load());
      }
    }
  }
}

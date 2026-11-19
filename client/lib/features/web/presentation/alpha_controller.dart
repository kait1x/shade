import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:shade/core/widgets/avatar_frame.dart';

/// Presentation-only projection. The existing JS client owns keys, encrypted
/// storage, transport, queue and recipient acknowledgements.
class AlphaController extends ChangeNotifier {
  AlphaController(this.dispatch);
  final Future<Object?> Function(String action, Map<String, dynamic> payload)
      dispatch;
  Uint8List? _avatarBytes;
  String _avatarDigest = '';
  final Map<String, (String, Uint8List?)> _peerAvatars = {};
  Map<String, dynamic> data = {};
  String get account => data['account'] as String? ?? '';
  String? get selected => data['selected'] as String?;
  String get connection => data['connection'] as String? ?? 'Переподключение…';
  bool get connected => data['connected'] == true;
  List<Map<String, dynamic>> get peers => _maps(data['peers']);
  List<Map<String, dynamic>> get messages => _maps(data['messages']);
  List<Map<String, dynamic>> get devices => _maps(data['devices']);
  Map<String, dynamic> get notes =>
      Map<String, dynamic>.from(data['notes'] as Map? ?? {});
  Map<String, dynamic> get profile =>
      Map<String, dynamic>.from(data['profile'] as Map? ?? {});
  // Key card presentation data (public material): identicon seed + genesis
  // digest, projected by alpha-ui.mjs; null until the vault is unlocked.
  Map<String, dynamic>? get key =>
      data['key'] == null ? null : Map<String, dynamic>.from(data['key'] as Map);
  String get platform => data['platform'] as String? ?? 'desktop';
  // Populates only when the relay starts returning the Google email in
  // /api/session (server-side gap tracked for Qwen).
  String? get email => data['email'] as String?;
  Map<String, dynamic> get typing =>
      Map<String, dynamic>.from(data['typing'] as Map? ?? {});
  Map<String, dynamic> get presence =>
      Map<String, dynamic>.from(data['presence'] as Map? ?? {});
  String peerName(String account) {
    if (account == this.account) return 'Избранное';
    final peer = peers
        .where((p) => p['account'] == account)
        .map((p) => p['name'] as String?)
        .firstWhere((name) => name != null && name.isNotEmpty, orElse: () => null);
    return peer ?? account;
  }

  Future<void> act(String action, [Map<String, dynamic> payload = const {}]) =>
      dispatch(action, payload);
  // Avatar bytes travel on demand, keyed by the projected digest, so the
  // base64 image is not re-sent with every snapshot.
  Future<Uint8List?> avatarImage(String digest) async {
    if (digest.isEmpty) return null;
    if (_avatarDigest == digest && _avatarBytes != null) return _avatarBytes;
    final result = (await dispatch('profile.avatar', const {})) as Map?;
    final image = result?['image'] as String?;
    _avatarDigest = digest;
    _avatarBytes = image == null ? null : base64Decode(image);
    return _avatarBytes;
  }

  // Peer avatars resolve through the v2 profile adapter, cached per account
  // and keyed by the projected digest.
  Future<Uint8List?> peerAvatarBytes(String account, String digest) async {
    if (digest.isEmpty) return null;
    final cached = _peerAvatars[account];
    if (cached != null && cached.$1 == digest) return cached.$2;
    final result = (await dispatch('peer.avatar', {'account': account})) as Map?;
    final image = result?['image'] as String?;
    final bytes = image == null ? null : base64Decode(image);
    _peerAvatars[account] = (digest, bytes);
    return bytes;
  }

  AvatarFrame? peerFrame(String account) {
    final digest = _peerAvatars[account]?.$1;
    if (digest == null || digest.isEmpty) return null;
    return AvatarFrame.values.firstWhere(
        (f) => f.name == (peers
                .where((p) => p['account'] == account)
                .map((p) => p['frame'] as String?)
                .firstWhere((f) => f != null, orElse: () => null) ??
            'none'),
        orElse: () => AvatarFrame.none);
  }
  Map<String, dynamic> get positions =>
      Map<String, dynamic>.from(data['positions'] as Map? ?? {});
  Map<String, dynamic> get readUntil =>
      Map<String, dynamic>.from(data['readUntil'] as Map? ?? {});
  static List<Map<String, dynamic>> _maps(dynamic value) =>
      (value as List? ?? [])
          .map((v) => Map<String, dynamic>.from(v as Map))
          .toList();
  void apply(Map<String, dynamic> value) {
    data = value;
    notifyListeners();
  }

  List<Map<String, dynamic>> conversation(String peer) => messages
      .where((m) => peer == account
          // Favorites (self-chat): only messages addressed to yourself.
          ? (m['from'] == peer && m['to'] == peer)
          : (m['from'] == peer || m['to'] == peer))
      .toList()
    ..sort((a, b) => (a['createdAt'] as num).compareTo(b['createdAt'] as num));
  int unread(String peer) => conversation(peer)
      .where((m) =>
          m['from'] == peer &&
          (m['createdAt'] as num) > ((readUntil[peer] as num?) ?? 0))
      .length;
  bool pinned(String peer) =>
      peers.any((p) => p['account'] == peer && p['pinned'] == true);
  // TOFU-контакт закреплён автоматически, но отпечаток ещё не сверен вручную.
  bool unverified(String peer) =>
      peers.any((p) => p['account'] == peer && p['unverified'] == true);
  static int acknowledgements(Map<String, dynamic> m) =>
      _maps(m['devices']).where((d) => d['acknowledgedAt'] != null).length;
  static int reads(Map<String, dynamic> m) =>
      _maps(m['devices']).where((d) => d['readAt'] != null).length;
  static String status(Map<String, dynamic> m) {
    if (reads(m) > 0) return 'read';
    return acknowledgements(m) > 0
        ? 'delivered'
        : switch (m['status']) {
            'queued' => 'queued',
            'blocked' => 'blocked',
            _ => 'sent'
          };
  }
  static String delivery(Map<String, dynamic> m) {
    if (m['status'] == 'received') {
      return m['readAt'] != null ? 'Прочитано' : 'Получено на это устройство';
    }
    final confirmed = acknowledgements(m), total = _maps(m['devices']).length;
    final read = reads(m);
    if (confirmed > 0) {
      if (read > 0) return 'Прочитано: $read/$total устройств';
      return 'Доставлено: $confirmed/$total устройств';
    }
    return switch (m['status']) {
      'queued' => 'В очереди на этом устройстве',
      'accepted' => 'На сервере · ожидает ACK устройства',
      'blocked' => 'Отправка заблокирована · сохранено для проверки',
      _ => 'Ожидает подтверждения',
    };
  }
}

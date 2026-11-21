import 'package:flutter/foundation.dart';

/// Presentation-only projection. The existing JS client owns keys, encrypted
/// storage, transport, queue and recipient acknowledgements.
class AlphaController extends ChangeNotifier {
  AlphaController(this.dispatch);
  final Future<void> Function(String action, Map<String, dynamic> payload)
      dispatch;
  Map<String, dynamic> data = {};
  String get account => data['account'] as String? ?? '';
  String? get selected => data['selected'] as String?;
  String get connection => data['connection'] as String? ?? 'Переподключение…';
  bool get connected => data['connected'] == true;
  List<Map<String, dynamic>> get peers => _maps(data['peers']);
  List<Map<String, dynamic>> get messages => _maps(data['messages']);
  List<Map<String, dynamic>> get devices => _maps(data['devices']);
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

  Future<void> act(String action, [Map<String, dynamic> payload = const {}]) =>
      dispatch(action, payload);
  List<Map<String, dynamic>> conversation(String peer) => messages
      .where((m) => m['from'] == peer || m['to'] == peer)
      .toList()
    ..sort((a, b) => (a['createdAt'] as num).compareTo(b['createdAt'] as num));
  int unread(String peer) => conversation(peer)
      .where((m) =>
          m['from'] == peer &&
          (m['createdAt'] as num) > ((readUntil[peer] as num?) ?? 0))
      .length;
  bool pinned(String peer) =>
      peers.any((p) => p['account'] == peer && p['pinned'] == true);
  static int acknowledgements(Map<String, dynamic> m) =>
      _maps(m['devices']).where((d) => d['acknowledgedAt'] != null).length;
  static String status(Map<String, dynamic> m) => acknowledgements(m) > 0
      ? 'delivered'
      : switch (m['status']) {
          'queued' => 'queued',
          'blocked' => 'blocked',
          _ => 'sent'
        };
  static String delivery(Map<String, dynamic> m) {
    if (m['status'] == 'received') return 'Получено на это устройство';
    final confirmed = acknowledgements(m);
    if (confirmed > 0) {
      return 'Доставлено: $confirmed/${_maps(m['devices']).length} устройств';
    }
    return switch (m['status']) {
      'queued' => 'В очереди на этом устройстве',
      'accepted' => 'На сервере · ожидает ACK устройства',
      'blocked' => 'Отправка заблокирована · сохранено для проверки',
      _ => 'Ожидает подтверждения',
    };
  }
}

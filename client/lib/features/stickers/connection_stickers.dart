import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shade/core/services/connection_service.dart';
import 'repository.dart';

/// v1 sticker backend: session-header transport over the encrypted profile
/// store on the relay. Native clients only — the web build must not import
/// this file (see repository.dart for the transport-agnostic seam).
class StickerRepository implements StickerBackend {
  final ConnectionService conn;
  StickerRepository(this.conn);
  @override
  Future<Collection> load(String name, bool owner) async =>
      Collection(await conn.profileRequest(
          'GET',
          owner
              ? '/stickers/inventory'
              : '/user/${Uri.encodeComponent(name)}/stickers'));
  @override
  Future<Map<String, dynamic>> save(int rev, List<Placement> wall) =>
      conn.profileRequest('PUT', '/stickers/wall', {
        'revision': rev,
        'wall': [for (var i = 0; i < wall.length; i++) wall[i].json(i)]
      });
  @override
  Future<void> gift(
      String to, String art, String note, String requestId) async {
    await conn.profileRequest('POST', '/stickers/gift', {
      'toUsername': to,
      'stickerId': art,
      'note': note,
      'requestId': requestId
    });
  }
}

final stickerRepository =
    Provider((ref) => StickerRepository(ref.watch(connectionServiceProvider)));

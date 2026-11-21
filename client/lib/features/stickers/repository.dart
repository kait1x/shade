import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shade/core/services/connection_service.dart';

class Gift {
  final String id, art;
  final String? from, note;
  Gift(Map data)
      : id = data['giftId'],
        art = data['stickerId'],
        from = data['fromUsername'],
        note = data['note'];
}

class Placement {
  final String id;
  double x, y, rotation, scale;
  Placement(this.id,
      {this.x = .5, this.y = .5, this.rotation = 0, this.scale = 1});
  factory Placement.parse(Map m) => Placement(m['giftId'],
      x: m['xNorm'].toDouble(),
      y: m['yNorm'].toDouble(),
      rotation: m['rotation'].toDouble(),
      scale: m['scale'].toDouble());
  Map<String, dynamic> json(int z) => {
        'giftId': id,
        'xNorm': x,
        'yNorm': y,
        'rotation': rotation,
        'scale': scale,
        'zIndex': z
      };
}

class Collection {
  final int revision;
  final List<Gift> gifts;
  final List<Placement> wall;
  Collection(Map m)
      : revision = m['revision'],
        gifts = [for (final g in m['inventory']) Gift(g)],
        wall = [
          for (final p
              in (List.of(m['wall'])
                ..sort((a, b) => a['zIndex'].compareTo(b['zIndex']))))
            Placement.parse(p)
        ];
}

final stickerRepository =
    Provider((ref) => StickerRepository(ref.watch(connectionServiceProvider)));

class StickerRepository {
  final ConnectionService conn;
  StickerRepository(this.conn);
  Future<Collection> load(String name, bool owner) async =>
      Collection(await conn.profileRequest(
          'GET',
          owner
              ? '/stickers/inventory'
              : '/user/${Uri.encodeComponent(name)}/stickers'));
  Future<Map<String, dynamic>> save(int rev, List<Placement> wall) =>
      conn.profileRequest('PUT', '/stickers/wall', {
        'revision': rev,
        'wall': [for (var i = 0; i < wall.length; i++) wall[i].json(i)]
      });
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

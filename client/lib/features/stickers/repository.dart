// Transport-agnostic sticker models and the backend seam. The v1
// ConnectionService implementation lives in connection_stickers.dart; the web
// alpha provides its own adapter. No dart:io may be imported here: the whole
// rendering stack is shared with the Flutter web build.
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

/// Data seam for the sticker collection. Implementations provide the account
/// binding and transport (v1 session headers today; a device-v2 contract is
/// pending for the web alpha).
abstract interface class StickerBackend {
  Future<Collection> load(String name, bool owner);
  Future<Map<String, dynamic>> save(int rev, List<Placement> wall);
  Future<void> gift(String to, String art, String note, String requestId);
}

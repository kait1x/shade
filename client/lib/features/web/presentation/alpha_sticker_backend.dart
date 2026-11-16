import 'package:shade/features/stickers/repository.dart';
import 'alpha_controller.dart';

/// Alpha sticker adapter over the encrypted local state. The wall, its 32
/// placements and revisions are real and stored locally; GIFTS are blocked
/// until the device-v2 contract adds a sticker exchange (parity matrix),
/// so `load(name, owner: false)` and `gift()` fail with honest errors
/// instead of pretending to work.
class AlphaStickerBackend implements StickerBackend {
  final AlphaController controller;
  AlphaStickerBackend(this.controller);
  @override
  Future<Collection> load(String name, bool owner) async {
    final result =
        (await controller.dispatch('stickers.load', {'name': name, 'owner': owner})) as Map?;
    if (result == null) throw StateError('Не удалось загрузить подарки');
    return Collection(Map<String, dynamic>.from(result));
  }

  @override
  Future<Map<String, dynamic>> save(int rev, List<Placement> wall) async {
    final result = (await controller.dispatch('stickers.save', {
      'revision': rev,
      'wall': [for (var i = 0; i < wall.length; i++) wall[i].json(i)]
    })) as Map?;
    if (result == null) throw StateError('Не удалось сохранить стену');
    return Map<String, dynamic>.from(result);
  }

  @override
  Future<void> gift(String to, String art, String note, String requestId) =>
      Future.error(StateError(
          'Подарки недоступны в Web Alpha: нужен device-v2 API для обмена наклейками'));
}

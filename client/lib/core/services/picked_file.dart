import 'dart:typed_data';

/// Результат выбора файла recovery-пакета. Собственный тип вместо зависимости
/// file_picker: Android-выбор реализован platform channel'ом в MainActivity
/// (ACTION_OPEN_DOCUMENT), что убирает сторонний плагин из нативной сборки.
class PickedFile {
  final String name;
  final int size;
  final Uint8List? bytes;
  final String? path;

  const PickedFile({required this.name, required this.size, this.bytes, this.path});
}
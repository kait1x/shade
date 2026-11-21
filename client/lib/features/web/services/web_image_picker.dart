import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';
import 'package:web/web.dart' as web;

// package:web's FileList has no List conversion; the stock plugin keeps the
// same helper private, so mirror it here.
extension _FileListToDart on web.FileList {
  List<web.File> get toList => <web.File>[
        for (int i = 0; i < length; i++) item(i)!,
      ];
}

/// Web image picker that reads the picked file into memory at pick time.
///
/// The stock image_picker_for_web wraps the picked File in a blob: URL and
/// XFile.readAsBytes() later re-fetches it with an XMLHttpRequest. On Android
/// Chrome PWA that XHR can fail before any upload happens ('Could not load
/// Blob from its URL. Has it been revoked?'). The plugin's canvas-resize path
/// (imageQuality/maxWidth) does not fix this: its output is another blob-URL
/// XFile without cached bytes, and any resize error silently falls back to
/// the original file.
///
/// Reading through FileReader while the input element is still attached and
/// returning XFile.fromData caches the bytes-backed Blob inside the XFile, so
/// every later readAsBytes()/length() is served from memory — no blob XHR is
/// ever performed. Registered only in the web entrypoint (main_alpha.dart);
/// native platforms keep the stock plugin.
class ShadeWebImagePicker extends ImagePickerPlatform {
  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async {
    final capture = source == ImageSource.camera
        ? (options.preferredCameraDevice == CameraDevice.front
            ? 'user'
            : 'environment')
        : null;
    final files = await _pick(accept: 'image/*', capture: capture);
    return files.isEmpty ? null : files.first;
  }

  Future<List<XFile>> _pick({required String accept, String? capture}) {
    final input = web.HTMLInputElement()
      ..type = 'file'
      ..accept = accept
      ..style.display = 'none';
    if (capture != null) input.setAttribute('capture', capture);
    final completer = Completer<List<XFile>>();
    input.onchange = (web.Event _) {
      final selected = input.files?.toList ?? <web.File>[];
      debugPrint('shade: web pick change: ${selected.length} files');
      unawaited(() async {
        try {
          final files = <XFile>[];
          for (final file in selected) {
            files.add(await _read(file));
          }
          debugPrint('shade: web pick complete: ${files.length}');
          if (!completer.isCompleted) completer.complete(files);
        } catch (e, st) {
          debugPrint('shade: web pick read failed: $e');
          if (!completer.isCompleted) completer.completeError(e, st);
        } finally {
          input.remove();
        }
      }());
    }.toJS;
    input.oncancel = (web.Event _) {
      debugPrint('shade: web pick cancel');
      if (!completer.isCompleted) completer.complete(<XFile>[]);
      input.remove();
    }.toJS;
    input.onerror = (web.Event _) {
      debugPrint('shade: web pick input error');
      if (!completer.isCompleted) {
        completer.completeError(const FormatException(
            'Не удалось открыть галерею. Попробуйте ещё раз.'));
      }
      input.remove();
    }.toJS;
    web.document.body!.append(input);
    input.click();
    return completer.future;
  }

  Future<XFile> _read(web.File file) async {
    final reader = web.FileReader()..readAsArrayBuffer(file);
    await reader.onLoadEnd.first;
    final bytes = (reader.result as JSArrayBuffer?)?.toDart.asUint8List();
    if (bytes == null) {
      throw const FormatException(
          'Не удалось прочитать выбранный файл. Попробуйте ещё раз.');
    }
    return XFile.fromData(bytes,
        name: file.name,
        mimeType: file.type.isEmpty ? null : file.type,
        length: file.size,
        lastModified: DateTime.fromMillisecondsSinceEpoch(file.lastModified));
  }
}
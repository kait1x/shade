// @dart=3.3
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'features/web/presentation/alpha_controller.dart';
import 'features/web/presentation/alpha_app.dart';

@JS('shadeAction')
external JSPromise<JSString> _action(JSString action, JSString payload);
@JS('shadeReceive')
external set _receive(JSFunction callback);

@JS('fetch')
external JSPromise<_FontResponse> _fetch(JSString url);
@JS()
extension type _FontResponse(JSObject _) implements JSObject {
  external bool get ok;
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final response =
      await _fetch('/flutter-ui/fonts/NotoColorEmoji.ttf'.toJS).toDart;
  if (!response.ok) {
    throw StateError('Не удалось загрузить локальный шрифт Shade');
  }
  final bytes = (await response.arrayBuffer().toDart).toDart;
  await (FontLoader('ShadeEmoji')..addFont(Future.value(ByteData.view(bytes))))
      .load();
  // Accessible DOM also makes browser verification exercise the real controls.
  SemanticsBinding.instance.ensureSemantics();
  final controller = AlphaController((action, payload) async {
    final result = jsonDecode(
        (await _action(action.toJS, jsonEncode(payload).toJS).toDart)
            .toDart) as Map<String, dynamic>;
    if (result['ok'] != true) {
      throw StateError(result['error'] as String? ?? 'Операция не выполнена');
    }
    // Actions may return data (e.g. profile.avatar) alongside the status.
    return result['data'];
  });
  _receive = ((JSString snapshot) {
    controller.apply(jsonDecode(snapshot.toDart) as Map<String, dynamic>);
  }).toJS;
  runApp(ShadeAlphaApp(controller: controller));
  controller.act('ready');
}

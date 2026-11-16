// Regenerates every iOS AppIcon PNG from the 1024 source icon.
// Needed because this repo ships without ios/Runner.xcodeproj, so
// flutter_launcher_icons can update Android but not iOS assets.
// Run from client/:  dart run tools/generate_ios_icons.dart
import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;

void main() {
  const appicon = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
  final source = img.decodePng(
      File('$appicon/../../../../assets/icon.png').readAsBytesSync());
  if (source == null) {
    stderr.writeln('cannot decode assets/icon.png');
    exit(1);
  }
  final manifest =
      jsonDecode(File('$appicon/Contents.json').readAsStringSync())
          as Map<String, dynamic>;
  var count = 0;
  for (final entry in manifest['images'] as List) {
    final name = entry['filename'] as String;
    final size = double.parse((entry['size'] as String).split('x').first);
    final scale = int.parse((entry['scale'] as String).replaceAll('x', ''));
    final px = (size * scale).round();
    var icon = img.copyResize(source, width: px, height: px,
        interpolation: img.Interpolation.cubic);
    // App Store marketing icon must be opaque.
    for (final p in icon.data!) {
      p.a = 255;
    }
    File('$appicon/$name').writeAsBytesSync(img.encodePng(icon));
    count++;
    stdout.writeln('$name -> ${px}px');
  }
  stdout.writeln('done: $count icons');
}

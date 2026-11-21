import 'dart:io';

import 'main_native.dart' as legacy;
import 'main_native_v2.dart' as v2;

void main() {
  if (Platform.isAndroid) {
    v2.main();
  } else {
    legacy.main();
  }
}

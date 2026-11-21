// Keep native-only storage and networking out of the browser dependency graph.
import 'main_native.dart' if (dart.library.js_interop) 'main_web.dart'
    as platform;
export 'main_native.dart' if (dart.library.js_interop) 'main_web.dart';
export 'core/theme/shade_theme.dart';

void main() => platform.main();

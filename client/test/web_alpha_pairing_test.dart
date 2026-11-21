import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shade/features/web/presentation/alpha_app.dart';
import 'package:shade/features/web/presentation/alpha_controller.dart';

// Second-device pairing entry points in the projection. The actual pairing
// logic (challenge/offer/confirmation, keys, install) lives in the JS client;
// the Flutter layer only opens the DOM dialog via `devices.pair`.
void main() {
  testWidgets('Profile screen offers adding a device and dispatches devices.pair',
      (tester) async {
    Map<String, dynamic>? paired;
    final c = AlphaController((action, payload) async {
      if (action == 'devices.pair') paired = {...payload};
      return null;
    });
    c.apply(<String, dynamic>{
      'account': 'alice',
      'connected': true,
      'peers': <Map<String, dynamic>>[],
      'messages': <Map<String, dynamic>>[],
      'devices': <Map<String, dynamic>>[
        {'id': 'a' * 64, 'current': true},
        {'id': 'b' * 64, 'current': false},
      ],
    });
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Профиль'));
    await tester.pumpAndSettle();
    // The devices card sits far down the lazily-built profile list.
    await tester.dragUntilVisible(
        find.text('Добавить устройство'), find.byType(ListView).first,
        const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(find.text('Добавить устройство'), findsOneWidget);
    expect(find.text('Этот браузер'), findsOneWidget);
    expect(find.text('Устройство'), findsOneWidget);
    await tester.tap(find.text('Добавить устройство'));
    await tester.pumpAndSettle();
    expect(paired, isNotNull);
    c.dispose();
  });

  testWidgets('Devices card renders the add-device entry with no devices yet',
      (tester) async {
    final c = AlphaController((action, payload) async => null);
    c.apply(<String, dynamic>{
      'account': 'alice',
      'connected': true,
      'peers': <Map<String, dynamic>>[],
      'messages': <Map<String, dynamic>>[],
      'devices': <Map<String, dynamic>>[],
    });
    await tester.pumpWidget(ShadeAlphaApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Профиль'));
    await tester.pumpAndSettle();
    await tester.dragUntilVisible(
        find.text('Добавить устройство'), find.byType(ListView).first,
        const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(find.text('Добавить устройство'), findsOneWidget);
    c.dispose();
  });
}

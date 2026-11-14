import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shade/core/database/database_service.dart';
import 'package:shade/features/auth/data/repositories/auth_notifier.dart';
import 'package:shade/features/auth/presentation/screens/welcome_screen.dart';

class EmptyProfileDatabase extends DatabaseService {
  @override
  Future<bool> hasUserProfile() async => false;
}

void main() {
  testWidgets(
      'Google welcome validates nickname and reports missing OAuth configuration',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(ProviderScope(overrides: [
      databaseServiceProvider.overrideWithValue(EmptyProfileDatabase()),
    ], child: const MaterialApp(home: WelcomeScreen())));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('google-sign-in')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('google-sign-in')));
    await tester.pumpAndSettle();
    expect(find.text('От 3 до 32 символов: a–z, 0–9 и _'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('nickname')), 'alice');
    await tester.ensureVisible(find.byKey(const Key('google-sign-in')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('google-sign-in')));
    await tester.pumpAndSettle();
    expect(find.textContaining('нужен OAuth Web Client ID'), findsOneWidget);
  });
}

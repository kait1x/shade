import 'package:flutter_test/flutter_test.dart';
import 'package:shade/main.dart';

void main() {
  testWidgets('Shade app smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const ShadeApp());

    expect(find.text('Shade'), findsOneWidget);
  });
}

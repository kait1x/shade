import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shade/features/chats/presentation/widgets/message_bubble.dart';

void main() {
  testWidgets('shows an overview and opens the map for a location message',
      (tester) async {
    var opened = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageBubble(
          text: '📍 Геопозиция\n55.75583, 37.61730',
          timestamp: DateTime(2026),
          isMine: false,
          isEncrypted: true,
          onOpenLocation: () => opened = true,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Геопозиция на обзорной карте'), findsOneWidget);
    final map = tester.widget<Image>(find.byType(Image));
    expect((map.image as AssetImage).assetName, 'assets/maps/world.png');
    await tester.tap(find.text('Открыть карту'));
    expect(opened, isTrue);
  });
}

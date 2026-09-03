import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/features/auth/update_screen.dart';

void main() {
  testWidgets('explains the forced update and offers the Play listing',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: UpdateScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Je potřeba aktualizace'), findsOneWidget);
    expect(find.textContaining('novější server'), findsOneWidget);
    expect(find.text('Otevřít Google Play'), findsOneWidget);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/features/schedule/widgets/group_booking_dialog.dart';

void main() {
  Future<String?> open(WidgetTester tester, {String? pick}) async {
    String? result = 'unset';
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await showGroupBookingDialog(
            context,
            message: 'čtvrtek 24. 9. · 17:30 · Dráha 2',
            meId: 'me',
            mates: const [(id: 'jana', name: 'Jana Nová')],
          ),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Pro koho'), findsOneWidget);
    if (pick != null) {
      await tester.tap(find.text(pick));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Rezervovat'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('"Já" is the default', (tester) async {
    expect(await open(tester), 'me');
  });

  testWidgets('a mate can be chosen', (tester) async {
    expect(await open(tester, pick: 'Jana Nová'), 'jana');
  });

  testWidgets('Zrušit books nobody', (tester) async {
    String? result = 'unset';
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await showGroupBookingDialog(
            context,
            message: 'x',
            meId: 'me',
            mates: const [(id: 'jana', name: 'Jana Nová')],
          ),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zrušit'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
}

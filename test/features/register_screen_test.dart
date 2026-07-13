import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/auth/register_screen.dart';

void main() {
  Widget app(List<Tenant> tenants) => ProviderScope(
        overrides: [
          tenantsProvider.overrideWith((ref) async => tenants),
        ],
        child: const MaterialApp(home: RegisterScreen()),
      );

  const two = [
    Tenant(id: 't1', name: 'Kuželna č. 1'),
    Tenant(id: 't2', name: 'Kuželna Vracov'),
  ];

  testWidgets('registration requires picking an alley when several exist', (
    tester,
  ) async {
    await tester.pumpWidget(app(two));
    await tester.pumpAndSettle();

    expect(find.text('Kuželna'), findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextField, 'Jméno a příjmení'), 'Jan Novák');
    await tester.tap(find.text('Zaregistrovat se'));
    await tester.pump();

    // Blocked before any RPC: no tenant picked yet.
    expect(find.text('Vyber kuželnu.'), findsOneWidget);

    // The dropdown lists both alleys.
    await tester.tap(find.text('Kuželna'));
    await tester.pumpAndSettle();
    expect(find.text('Kuželna č. 1'), findsWidgets);
    expect(find.text('Kuželna Vracov'), findsWidgets);
  });

  testWidgets('a single alley preselects silently', (tester) async {
    await tester.pumpWidget(app(const [Tenant(id: 't1', name: 'Kuželna č. 1')]));
    await tester.pumpAndSettle();

    // The lone alley shows as the dropdown's value without any tap.
    expect(find.text('Kuželna č. 1'), findsOneWidget);
  });
}

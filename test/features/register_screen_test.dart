import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/auth/register_screen.dart';

void main() {
  Widget app(List<Tenant> tenants,
      {Map<String, List<Club>> clubs = const {}}) {
    return ProviderScope(
      overrides: [
        tenantsProvider.overrideWith((ref) async => tenants),
        registrationClubsProvider.overrideWith(
            (ref, tenantId) async => clubs[tenantId] ?? const <Club>[]),
      ],
      child: const MaterialApp(home: RegisterScreen()),
    );
  }

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

    // The dropdown lists both alleys plus the found-a-new-one entry.
    await tester.tap(find.text('Kuželna'));
    await tester.pumpAndSettle();
    expect(find.text('Kuželna č. 1'), findsWidgets);
    expect(find.text('Kuželna Vracov'), findsWidgets);
    expect(find.text('➕ Založit novou kuželnu'), findsWidgets);
  });

  testWidgets('a single alley preselects silently', (tester) async {
    await tester.pumpWidget(app(const [Tenant(id: 't1', name: 'Kuželna č. 1')]));
    await tester.pumpAndSettle();

    // The lone alley shows as the dropdown's value without any tap.
    expect(find.text('Kuželna č. 1'), findsOneWidget);
  });

  testWidgets('founding a new alley reveals its name field and requires it', (
    tester,
  ) async {
    await tester.pumpWidget(app(two));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Kuželna'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('➕ Založit novou kuželnu').last);
    await tester.pumpAndSettle();

    expect(find.text('Název nové kuželny'), findsOneWidget);
    expect(find.text('Staneš se jejím správcem.'), findsOneWidget);

    await tester.enterText(
        find.widgetWithText(TextField, 'Jméno a příjmení'), 'Jan Novák');
    await tester.tap(find.text('Zaregistrovat se'));
    await tester.pump();
    expect(find.text('Napiš název nové kuželny.'), findsOneWidget);
  });

  testWidgets('an existing alley with clubs offers a club dropdown '
      '(with "Bez oddílu"); a clubless alley hides it', (tester) async {
    await tester.pumpWidget(app(two, clubs: {
      't1': const [
        Club(id: 'c1', name: 'TJ Sokol'),
        Club(id: 'c2', name: 'KK Vracov'),
      ],
    }));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Kuželna'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kuželna č. 1').last);
    await tester.pumpAndSettle();

    expect(find.text('Oddíl / klub'), findsOneWidget);
    await tester.tap(find.text('Oddíl / klub'));
    await tester.pumpAndSettle();
    expect(find.text('Bez oddílu'), findsWidgets);
    expect(find.text('TJ Sokol'), findsWidgets);
    expect(find.text('KK Vracov'), findsWidgets);

    // Close the dropdown, switch to the clubless alley — no club picker.
    await tester.tap(find.text('Bez oddílu').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kuželna'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kuželna Vracov').last);
    await tester.pumpAndSettle();
    expect(find.text('Oddíl / klub'), findsNothing);
  });

  testWidgets('the nick field caps input at 14 characters', (tester) async {
    await tester.pumpWidget(app(two));
    await tester.pumpAndSettle();

    final nickField =
        find.widgetWithText(TextField, 'Přezdívka na tabuli (nepovinné)');
    expect(nickField, findsOneWidget);
    await tester.enterText(nickField, 'Příliš dlouhá přezdívka');
    expect(
      tester.widget<TextField>(nickField).controller!.text.length,
      lessThanOrEqualTo(14),
    );
  });
}

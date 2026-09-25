import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/auth/register_screen.dart';

void main() {
  /// What the screen sent, one line per backend call.
  late List<String> calls;
  setUp(() => calls = []);

  Widget app(List<Tenant> tenants,
      {Map<String, List<Club>> clubs = const {}}) {
    return ProviderScope(
      overrides: [
        tenantsProvider.overrideWith((ref) async => tenants),
        registrationClubsProvider.overrideWith(
            (ref, tenantId) async => clubs[tenantId] ?? const <Club>[]),
      ],
      child: MaterialApp(
        home: RegisterScreen(
          registerProfile: (name, tenantId, {clubId, nick = '', phone}) async =>
              calls.add('register $name|$tenantId|$clubId|$nick|$phone'),
          createTenantAndRegister: (tenantName, name,
                  {nick = '', phone}) async =>
              calls.add('found $tenantName|$name|$nick|$phone'),
        ),
      ),
    );
  }

  /// Scrolls to „Zaregistrovat se" and taps it: the form is taller than the
  /// test viewport.
  Future<void> submit(WidgetTester tester) async {
    await tester.ensureVisible(find.text('Zaregistrovat se'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zaregistrovat se'));
  }

  const phoneLabel = 'Telefon (nepovinné)';
  const phoneError = 'Telefon nemá správný tvar — třeba +420 777 123 456.';

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
    await submit(tester);
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
    // The phone field pushed the button below the fold of the test screen.
    await submit(tester);
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

  testWidgets('the phone field says who sees the number and where to hide it',
      (tester) async {
    await tester.pumpWidget(app(const [Tenant(id: 't1', name: 'Kuželna č. 1')]));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.widgetWithText(TextField, phoneLabel),
        matching: find.text('Uvidí ho ostatní hráči kuželny v Kontaktech. '
            'Skrýt ho můžeš v Můj profil.'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the phone is optional: without one nothing is sent for it',
      (tester) async {
    await tester.pumpWidget(app(const [Tenant(id: 't1', name: 'Kuželna č. 1')]));
    await tester.pumpAndSettle();

    final field = find.widgetWithText(TextField, phoneLabel);
    expect(field, findsOneWidget);
    expect(tester.widget<TextField>(field).keyboardType, TextInputType.phone);

    await tester.enterText(
        find.widgetWithText(TextField, 'Jméno a příjmení'), 'Jan Novák');
    await submit(tester);
    await tester.pumpAndSettle();

    expect(calls, ['register Jan Novák|t1|null||null']);
  });

  testWidgets('an invalid phone is refused inline and nothing is sent; '
      'typing again clears the message', (tester) async {
    await tester.pumpWidget(app(const [Tenant(id: 't1', name: 'Kuželna č. 1')]));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, 'Jméno a příjmení'), 'Jan Novák');
    await tester.enterText(find.widgetWithText(TextField, phoneLabel), '12345');
    await submit(tester);
    await tester.pumpAndSettle();

    expect(find.text(phoneError), findsOneWidget);
    expect(calls, isEmpty);

    await tester.ensureVisible(find.widgetWithText(TextField, phoneLabel));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, phoneLabel), '777 123 45');
    // The error cross-fades back to the helper text.
    await tester.pumpAndSettle();
    expect(find.text(phoneError), findsNothing);
  });

  testWidgets('a valid phone is sent normalised to register_profile',
      (tester) async {
    await tester.pumpWidget(app(const [Tenant(id: 't1', name: 'Kuželna č. 1')]));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, 'Jméno a příjmení'), 'Jan Novák');
    await tester.enterText(
        find.widgetWithText(TextField, 'Přezdívka na tabuli (nepovinné)'),
        'Honza');
    await tester.enterText(
        find.widgetWithText(TextField, phoneLabel), '777 123 456');
    await submit(tester);
    await tester.pumpAndSettle();

    expect(calls, ['register Jan Novák|t1|null|Honza|+420777123456']);
  });

  testWidgets('a founder\'s phone goes normalised with the founding, in the '
      'same call', (tester) async {
    await tester.pumpWidget(app(two));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Kuželna'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('➕ Založit novou kuželnu').last);
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, 'Název nové kuželny'), 'Kuželna Nová');
    await tester.enterText(
        find.widgetWithText(TextField, 'Jméno a příjmení'), 'Jan Novák');
    await tester.enterText(
        find.widgetWithText(TextField, phoneLabel), '+49 30 1234567');
    await submit(tester);
    await tester.pumpAndSettle();

    expect(calls, ['found Kuželna Nová|Jan Novák||+49301234567']);
  });
}

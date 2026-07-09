import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/admin/overrides_screen.dart';

void main() {
  const admin = Profile(
    id: 'admin1',
    displayName: 'Správce',
    club: '',
    email: 'admin@example.com',
    role: Role.admin,
    status: ProfileStatus.approved,
  );

  Widget app() {
    return ProviderScope(
      overrides: [
        myProfileProvider.overrideWith((ref) => Stream.value(admin)),
        dayOverridesProvider.overrideWith((ref) => Stream.value(const [])),
        timeBlocksProvider.overrideWith((ref) => Stream.value(const [])),
      ],
      child: const MaterialApp(
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: [Locale('cs'), Locale('en')],
        home: OverridesScreen(),
      ),
    );
  }

  Future<void> openDialogWithDate(WidgetTester tester) async {
    await tester.tap(find.text('Přidat výjimku'));
    await tester.pumpAndSettle();
    // Date picker opens pre-selected on today; OK confirms it.
    await tester.tap(find.text('Vybrat'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
  }

  testWidgets('closure dialog only offers a reason (no custom-times mode)', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Přidat výjimku'));
    await tester.pumpAndSettle();

    expect(find.text('Důvod (zavřeno)'), findsOneWidget);
    // The removed slot-shift / custom-times affordances are gone.
    expect(find.text('Otevřeno — vlastní časy'), findsNothing);
    expect(find.text('Přidat čas'), findsNothing);
  });

  testWidgets('saving a closure without a reason is rejected', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await openDialogWithDate(tester);

    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();

    expect(find.text('Vyplň důvod.'), findsOneWidget);
    // Dialog stays open — never reached Api.setDayOverride.
    expect(find.byType(AlertDialog), findsOneWidget);
  });
}

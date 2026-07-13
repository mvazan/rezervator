import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/ui.dart' show today;
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

  Widget app({
    List<DayOverride> overrides = const [],
    List<TimeBlock> blocks = const [],
  }) {
    return ProviderScope(
      overrides: [
        myProfileProvider.overrideWith((ref) => Stream.value(admin)),
        dayOverridesProvider.overrideWith((ref) => Stream.value(overrides)),
        timeBlocksProvider.overrideWith((ref) => Stream.value(blocks)),
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

  testWidgets('past closures collapse behind Minulé, upcoming stay visible',
      (tester) async {
    final now = today();
    await tester.pumpWidget(app(overrides: [
      DayOverride(
          date: now.addDays(3), closed: true, reason: 'Malování drah'),
      DayOverride(date: now.addDays(-3), closed: true, reason: 'Revize'),
      DayOverride(date: now.addDays(-10), closed: true, reason: 'Turnaj'),
    ]));
    await tester.pumpAndSettle();

    // Upcoming closure listed directly; past ones only behind the tile.
    expect(find.text('Zavřeno — Malování drah'), findsOneWidget);
    expect(find.text('Minulé (2)'), findsOneWidget);
    expect(find.text('Zavřeno — Revize'), findsNothing);

    await tester.tap(find.text('Minulé (2)'));
    await tester.pumpAndSettle();
    expect(find.text('Zavřeno — Revize'), findsOneWidget);
    expect(find.text('Zavřeno — Turnaj'), findsOneWidget);
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

  testWidgets('day-scoped schedule forks list under Jednodenní změny with '
      'block labels, specials marked, and an undo affordance', (tester) async {
    const template = TimeBlock(
      id: 'b1',
      startsAt: HourMinute(16, 0),
      endsAt: HourMinute(17, 0),
      position: 0,
      active: true,
    );
    const special = TimeBlock(
      id: 'sp1',
      startsAt: HourMinute(17, 30),
      endsAt: HourMinute(18, 30),
      position: -1,
      active: false,
    );
    final future = today().addDays(2);
    await tester.pumpWidget(app(
      blocks: const [template, special],
      overrides: [
        DayOverride(
            date: future,
            closed: false,
            reason: '',
            blockIds: const ['b1', 'sp1']),
      ],
    ));
    await tester.pumpAndSettle();

    expect(find.text('Jednodenní změny rozvrhu'), findsOneWidget);
    expect(
      find.textContaining('(jen tento den)'),
      findsOneWidget,
    );
    expect(find.byTooltip('Vrátit den k týdennímu rozvrhu'), findsOneWidget);
  });
}

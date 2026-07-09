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

  // Two active blocks that overlap each other (09:00-10:30 and 10:00-11:00)
  // — _OverrideDialogState._pickDate prefills `_rows` from exactly the
  // day's effective blocks (all active blocks, since the freshly-picked
  // date has no existing override), so picking any date auto-populates two
  // overlapping rows without this test needing to drive the time pickers
  // itself.
  const overlapping1 = TimeBlock(
    id: 'ov1',
    startsAt: HourMinute(9, 0),
    endsAt: HourMinute(10, 30),
    position: 0,
    active: true,
  );
  const overlapping2 = TimeBlock(
    id: 'ov2',
    startsAt: HourMinute(10, 0),
    endsAt: HourMinute(11, 0),
    position: 1,
    active: true,
  );

  Widget app() {
    return ProviderScope(
      overrides: [
        myProfileProvider.overrideWith((ref) => Stream.value(admin)),
        dayOverridesProvider.overrideWith((ref) => Stream.value(const [])),
        timeBlocksProvider.overrideWith(
          (ref) => Stream.value(const [overlapping1, overlapping2]),
        ),
      ],
      child: const MaterialApp(
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: [Locale('cs'), Locale('en')],
        home: OverridesScreen(),
      ),
    );
  }

  testWidgets(
    'overlapping rows are rejected on save with Časy se nesmí překrývat.',
    (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      // Open the add-override dialog.
      await tester.tap(find.text('Přidat výjimku'));
      await tester.pumpAndSettle();

      // Pick a date: the calendar date picker opens pre-selected on today
      // (the dialog's initial date), so confirming with OK is enough — no
      // need to actually change the selection.
      await tester.tap(find.text('Vybrat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      // Switch to "Otevřeno — vlastní časy", which prefills two rows from
      // the day's effective (active) blocks — overlapping1 and
      // overlapping2, which overlap each other.
      await tester.tap(find.text('Otevřeno — vlastní časy'));
      await tester.pumpAndSettle();

      // Two rows now show the prefilled overlapping times (HourMinute.display
      // pads only the minute, not the hour — "9:00", not "09:00").
      expect(find.text('9:00'), findsOneWidget);
      expect(find.text('10:30'), findsOneWidget);
      expect(find.text('10:00'), findsOneWidget);
      expect(find.text('11:00'), findsOneWidget);

      await tester.tap(find.text('Uložit'));
      await tester.pumpAndSettle();

      expect(find.text('Časy se nesmí překrývat.'), findsOneWidget);
      // The dialog stays open — save was rejected before ever reaching
      // Api.setDayOverride.
      expect(find.byType(AlertDialog), findsOneWidget);
    },
  );

  testWidgets(
    'tapping + 30 min fills the rows with default blocks shifted +30',
    (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Přidat výjimku'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Vybrat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Otevřeno — vlastní časy'));
      await tester.pumpAndSettle();

      // Prefilled from the default active blocks: 9:00-10:30, 10:00-11:00.
      expect(find.text('9:00'), findsOneWidget);

      await tester.tap(find.text('+ 30 min'));
      await tester.pumpAndSettle();

      // Rows are replaced with the default active blocks shifted +30:
      // 9:30-11:00, 10:30-11:30.
      expect(find.text('9:00'), findsNothing);
      expect(find.text('9:30'), findsOneWidget);
      expect(find.text('11:00'), findsOneWidget);
      expect(find.text('10:30'), findsOneWidget);
      expect(find.text('11:30'), findsOneWidget);
    },
  );
}

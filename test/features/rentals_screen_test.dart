import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/ui.dart' show today;
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/admin/rentals_screen.dart';

void main() {
  const admin = Profile(
    id: 'admin1',
    displayName: 'Správce',
    email: 'admin@example.com',
    role: Role.admin,
    status: ProfileStatus.approved,
  );
  // Two lanes, so the dialog's lane chips are predictable.
  const settings = ScheduleSettings(
    laneCount: 2,
    trainingWeekdays: {1, 2, 3, 4, 5, 6, 7},
    bookingHorizonDays: 14,
    maxActiveReservations: 3,
  );

  Widget app({List<Rental> rentals = const []}) {
    return ProviderScope(
      overrides: [
        myProfileProvider.overrideWith((ref) => Stream.value(admin)),
        rentalsProvider.overrideWith((ref) => Stream.value(rentals)),
        settingsProvider.overrideWith((ref) => Stream.value(settings)),
      ],
      child: const MaterialApp(home: RentalsScreen()),
    );
  }

  // One fixture per test: a second pumpWidget does not swap ProviderScope
  // overrides.
  testWidgets('lists one-time rentals before weekly ones, with lanes, '
      'validity and note', (tester) async {
    await tester.pumpWidget(app(rentals: [
      Rental(
        id: 'r-weekly',
        renterName: 'Firma Kolo',
        lanes: const [1, 2],
        date: null,
        weekday: DateTime.thursday,
        startsAt: const HourMinute(18, 0),
        endsAt: const HourMinute(20, 0),
        validFrom: Day(2026, 9, 1),
        validUntil: null,
        note: 'faktura měsíčně',
      ),
      Rental(
        id: 'r-once',
        renterName: 'Oslava Novákovi',
        lanes: const [2],
        date: today().addDays(5),
        weekday: null,
        startsAt: const HourMinute(15, 0),
        endsAt: const HourMinute(17, 0),
        validFrom: null,
        validUntil: null,
        note: '',
      ),
    ]));
    await tester.pumpAndSettle();

    expect(find.text('Pronájmy'), findsOneWidget);
    expect(find.text('Oslava Novákovi'), findsOneWidget);
    expect(find.text('Firma Kolo'), findsOneWidget);
    expect(find.textContaining('jednorázově'), findsOneWidget);
    expect(find.textContaining('každý čtvrtek 18:00–20:00'), findsOneWidget);
    expect(find.textContaining('dráhy 1, 2'), findsOneWidget);
    expect(find.textContaining('platí od út 1.9.'), findsOneWidget);
    expect(find.textContaining('faktura měsíčně'), findsOneWidget);

    // One-time first, weekly after.
    expect(
      tester.getTopLeft(find.text('Oslava Novákovi')).dy,
      lessThan(tester.getTopLeft(find.text('Firma Kolo')).dy),
    );
  });

  testWidgets('empty state', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Zatím žádné pronájmy.'), findsOneWidget);
    expect(find.text('Přidat pronájem'), findsOneWidget);
  });

  testWidgets("Přidat pronájem opens the rental dialog with the alley's lanes",
      (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Přidat pronájem'));
    await tester.pumpAndSettle();

    // The dialog's title (the FAB label underneath reads the same).
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Přidat pronájem'),
      ),
      findsOneWidget,
    );
    expect(find.text('Nájemce'), findsOneWidget);
    expect(find.text('Jednorázový'), findsOneWidget);
    expect(find.text('Týdenní'), findsOneWidget);
    expect(find.text('Dráha 1'), findsOneWidget);
    expect(find.text('Dráha 2'), findsOneWidget);
    expect(find.text('Dráha 3'), findsNothing);
    expect(find.text('Uložit'), findsOneWidget);
  });
}

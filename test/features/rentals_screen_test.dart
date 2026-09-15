import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/ui.dart' show dayFull, dayLabel, today;
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/labels.dart' show rentalMoreDatesLabel;
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

  // A Thursday series on both lanes, and exception rows hanging under it.
  final weekly = Rental(
    id: 'r-weekly',
    renterName: 'Firma Kolo',
    lanes: const [1, 2],
    date: null,
    weekday: DateTime.thursday,
    startsAt: const HourMinute(18, 0),
    endsAt: const HourMinute(20, 0),
    validFrom: null,
    validUntil: null,
    note: '',
  );
  // The series' next two dates (today counts when it is a Thursday).
  final firstThursday =
      today().addDays((DateTime.thursday - today().weekday + 7) % 7);
  final secondThursday = firstThursday.addDays(7);
  Rental exception({
    required String id,
    required Day date,
    bool skipped = false,
    List<int> lanes = const [1, 2],
  }) =>
      Rental(
        id: id,
        renterName: 'Firma Kolo',
        lanes: lanes,
        date: date,
        weekday: null,
        startsAt: const HourMinute(18, 0),
        endsAt: const HourMinute(20, 0),
        validFrom: null,
        validUntil: null,
        note: '',
        parentId: 'r-weekly',
        skipped: skipped,
      );
  final withExceptions = [
    weekly,
    exception(id: 'x-skip', date: firstThursday, skipped: true),
    exception(id: 'x-lane', date: secondThursday, lanes: const [1]),
  ];

  // A renter with three scattered dates in one group, and a lone one-off.
  Rental grouped({required String id, required Day date, List<int> lanes = const [1]}) =>
      Rental(
        id: id,
        renterName: 'Firma Trak',
        lanes: lanes,
        date: date,
        weekday: null,
        startsAt: const HourMinute(18, 0),
        endsAt: const HourMinute(20, 0),
        validFrom: null,
        validUntil: null,
        note: '',
        color: 3,
        groupId: 'g1',
      );
  final d1 = today().addDays(3);
  final d2 = today().addDays(9);
  final d3 = today().addDays(30);
  final lone = Rental(
    id: 'r-lone',
    renterName: 'Oslava Novákovi',
    lanes: const [1, 2],
    date: today().addDays(5),
    weekday: null,
    startsAt: const HourMinute(19, 0),
    endsAt: const HourMinute(22, 0),
    validFrom: null,
    validUntil: null,
    note: 'dort',
  );

  // One fixture per test: a second pumpWidget does not swap ProviderScope
  // overrides.
  testWidgets('series under Pravidelné, groups under Nepravidelné by next '
      'date, each tile with its dates and lanes', (tester) async {
    await tester.pumpWidget(app(rentals: [
      weekly,
      grouped(id: 'g1-c', date: d3, lanes: const [3]),
      grouped(id: 'g1-a', date: d1),
      grouped(id: 'g1-b', date: d2, lanes: const [1, 2]),
      lone,
    ]));
    await tester.pumpAndSettle();

    expect(find.text('Pravidelné'), findsOneWidget);
    expect(find.text('Nepravidelné'), findsOneWidget);
    expect(find.text('Firma Kolo'), findsOneWidget);
    expect(find.textContaining('každý čtvrtek 18:00–20:00'), findsOneWidget);
    // The group tile: first two dates, the rest counted.
    expect(find.textContaining('${dayLabel(d1)} · 18:00–20:00 · dráhy 1'),
        findsOneWidget);
    expect(find.textContaining('${dayLabel(d2)} · 18:00–20:00 · dráhy 1, 2'),
        findsOneWidget);
    expect(find.textContaining(dayLabel(d3)), findsNothing);
    expect(find.textContaining(rentalMoreDatesLabel(1)), findsOneWidget);
    // The lone one-off is a group of one, with its note.
    expect(find.textContaining('${dayLabel(lone.date!)} · 19:00–22:00 · dráhy 1, 2 · dort'),
        findsOneWidget);
    // Order: header Pravidelné, series, header Nepravidelné, Trak (d1) before Oslava (d1+2).
    double y(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(y('Pravidelné'), lessThan(y('Firma Kolo')));
    expect(y('Firma Kolo'), lessThan(y('Nepravidelné')));
    expect(y('Nepravidelné'), lessThan(y('Firma Trak')));
    expect(y('Firma Trak'), lessThan(y('Oslava Novákovi')));
  });

  testWidgets('empty state', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Zatím žádné pronájmy.'), findsOneWidget);
    expect(find.text('Přidat pronájem'), findsOneWidget);
  });

  testWidgets('Přidat pronájem asks which kind; Nepravidelný opens the '
      "dialog with the alley's lanes and no mode switch", (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Přidat pronájem'));
    await tester.pumpAndSettle();
    expect(find.text('Pravidelný'), findsOneWidget);
    expect(find.text('Nepravidelný'), findsOneWidget);
    await tester.tap(find.text('Nepravidelný'));
    await tester.pumpAndSettle();
    expect(find.text('Přidat nepravidelný pronájem'), findsOneWidget);
    expect(find.text('Nájemce'), findsOneWidget);
    expect(find.text('Datum'), findsOneWidget);
    expect(find.text('Jednorázový'), findsNothing);
    expect(find.text('Týdenní'), findsNothing);
    expect(find.text('Den v týdnu'), findsNothing);
    expect(find.text('Dráha 1'), findsOneWidget);
    expect(find.text('Dráha 2'), findsOneWidget);
    expect(find.text('Dráha 3'), findsNothing);
    expect(find.text('Uložit'), findsOneWidget);
  });

  testWidgets('Pravidelný opens the weekly form', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Přidat pronájem'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pravidelný'));
    await tester.pumpAndSettle();
    expect(find.text('Přidat pravidelný pronájem'), findsOneWidget);
    expect(find.text('Den v týdnu'), findsOneWidget);
    expect(find.text('Datum'), findsNothing);
  });

  testWidgets('a weekly rental counts its exceptions and offers Výjimky; '
      'the exception rows are not listed as rentals', (tester) async {
    await tester.pumpWidget(app(rentals: withExceptions));
    await tester.pumpAndSettle();

    expect(find.text('Firma Kolo'), findsOneWidget);
    expect(find.textContaining('2 výjimky'), findsOneWidget);
    expect(find.byTooltip('Výjimky'), findsOneWidget);
    expect(find.text('Nepravidelné'), findsNothing);
    expect(find.byType(ListTile), findsOneWidget);
  });

  testWidgets('Výjimky lists the exceptions with what each one changes',
      (tester) async {
    await tester.pumpWidget(app(rentals: withExceptions));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Výjimky'));
    await tester.pumpAndSettle();

    expect(find.text('Výjimky · Firma Kolo'), findsOneWidget);
    expect(find.text(dayFull(firstThursday)), findsOneWidget);
    expect(find.text('vynecháno'), findsOneWidget);
    expect(find.text(dayFull(secondThursday)), findsOneWidget);
    expect(find.text('dráhy 1'), findsOneWidget);
    expect(find.text('Přidat výjimku'), findsOneWidget);
    expect(find.text('Zavřít'), findsOneWidget);
  });

  testWidgets('Přidat výjimku opens the occurrence dialog with a date pick',
      (tester) async {
    await tester.pumpWidget(app(rentals: withExceptions));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Výjimky'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Přidat výjimku'));
    await tester.pumpAndSettle();

    expect(find.text('Výjimka pronájmu'), findsOneWidget);
    expect(find.text('Datum'), findsOneWidget);
  });

  testWidgets('a past exception is listed but inert', (tester) async {
    final lastThursday = firstThursday.addDays(-7);
    await tester.pumpWidget(app(rentals: [
      weekly,
      exception(id: 'x-past', date: lastThursday, skipped: true),
    ]));
    await tester.pumpAndSettle();

    expect(find.textContaining('1 výjimka'), findsOneWidget);
    await tester.tap(find.byTooltip('Výjimky'));
    await tester.pumpAndSettle();

    final tile = find.ancestor(
      of: find.text(dayFull(lastThursday)),
      matching: find.byType(ListTile),
    );
    expect(tester.widget<ListTile>(tile).enabled, isFalse);
    final delete = find.descendant(of: tile, matching: find.byType(IconButton));
    expect(tester.widget<IconButton>(delete).onPressed, isNull);
  });

  testWidgets('a one-time rental has no Výjimky button', (tester) async {
    await tester.pumpWidget(app(rentals: [
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

    expect(find.text('Oslava Novákovi'), findsOneWidget);
    expect(find.byTooltip('Výjimky'), findsNothing);
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
  });

  testWidgets('a group tile offers Termíny, Upravit and Smazat naming the '
      'date count', (tester) async {
    await tester.pumpWidget(app(rentals: [
      grouped(id: 'g1-a', date: d1),
      grouped(id: 'g1-b', date: d2),
    ]));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Termíny'));
    await tester.pumpAndSettle();
    expect(find.text('Termíny · Firma Trak'), findsOneWidget);
    await tester.tap(find.text('Zavřít'));
    await tester.pumpAndSettle();

    // Upravit must open the GROUP dialog (name + colour), not the rental
    // form — the two look alike and only the title tells them apart.
    await tester.tap(find.byTooltip('Upravit'));
    await tester.pumpAndSettle();
    expect(find.text('Upravit pronájem'), findsOneWidget);
    expect(find.text('Nájemce'), findsOneWidget);
    expect(find.text('Barva'), findsOneWidget);
    expect(find.text('Datum'), findsNothing, reason: 'a group has no one date');
    await tester.tap(find.text('Zrušit'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Smazat'));
    await tester.pumpAndSettle();
    expect(find.text('Smazat pronájem?'), findsOneWidget);
    expect(find.textContaining('včetně 2 termínů'), findsOneWidget,
        reason: '"včetně" governs the genitive');
  });

  testWidgets('a group tile shows what is coming, not what is over',
      (tester) async {
    // Two dates behind, one ahead. The group is in the list BECAUSE of the
    // date ahead, so filling both lines with history would hide the reason.
    final past1 = today().addDays(-20);
    final past2 = today().addDays(-6);
    await tester.pumpWidget(app(rentals: [
      grouped(id: 'g1-p1', date: past1),
      grouped(id: 'g1-p2', date: past2),
      grouped(id: 'g1-n', date: d1, lanes: const [2]),
    ]));
    await tester.pumpAndSettle();
    expect(find.textContaining(dayLabel(d1)), findsOneWidget);
    expect(find.textContaining(dayLabel(past1)), findsNothing);
    expect(find.textContaining(dayLabel(past2)), findsNothing);
    // Nothing follows the window, so there is no tail: the two dates the
    // window skipped are over, and "…a další 2 termíny" would announce two
    // more still to come.
    expect(find.textContaining('…a'), findsNothing);
  });

  testWidgets('the tail counts only the dates AFTER the two shown, past ones '
      'excluded', (tester) async {
    // Two behind and three ahead: the tile shows the first two ahead, and
    // exactly one date is still to come after them.
    final past1 = today().addDays(-20);
    final past2 = today().addDays(-6);
    await tester.pumpWidget(app(rentals: [
      grouped(id: 'g1-p1', date: past1),
      grouped(id: 'g1-p2', date: past2),
      grouped(id: 'g1-a', date: d1),
      grouped(id: 'g1-b', date: d2),
      grouped(id: 'g1-c', date: d3),
    ]));
    await tester.pumpAndSettle();
    expect(find.textContaining(dayLabel(d1)), findsOneWidget);
    expect(find.textContaining(dayLabel(d2)), findsOneWidget);
    expect(find.textContaining(dayLabel(d3)), findsNothing);
    expect(find.textContaining(rentalMoreDatesLabel(1)), findsOneWidget);
  });

  testWidgets('a group with nothing ahead still shows its last dates',
      (tester) async {
    final past1 = today().addDays(-20);
    final past2 = today().addDays(-6);
    await tester.pumpWidget(app(rentals: [
      grouped(id: 'g1-p1', date: past1),
      grouped(id: 'g1-p2', date: past2),
    ]));
    await tester.pumpAndSettle();
    expect(find.textContaining(dayLabel(past1)), findsOneWidget);
    expect(find.textContaining(dayLabel(past2)), findsOneWidget);
  });

  testWidgets('a lone one-off is deleted like before, no count', (tester) async {
    await tester.pumpWidget(app(rentals: [lone]));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Smazat'));
    await tester.pumpAndSettle();
    expect(find.text('Opravdu smazat pronájem pro Oslava Novákovi?'),
        findsOneWidget);
  });
}

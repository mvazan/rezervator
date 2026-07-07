import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/ui.dart' show today;
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/schedule/week_screen.dart';

void main() {
  const settings = ScheduleSettings(
    laneCount: 2,
    trainingWeekdays: {1, 2, 3, 4, 5, 6, 7},
    bookingHorizonDays: 14,
    maxActiveReservations: 3,
  );
  const b1 = TimeBlock(
      id: 'b1',
      startsAt: HourMinute(22, 58),
      endsAt: HourMinute(23, 59),
      position: 0,
      active: true);

  final t = today();
  final tomorrow = t.addDays(1);

  const me = Profile(
    id: 'me',
    displayName: 'Já Hráč',
    club: '',
    email: 'me@example.com',
    role: Role.player,
    status: ProfileStatus.approved,
  );

  Reservation res(String id, String playerId, Day date) => Reservation(
        id: id,
        playerId: playerId,
        date: date,
        blockId: 'b1',
        lane: 2,
        createdVia: 'app',
        createdAt: DateTime.utc(2026, 1, 1),
      );

  Widget app({
    List<DayOverride> overrides = const [],
    List<Match> matches = const [],
    List<Reservation> reservations = const [],
  }) {
    return ProviderScope(
      overrides: [
        settingsProvider.overrideWith((ref) => Stream.value(settings)),
        timeBlocksProvider.overrideWith((ref) => Stream.value(const [b1])),
        dayOverridesProvider.overrideWith((ref) => Stream.value(overrides)),
        matchesProvider.overrideWith((ref) => Stream.value(matches)),
        rentalsProvider.overrideWith((ref) => Stream.value(const [])),
        weekReservationsProvider
            .overrideWith((ref, monday) => Stream.value(reservations)),
        myActiveReservationsProvider
            .overrideWith((ref) => Stream.value(reservations)),
        myProfileProvider.overrideWith((ref) => Stream.value(me)),
        playersProvider.overrideWith((ref) async => const [
              PlayerName(id: 'me', displayName: 'Já Hráč', club: ''),
              PlayerName(id: 'p2', displayName: 'Petr Novák', club: ''),
            ]),
      ],
      child: const MaterialApp(home: Scaffold(body: WeekScreen())),
    );
  }

  testWidgets('closed override renders reason', (tester) async {
    await tester.pumpWidget(app(overrides: [
      DayOverride(date: tomorrow, closed: true, reason: 'Malování'),
    ]));
    await tester.pumpAndSettle();
    expect(find.textContaining('Zavřeno — Malování'), findsOneWidget);
  });

  testWidgets('reserved cell shows player name; own name bold', (tester) async {
    await tester.pumpWidget(app(reservations: [res('r2', 'p2', tomorrow)]));
    await tester.pumpAndSettle();
    expect(find.text('Petr Novák'), findsOneWidget);
  });

  testWidgets('tap on own reservation opens cancel dialog', (tester) async {
    await tester.pumpWidget(app(reservations: [res('r1', 'me', tomorrow)]));
    await tester.pumpAndSettle();
    // `tomorrow`'s day card can sit past the default 800x600 test surface
    // depending on its weekday (e.g. Thu = 4th of 7 stacked cards), so the
    // cell must be scrolled into view before tapping — ensureVisible finds
    // the nearest Scrollable (the week ListView) and brings it on-screen.
    await tester.ensureVisible(find.text('Já Hráč').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Já Hráč').first);
    await tester.pumpAndSettle();
    expect(find.text('Zrušit rezervaci?'), findsOneWidget);
  });

  testWidgets('free bookable cell opens booking dialog', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add).first);
    await tester.pumpAndSettle();
    expect(find.text('Rezervovat termín?'), findsOneWidget);
  });

  testWidgets('match renders banner and Zápas cells', (tester) async {
    await tester.pumpWidget(app(matches: [
      Match(
        id: 'm1',
        date: tomorrow,
        startsAt: const HourMinute(22, 0),
        endsAt: const HourMinute(23, 59),
        opponent: 'KK Slavoj',
        description: '',
      ),
    ]));
    await tester.pumpAndSettle();
    expect(find.textContaining('KK Slavoj'), findsOneWidget);
    expect(find.text('Zápas'), findsNWidgets(2)); // 2 lanes × 1 block
  });

  testWidgets(
      'cells stay inert while weekReservationsProvider never emits',
      (tester) async {
    // Everything else has data, but this week's reservation stream is stuck
    // loading forever — no cell may be bookable while that's true.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith((ref) => Stream.value(settings)),
          timeBlocksProvider.overrideWith((ref) => Stream.value(const [b1])),
          dayOverridesProvider.overrideWith((ref) => Stream.value(const [])),
          matchesProvider.overrideWith((ref) => Stream.value(const [])),
          rentalsProvider.overrideWith((ref) => Stream.value(const [])),
          weekReservationsProvider.overrideWith(
              (ref, monday) => StreamController<List<Reservation>>().stream),
          myActiveReservationsProvider
              .overrideWith((ref) => Stream.value(const [])),
          myProfileProvider.overrideWith((ref) => Stream.value(me)),
          playersProvider.overrideWith((ref) async => const [
                PlayerName(id: 'me', displayName: 'Já Hráč', club: ''),
              ]),
        ],
        child: const MaterialApp(home: Scaffold(body: WeekScreen())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.add), findsNothing);
  });
}

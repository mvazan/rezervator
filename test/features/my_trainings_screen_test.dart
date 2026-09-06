import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/ui.dart' show dayFull;
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/schedule/my_trainings_screen.dart';

void main() {
  final now = DateTime(2026, 9, 9, 10, 0); // středa
  final today = Day.fromDateTime(now);
  const b1 = TimeBlock(
    id: 'b1',
    startsAt: HourMinute(18, 0),
    endsAt: HourMinute(19, 0),
    position: 0,
    active: true,
  );
  const me = Profile(
    id: 'me',
    displayName: 'Já Hráč',
    email: 'me@example.com',
    role: Role.player,
    status: ProfileStatus.approved,
    followedTeams: ['SKK Veverky Brno A'],
  );
  const nobody = Profile(
    id: 'me',
    displayName: 'Já Hráč',
    email: 'me@example.com',
    role: Role.player,
    status: ProfileStatus.approved,
  );
  Reservation res(String id, Day date) => Reservation(
        id: id,
        playerId: 'me',
        date: date,
        blockId: 'b1',
        lane: 2,
        createdVia: 'app',
        createdAt: DateTime.utc(2026, 1, 1),
      );
  final match = PrioritySlot(
    id: 'm1',
    date: today.addDays(2),
    startsAt: const HourMinute(18, 30),
    endsAt: const HourMinute(21, 30),
    type: PrioritySlot.fallbackMatchType,
    homeTeam: 'SKK Veverky Brno A',
    awayTeam: 'KK MS Brno D',
    description: 'KP1 Sever',
  );

  Widget app({
    Profile profile = me,
    List<Reservation> reservations = const [],
    List<PrioritySlot> slots = const [],
    Stream<List<Reservation>>? reservationsStream,
    Future<void> Function(String id)? cancel,
    VoidCallback? onOpenCalendar,
  }) {
    return ProviderScope(
      overrides: [
        myProfileProvider.overrideWith((ref) => Stream.value(profile)),
        myActiveReservationsProvider.overrideWith(
            (ref) => reservationsStream ?? Stream.value(reservations)),
        timeBlocksProvider.overrideWith((ref) => Stream.value(const [b1])),
        prioritySlotsProvider.overrideWithValue(slots),
        nowProvider.overrideWith((ref) => Stream.value(now)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: MyTrainingsScreen(
            onOpenCalendar: onOpenCalendar ?? () {},
            cancelReservation: cancel ?? (_) async => throw StateError('unexpected'),
          ),
        ),
      ),
    );
  }

  testWidgets('lists trainings and followed matches by day, today and '
      'tomorrow by name', (tester) async {
    await tester.pumpWidget(app(
      reservations: [res('r1', today), res('r2', today.addDays(1))],
      slots: [match],
    ));
    await tester.pumpAndSettle();

    expect(find.text('Moje tréninky'), findsOneWidget);
    expect(find.text('Dnes'), findsOneWidget);
    expect(find.text('Zítra'), findsOneWidget);
    // A day beyond tomorrow (the match, two days out) is labelled with the
    // full weekday name, not a relative one.
    expect(find.text(dayFull(today.addDays(2))), findsOneWidget);
    expect(find.text('18:00–19:00 · Dráha 2'), findsNWidgets(2));
    expect(find.text('SKK Veverky Brno A – KK MS Brno D'), findsOneWidget);
    expect(find.text('18:30–21:30 · doma · KP1 Sever'), findsOneWidget);
    // Chronological: today's training above the match two days out.
    expect(
      tester.getTopLeft(find.text('Dnes')).dy,
      lessThan(tester.getTopLeft(find.text('SKK Veverky Brno A – KK MS Brno D')).dy),
    );
    expect(find.textContaining('Moje týmy'), findsNothing);
  });

  testWidgets('while reservations have not loaded yet shows a progress '
      'indicator, never the empty state', (tester) async {
    final ctrl = StreamController<List<Reservation>>();
    addTearDown(ctrl.close);
    // No pumpAndSettle: the indicator's animation never settles on its own,
    // and a single pumpWidget frame already flushes every OTHER overridden
    // stream (blocks, profile, now) via their microtask, leaving only the
    // reservations stream genuinely stuck loading.
    await tester.pumpWidget(app(reservationsStream: ctrl.stream));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Zatím nic.'), findsNothing);
  });

  testWidgets('when the reservations stream errors, shows the error text '
      'and a retry button', (tester) async {
    await tester.pumpWidget(
      app(reservationsStream: Stream.error(StateError('boom'))),
    );
    await tester.pumpAndSettle();

    expect(find.text('Tréninky se nepodařilo načíst.'), findsOneWidget);
    expect(find.text('Zkusit znovu'), findsOneWidget);
    expect(find.text('Zatím nic.'), findsNothing);
  });

  testWidgets('tapping a training asks, then cancels it', (tester) async {
    final cancelled = <String>[];
    await tester.pumpWidget(app(
      reservations: [res('r1', today.addDays(1))],
      cancel: (id) async => cancelled.add(id),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('18:00–19:00 · Dráha 2'));
    await tester.pumpAndSettle();
    expect(find.text('Zrušit rezervaci?'), findsOneWidget);
    await tester.tap(find.text('Zrušit rezervaci'));
    await tester.pumpAndSettle();

    expect(cancelled, ['r1']);
    expect(find.text('Rezervace zrušena.'), findsOneWidget);
  });

  testWidgets('empty: says so and the button opens the calendar', (tester) async {
    var opened = 0;
    await tester.pumpWidget(app(onOpenCalendar: () => opened++));
    await tester.pumpAndSettle();

    expect(find.text('Zatím nic.'), findsOneWidget);
    await tester.tap(find.text('Do kalendáře'));
    expect(opened, 1);
  });

  testWidgets('without followed teams the list ends with the hint', (tester) async {
    await tester.pumpWidget(app(
      profile: nobody,
      reservations: [res('r1', today)],
      slots: [match],
    ));
    await tester.pumpAndSettle();

    expect(find.text('SKK Veverky Brno A – KK MS Brno D'), findsNothing);
    expect(find.textContaining('Moje týmy'), findsOneWidget);
  });
}

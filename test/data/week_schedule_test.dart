import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/data/week_schedule.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/schedule.dart';

void main() {
  const b1 = TimeBlock(
      id: 'b1',
      startsAt: HourMinute(17, 0),
      endsAt: HourMinute(18, 0),
      position: 0,
      active: true);
  final monday = Day(2026, 8, 31); // 2026-09-02 (Wednesday) lies in this week
  final wednesday = Day(2026, 9, 2);
  final clock = DateTime(2026, 9, 2, 16, 0);
  const settings = ScheduleSettings(
    laneCount: 2,
    trainingWeekdays: {3},
    bookingHorizonDays: 14,
    maxActiveReservations: 3,
  );
  const players = [
    PlayerName(id: 'p1', displayName: 'Petr Novák', nick: 'Péťa', clubColor: 4),
    PlayerName(id: 'p2', displayName: 'Olga Malá'),
  ];
  final reservation = Reservation(
    id: 'r1',
    playerId: 'p1',
    date: wednesday,
    blockId: 'b1',
    lane: 1,
    createdVia: 'app',
    createdAt: clock,
  );

  // Streams are created inside the override callbacks: a family instance
  // may be built more than once and a single-subscription stream can only
  // be listened to once.
  ProviderContainer container({
    required Stream<List<TimeBlock>> Function() blocks,
    List<Reservation> reservations = const [],
  }) {
    final c = ProviderContainer(overrides: [
      nowProvider.overrideWith((ref) => Stream.value(clock)),
      timeBlocksProvider.overrideWith((ref) => blocks()),
      settingsProvider.overrideWith((ref) => Stream.value(settings)),
      dayOverridesProvider.overrideWith((ref) => Stream.value(const [])),
      prioritySlotsProvider.overrideWith((ref) => const []),
      rentalsProvider.overrideWith((ref) => Stream.value(const [])),
      weekReservationsProvider
          .overrideWith((ref, day) => Stream.value(reservations)),
      playersProvider.overrideWith((ref) async => players),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  /// Subscribes (autoDispose providers live only while listened), lets every
  /// overridden stream/future deliver its first value, and reads the result.
  Future<AsyncValue<WeekView>> load(ProviderContainer c) async {
    final sub = c.listen(weekScheduleProvider(monday), (_, _) {});
    addTearDown(sub.close);
    // Streams deliver in microtasks, and the week provider only subscribes
    // to the reservation stream once the blocks have arrived — give the
    // chain a bounded number of event-loop turns to settle.
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(Duration.zero);
      final v = c.read(weekScheduleProvider(monday));
      if (v.hasError || (v.hasValue && v.value!.reservationsLoaded)) break;
    }
    return c.read(weekScheduleProvider(monday));
  }

  test('loading while the blocks stream has not delivered', () async {
    final c =
        container(blocks: () => Completer<List<TimeBlock>>().future.asStream());
    expect((await load(c)).isLoading, isTrue);
  });

  test('a blocks error propagates', () async {
    final c = container(blocks: () => Stream.error(StateError('rls')));
    expect((await load(c)).hasError, isTrue);
  });

  test('composes the week, the nick-first names and club colours', () async {
    final c = container(
        blocks: () => Stream.value(const [b1]), reservations: [reservation]);
    final view = (await load(c)).value!;
    expect((view.blocksFromDb, view.reservationsLoaded, view.interactive),
        (true, true, true));
    expect(view.today, wednesday);
    expect(view.now, const HourMinute(16, 0));
    expect(view.nameById, {'p1': 'Péťa', 'p2': 'Olga Malá'});
    expect(view.clubColorById, {'p1': 4, 'p2': -1});
    final day = view.week.days[2] as OpenDay; // Wednesday
    expect(day.slot('b1', 1), isA<ReservedSlot>());
    expect(day.slot('b1', 2), isA<FreeSlot>());
    expect(view.week.days[0], isA<ClosedDay>()); // Monday: not a training day
  });

  test('an empty blocks table renders the placeholder grid, never '
      'interactive', () async {
    final c = container(blocks: () => Stream.value(const []));
    final view = (await load(c)).value!;
    expect(view.blocksFromDb, isFalse);
    expect(view.blocks.length, 6);
    expect(view.interactive, isFalse);
  });

  test('the same Monday yields the same instance while nothing changed',
      () async {
    final c = container(blocks: () => Stream.value(const [b1]));
    final a = (await load(c)).value;
    final b = c.read(weekScheduleProvider(monday)).value;
    expect(identical(a, b), isTrue);
  });
}

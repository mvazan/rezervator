import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/freed_spot.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/schedule.dart';

void main() {
  const b1 = TimeBlock(
    id: 'b1',
    startsAt: HourMinute(16, 0),
    endsAt: HourMinute(17, 0),
    position: 0,
    active: true,
  );
  const b2 = TimeBlock(
    id: 'b2',
    startsAt: HourMinute(17, 0),
    endsAt: HourMinute(18, 0),
    position: 1,
    active: true,
  );
  const settings = ScheduleSettings(
    laneCount: 2,
    trainingWeekdays: {1, 2, 4},
    bookingHorizonDays: 14,
    maxActiveReservations: 2,
  );
  final monday = Day(2026, 7, 6);
  final tuesday = Day(2026, 7, 7);
  final thursday = Day(2026, 7, 9);

  Reservation res(String player, String block, int lane, Day date) =>
      Reservation(
        id: '$player$block$lane',
        playerId: player,
        date: date,
        blockId: block,
        lane: lane,
        createdVia: 'app',
        createdAt: DateTime.utc(2026, 7, 1),
      );

  DaySchedule day(
    Day date, {
    List<Reservation> reservations = const [],
    Day? today,
    HourMinute now = const HourMinute(12, 0),
  }) => buildWeekSchedule(
    monday: monday,
    today: today ?? tuesday,
    now: now,
    settings: settings,
    blocks: const [b1, b2],
    overrides: const [],
    priority: const [],
    rentals: const [],
    reservations: reservations,
  ).days[date.weekday - 1];

  FreedSpotResult result(
    DaySchedule d, {
    String blockId = 'b1',
    int lane = 1,
    int myCount = 0,
  }) => freedSpotResult(
    d,
    blockId: blockId,
    lane: lane,
    myPlayerId: 'me',
    myActiveCount: myCount,
    settings: settings,
  );

  test('still free: highlighted, no message', () {
    final r = result(day(thursday));
    expect(r.outcome, FreedSpotOutcome.free);
    expect(r.message, isNull);
  });

  test('booked again by somebody else: says so and counts what is left', () {
    final d = day(thursday, reservations: [res('p1', 'b1', 1, thursday)]);
    final r = result(d);
    expect(r.outcome, FreedSpotOutcome.taken);
    // 2 blocks × 2 lanes − the one taken.
    expect(r.othersFree, 3);
    expect(r.message, contains('zase obsazené'));
    expect(r.message, contains('zbývají ještě 3 volná místa'));
  });

  test('nothing left in the day', () {
    final d = day(
      thursday,
      reservations: [
        for (final b in ['b1', 'b2'])
          for (final l in [1, 2]) res('p$b$l', b, l, thursday),
      ],
    );
    final r = result(d);
    expect(r.outcome, FreedSpotOutcome.taken);
    expect(r.message, contains('nic volného nezbylo'));
  });

  test('czech plural of the free spots', () {
    final one = FreedSpotResult(FreedSpotOutcome.taken, othersFree: 1).message;
    final five = FreedSpotResult(FreedSpotOutcome.taken, othersFree: 5).message;
    expect(one, contains('zbývá ještě 1 volné místo'));
    expect(five, contains('zbývá ještě 5 volných míst'));
  });

  test('the caller booked it themselves', () {
    final d = day(thursday, reservations: [res('me', 'b1', 1, thursday)]);
    expect(result(d).outcome, FreedSpotOutcome.mine);
  });

  test('free but at the reservation limit', () {
    final r = result(day(thursday), myCount: 2);
    expect(r.outcome, FreedSpotOutcome.limit);
    expect(r.message, contains('nejvyšší počet'));
  });

  test('the block has started', () {
    // Tuesday 16:30: the 16:00 block is under way.
    final d = day(tuesday, now: const HourMinute(16, 30));
    expect(result(d).outcome, FreedSpotOutcome.past);
    expect(result(d).message, 'Tenhle trénink už začal.');
  });

  test('a taken spot of a block that has started is just past', () {
    final d = day(
      tuesday,
      now: const HourMinute(16, 30),
      reservations: [res('p1', 'b1', 1, tuesday)],
    );
    expect(result(d).outcome, FreedSpotOutcome.past);
  });

  test('a closed day', () {
    final r = result(day(Day(2026, 7, 8))); // Wednesday: no training
    expect(r.outcome, FreedSpotOutcome.closed);
  });

  test('a block or lane that is not in the day', () {
    expect(
      result(day(thursday), blockId: 'zzz').outcome,
      FreedSpotOutcome.gone,
    );
    expect(result(day(thursday), lane: 9).outcome, FreedSpotOutcome.gone);
  });
}

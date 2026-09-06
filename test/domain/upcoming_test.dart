import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/upcoming.dart';

void main() {
  final today = Day(2026, 9, 9);
  const b1 = TimeBlock(
    id: 'b1',
    startsAt: HourMinute(18, 0),
    endsAt: HourMinute(19, 0),
    position: 0,
    active: true,
  );
  const b2 = TimeBlock(
    id: 'b2',
    startsAt: HourMinute(19, 0),
    endsAt: HourMinute(20, 0),
    position: 1,
    active: true,
  );
  Reservation res(String id, Day date, {String block = 'b1', DateTime? cancelled}) =>
      Reservation(
        id: id,
        playerId: 'me',
        date: date,
        blockId: block,
        lane: 2,
        createdVia: 'app',
        createdAt: DateTime.utc(2026, 1, 1),
        cancelledAt: cancelled,
      );
  PrioritySlot match(String id, Day date, HourMinute start,
          {String home = 'SKK Veverky Brno A',
          String away = 'KK MS Brno D',
          bool isAway = false,
          String? parentId}) =>
      PrioritySlot(
        id: id,
        date: date,
        startsAt: start,
        endsAt: HourMinute(start.hour + 2, start.minute),
        type: PrioritySlot.fallbackMatchType,
        homeTeam: home,
        awayTeam: away,
        isAway: isAway,
        parentId: parentId,
      );

  test('days ascending, items by start, a training before a match at the '
      'same start', () {
    final days = upcomingTimeline(
      reservations: [res('r2', today.addDays(1), block: 'b2'), res('r1', today)],
      blocks: const [b1, b2],
      slots: [
        match('m1', today.addDays(1), const HourMinute(19, 0)),
        match('m0', today, const HourMinute(16, 0)),
      ],
      teams: const ['SKK Veverky Brno A'],
      today: today,
    );
    expect([for (final d in days) d.date], [today, today.addDays(1)]);
    expect(days[0].items.map((i) => i is UpcomingMatch ? 'm' : 't'), ['m', 't']);
    expect(
      days[1].items.map((i) => i is UpcomingMatch ? 'm' : 't'),
      ['t', 'm'],
      reason: 'r2 (19:00) sorts before m1 (19:00)',
    );
  });

  test('cancelled, past and orphaned reservations are dropped', () {
    final days = upcomingTimeline(
      reservations: [
        res('gone', today.addDays(2), cancelled: DateTime.utc(2026, 9, 1)),
        res('past', today.addDays(-1)),
        res('orphan', today.addDays(2), block: 'deleted-block'),
        res('ok', today.addDays(2)),
      ],
      blocks: const [b1],
      slots: const [],
      teams: const [],
      today: today,
    );
    expect(days, hasLength(1));
    expect((days.single.items.single as UpcomingTraining).reservation.id, 'ok');
  });

  test('matches: followed as home or away, away kept, úklid children and '
      'unfollowed skipped', () {
    final days = upcomingTimeline(
      reservations: const [],
      blocks: const [],
      slots: [
        match('home', today.addDays(1), const HourMinute(18, 0)),
        match('away', today.addDays(2), const HourMinute(18, 0),
            home: 'KK Blansko B', away: 'SKK Veverky Brno A', isAway: true),
        match('other', today.addDays(3), const HourMinute(18, 0),
            home: 'TJ Sokol Husovice', away: 'KK Vyškov'),
        match('child', today.addDays(1), const HourMinute(17, 30), parentId: 'home'),
      ],
      teams: const ['SKK Veverky Brno A'],
      today: today,
    );
    expect(
      [for (final d in days) for (final i in d.items) (i as UpcomingMatch).slot.id],
      ['home', 'away'],
    );
  });

  test('no followed teams means no matches; nothing at all means no days', () {
    final only = upcomingTimeline(
      reservations: const [],
      blocks: const [],
      slots: [match('m', today, const HourMinute(18, 0))],
      teams: const [],
      today: today,
    );
    expect(only, isEmpty);
  });
}

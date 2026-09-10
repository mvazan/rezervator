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
  Reservation res(String id, Day date,
          {String block = 'b1', DateTime? cancelled, int lane = 2}) =>
      Reservation(
        id: id,
        playerId: 'me',
        date: date,
        blockId: block,
        lane: lane,
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

  // The youth squad shares its club's name in the federation's schedule, so
  // the import marks ours with a suffix (TEAM_SUFFIXES in
  // tool/import_matches.py). Following one squad must then leave the other
  // out — the overview matches a team by its exact name, which is what
  // makes the split by competition work at all.
  test('a followed squad does not drag its namesake along', () {
    final slots = [
      match('a', today, const HourMinute(11, 30), home: 'TJ Sokol Husovice'),
      match('d', today, const HourMinute(9, 30),
          home: 'TJ Sokol Husovice (dorost)'),
    ];
    List<String> idsFor(List<String> teams) => [
          for (final day in upcomingTimeline(
            reservations: const [],
            blocks: const [b1],
            slots: slots,
            teams: teams,
            today: today,
          ))
            for (final item in day.items)
              if (item is UpcomingMatch) item.slot.id,
        ];

    expect(idsFor(const ['TJ Sokol Husovice']), ['a']);
    expect(idsFor(const ['TJ Sokol Husovice (dorost)']), ['d']);
    expect(
      idsFor(const ['TJ Sokol Husovice', 'TJ Sokol Husovice (dorost)']),
      ['d', 'a'],
      reason: 'both followed, both shown, in the order they are played',
    );
  });

  test('two own trainings tied on date and start (same block) break by '
      'lane, lower first', () {
    final days = upcomingTimeline(
      reservations: [
        res('lane3', today, lane: 3),
        res('lane1', today, lane: 1),
      ],
      blocks: const [b1],
      slots: const [],
      teams: const [],
      today: today,
    );
    expect(days, hasLength(1));
    expect(
      days.single.items.map((i) => (i as UpcomingTraining).reservation.id),
      ['lane1', 'lane3'],
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

  test('a match between two followed teams (home and away both followed) '
      'is included once, not twice', () {
    final days = upcomingTimeline(
      reservations: const [],
      blocks: const [],
      slots: [
        match('derby', today, const HourMinute(18, 0),
            home: 'SKK Veverky Brno A', away: 'SKK Veverky Brno B'),
      ],
      teams: const [
        'SKK Veverky Brno A',
        'SKK Veverky Brno B',
        'KK Blansko B',
      ],
      today: today,
    );
    expect(days, hasLength(1));
    expect(days.single.items, hasLength(1));
    expect((days.single.items.single as UpcomingMatch).slot.id, 'derby');
  });

  test('a non-match priority slot (e.g. a rental) is never listed even when '
      'its team fields happen to match a followed team', () {
    const rentalType = PrioritySlotType(id: 't-rental', name: 'Pronájem');
    final days = upcomingTimeline(
      reservations: const [],
      blocks: const [],
      slots: [
        PrioritySlot(
          id: 'r1',
          date: today,
          startsAt: const HourMinute(18, 0),
          endsAt: const HourMinute(19, 0),
          type: rentalType,
          homeTeam: 'SKK Veverky Brno A',
          awayTeam: 'KK MS Brno D',
        ),
      ],
      teams: const ['SKK Veverky Brno A'],
      today: today,
    );
    expect(days, isEmpty);
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

  // ---------------------------------------------------------------------
  // matchColorOf (0036): the trophy's colour in Můj přehled.
  // ---------------------------------------------------------------------

  group('matchColorOf', () {
    // match()'s defaults: home 'SKK Veverky Brno A', away 'KK MS Brno D'.
    final m = match('m', today, const HourMinute(18, 0));
    const bothFollowed = ['SKK Veverky Brno A', 'KK MS Brno D'];

    test('neither team coloured: null, today\'s look', () {
      expect(matchColorOf(m, bothFollowed, const {}), isNull);
    });

    test('the followed home team coloured: its colour', () {
      expect(
        matchColorOf(m, const ['SKK Veverky Brno A'],
            const {'SKK Veverky Brno A': 3}),
        3,
      );
    });

    test('the followed away team coloured: its colour', () {
      expect(
        matchColorOf(m, const ['KK MS Brno D'], const {'KK MS Brno D': 5}),
        5,
      );
    });

    test('derby — both teams followed and coloured: home wins, same '
        'tie-break shape my_future_matches uses server-side (over the '
        'calendar\'s own list, not this one)', () {
      expect(
        matchColorOf(m, bothFollowed, const {
          'SKK Veverky Brno A': 3,
          'KK MS Brno D': 5,
        }),
        3,
      );
    });

    test('a colour registered for an unrelated, unfollowed team never '
        'leaks in', () {
      expect(
        matchColorOf(m, bothFollowed, const {'TJ Sokol Husovice E': 7}),
        isNull,
      );
    });

    // -----------------------------------------------------------------
    // The bug this group exists to pin down: a colour set on a team the
    // player does NOT follow must never paint a match that is only on
    // the list because of the OTHER team.
    // -----------------------------------------------------------------

    test('the trophy never takes a colour belonging to a team the player '
        'does not follow (the match shows because the OTHER team is '
        'followed)', () {
      final derby = match('derby', today, const HourMinute(18, 0),
          home: 'SKK Veverky Brno A', away: 'KS Devítka Brno B');
      // Only Devítka is followed; Veverky was once coloured red (11) —
      // that colour must not leak onto this match just because Veverky
      // is the home team.
      expect(
        matchColorOf(derby, const ['KS Devítka Brno B'],
            const {'SKK Veverky Brno A': 11}),
        isNull,
      );
    });

    test('no fall-through even within the followed list: home wins the '
        'team pick regardless of colour, so an uncoloured followed home '
        'team hides a coloured followed away team', () {
      expect(matchColorOf(m, bothFollowed, const {'KK MS Brno D': 5}), isNull);
    });
  });
}

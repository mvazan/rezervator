import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/results.dart';

void main() {
  group('numLabel', () {
    test('integral values drop the decimal, null is a dash', () {
      expect(numLabel(2), '2');
      expect(numLabel(2.0), '2');
      expect(numLabel(2.5), '2,5');
      expect(numLabel(null), '–');
    });
  });

  group('pointsLabel', () {
    test('integral points', () => expect(pointsLabel(5, 3), '5 : 3'));
    test(
      'half points use a Czech comma',
      () => expect(pointsLabel(2.5, 5.5), '2,5 : 5,5'),
    );
    test(
      'neither side has a result yet',
      () => expect(pointsLabel(null, null), '–'),
    );
  });

  group('pinsLabel', () {
    test('both sides', () => expect(pinsLabel(3460, 3349), '3460 : 3349'));
    test(
      'neither side has a result yet',
      () => expect(pinsLabel(null, null), ''),
    );
  });

  group('formatLabel', () {
    test(
      'TEAMS_OF_6 + T120',
      () => expect(formatLabel('TEAMS_OF_6', 'T120'), '6 hráčů · 120 HS'),
    );
    test(
      'TEAMS_OF_4 alone (Czech 2–4 agreement)',
      () => expect(formatLabel('TEAMS_OF_4', ''), '4 hráči'),
    );
    test(
      'unknown match type is omitted, discipline still shows',
      () => expect(formatLabel('', 'T100'), '100 HS'),
    );
    test('both unknown is empty', () => expect(formatLabel('', ''), ''));
  });

  group('winningSide', () {
    test('home wins', () => expect(winningSide(5, 3), MatchSide.home));
    test('away wins', () => expect(winningSide(3, 5), MatchSide.away));
    test('a draw is null', () => expect(winningSide(4, 4), isNull));
    test('either side missing is null', () {
      expect(winningSide(null, 3), isNull);
      expect(winningSide(5, null), isNull);
      expect(winningSide(null, null), isNull);
    });
  });

  group('hasScoreData', () {
    MatchResult result(String status) => MatchResult.fromJson({
      'match_id': 'm1',
      'status': status,
      'fetched_at': '2026-09-27T09:00:00+00:00',
    });

    test(
      'null result has no score data',
      () => expect(hasScoreData(null), isFalse),
    );
    test('scheduled/preparation have no score data yet', () {
      expect(hasScoreData(result('scheduled')), isFalse);
      expect(hasScoreData(result('preparation')), isFalse);
    });
    test('in_progress, finished and forfeit all have score data', () {
      expect(hasScoreData(result('in_progress')), isTrue);
      expect(hasScoreData(result('finished')), isTrue);
      expect(hasScoreData(result('forfeit')), isTrue);
    });
  });

  group('displayWinner', () {
    MatchResult result(String status, {num? home, num? away}) =>
        MatchResult.fromJson({
          'match_id': 'm1',
          'status': status,
          'home_points': home,
          'away_points': away,
          'fetched_at': '2026-09-27T09:00:00+00:00',
        });

    test('null before there is score data', () {
      expect(displayWinner(null), isNull);
      expect(displayWinner(result('scheduled', home: 5, away: 3)), isNull);
    });

    test('whoever is ahead once there is score data, final or not', () {
      expect(
        displayWinner(result('in_progress', home: 5, away: 3)),
        MatchSide.home,
      );
      expect(
        displayWinner(result('finished', home: 2, away: 6)),
        MatchSide.away,
      );
    });

    test('null for a draw or missing points even with score data', () {
      expect(displayWinner(result('finished', home: 4, away: 4)), isNull);
      expect(displayWinner(result('in_progress')), isNull);
    });
  });

  group('isLive', () {
    PrioritySlot slot() => PrioritySlot.fromJson(const {
      'id': 'm1',
      'date': '2026-09-27',
      'starts_at': '10:00:00',
      'ends_at': '13:00:00',
      'home_team': 'A',
      'away_team': 'B',
      'description': '',
      'import_key': 'cka:1',
    }, const {});

    MatchResult result(String status) => MatchResult.fromJson({
      'match_id': 'm1',
      'status': status,
      'fetched_at': '2026-09-27T09:00:00+00:00',
    });

    final start = DateTime(2026, 9, 27, 10, 0);

    test('in_progress is live', () {
      expect(isLive(slot(), result('in_progress'), start), isTrue);
    });

    test('scheduled 30 minutes before start is live (refresh window)', () {
      expect(
        isLive(
          slot(),
          result('scheduled'),
          start.subtract(const Duration(minutes: 30)),
        ),
        isTrue,
      );
    });

    test('scheduled 2 hours before start is not live yet', () {
      expect(
        isLive(
          slot(),
          result('scheduled'),
          start.subtract(const Duration(hours: 2)),
        ),
        isFalse,
      );
    });

    test('finished is never live', () {
      expect(isLive(slot(), result('finished'), start), isFalse);
    });

    test(
      'no result row yet, 1 hour after start, is live (treated as scheduled)',
      () {
        expect(
          isLive(slot(), null, start.add(const Duration(hours: 1))),
          isTrue,
        );
      },
    );
  });

  group('resultsTimeline', () {
    const matchType = PrioritySlotType(
      id: 'match-type',
      name: 'Zápas',
      isMatch: true,
    );
    final typeById = {'match-type': matchType};

    PrioritySlot match({
      required String id,
      required String date,
      required String startsAt,
      required String home,
      required String away,
      String? importKey = 'cka:1',
      String? parentId,
    }) => PrioritySlot.fromJson({
      'id': id,
      'date': date,
      'starts_at': startsAt,
      'ends_at': startsAt,
      'type_id': 'match-type',
      'home_team': home,
      'away_team': away,
      'description': '',
      'import_key': importKey,
      'parent_id': parentId,
    }, typeById);

    final slots = [
      match(
        id: 'a',
        date: '2026-09-27',
        startsAt: '10:00:00',
        home: 'SKK Veverky Brno A',
        away: 'KS Devítka Brno A',
      ),
      match(
        id: 'b',
        date: '2026-09-27',
        startsAt: '09:00:00',
        home: 'TJ Sokol Brno IV A',
        away: 'TJ Sokol Husovice A',
      ),
      match(
        id: 'c',
        date: '2026-09-20',
        startsAt: '10:00:00',
        home: 'KS Devítka Brno A',
        away: 'SKK Veverky Brno A',
      ),
      // Not from the federation — excluded regardless of filter.
      match(
        id: 'd',
        date: '2026-09-27',
        startsAt: '11:00:00',
        home: 'Husky',
        away: 'přátelák',
        importKey: 'rozpis:x',
      ),
      match(
        id: 'd2',
        date: '2026-09-27',
        startsAt: '11:00:00',
        home: 'Husky2',
        away: 'přátelák2',
        importKey: null,
      ),
      // Úklid child of a federation match — excluded (parentId set).
      match(
        id: 'e',
        date: '2026-09-27',
        startsAt: '09:45:00',
        home: '',
        away: '',
        parentId: 'a',
      ),
    ];

    test(
      'only federation matches with no parent, days ascending, sorted by start then title',
      () {
        final days = resultsTimeline(
          slots: slots,
          mineOnly: false,
          followedTeams: const [],
          exceptions: const {},
        );
        expect(days.map((d) => d.day.toSql()), ['2026-09-20', '2026-09-27']);
        expect(days.first.matches.map((m) => m.id), ['c']);
        expect(days.last.matches.map((m) => m.id), ['b', 'a']);
      },
    );

    test('mineOnly honours followed teams', () {
      final days = resultsTimeline(
        slots: slots,
        mineOnly: true,
        followedTeams: const ['SKK Veverky Brno A'],
        exceptions: const {},
      );
      expect(days.expand((d) => d.matches).map((m) => m.id).toSet(), {
        'a',
        'c',
      });
    });

    test('mineOnly honours a per-match exception', () {
      final days = resultsTimeline(
        slots: slots,
        mineOnly: true,
        followedTeams: const [],
        exceptions: const {'b': true},
      );
      expect(days.expand((d) => d.matches).map((m) => m.id).toSet(), {'b'});
    });

    test('team filter wins over mineOnly/all and matches either side', () {
      final days = resultsTimeline(
        slots: slots,
        team: 'KS Devítka Brno A',
        mineOnly: false,
        followedTeams: const [],
        exceptions: const {},
      );
      expect(days.expand((d) => d.matches).map((m) => m.id).toSet(), {
        'a',
        'c',
      });
    });
  });

  group('todayIndex', () {
    ({Day day, List<PrioritySlot> matches}) dayOf(String d) =>
        (day: Day.parse(d), matches: const <PrioritySlot>[]);

    test('first day >= today', () {
      final days = [
        dayOf('2026-09-20'),
        dayOf('2026-09-27'),
        dayOf('2026-10-04'),
      ];
      expect(todayIndex(days, Day.parse('2026-09-25')), 1);
    });

    test('today matches exactly', () {
      final days = [dayOf('2026-09-20'), dayOf('2026-09-27')];
      expect(todayIndex(days, Day.parse('2026-09-27')), 1);
    });

    test('every day is in the past → last index', () {
      final days = [dayOf('2026-09-20'), dayOf('2026-09-27')];
      expect(todayIndex(days, Day.parse('2026-10-04')), 1);
    });

    test('empty list → -1', () {
      expect(todayIndex(const [], Day.parse('2026-09-27')), -1);
    });
  });

  group('recentResultsIndex', () {
    const matchType = PrioritySlotType(
      id: 'match-type',
      name: 'Zápas',
      isMatch: true,
    );
    final typeById = {'match-type': matchType};

    PrioritySlot slotOf(String id) => PrioritySlot.fromJson({
      'id': id,
      'date': '2026-09-20',
      'starts_at': '10:00:00',
      'ends_at': '10:00:00',
      'type_id': 'match-type',
      'home_team': 'A',
      'away_team': 'B',
      'description': '',
      'import_key': 'cka:1',
    }, typeById);

    ({Day day, List<PrioritySlot> matches}) dayOf(String d, List<String> ids) =>
        (day: Day.parse(d), matches: [for (final id in ids) slotOf(id)]);

    MatchResult resultOf(String status) => MatchResult.fromJson({
      'match_id': 'x',
      'status': status,
      'fetched_at': '2026-09-20T09:00:00+00:00',
    });

    test('a finished match before today wins over a later day that is '
        'merely today with no result yet', () {
      final days = [
        dayOf('2026-09-20', ['a']),
        dayOf('2026-09-27', ['b']),
      ];
      final results = {'a': resultOf('finished')};
      expect(recentResultsIndex(days, results, Day.parse('2026-09-27')), 0);
    });

    test('the LAST decided day wins when several qualify', () {
      final days = [
        dayOf('2026-09-13', ['a']),
        dayOf('2026-09-20', ['b']),
        dayOf('2026-09-27', ['c']),
      ];
      final results = {'a': resultOf('finished'), 'b': resultOf('forfeit')};
      expect(recentResultsIndex(days, results, Day.parse('2026-09-27')), 1);
    });

    test('falls back to todayIndex when nothing is decided', () {
      final days = [
        dayOf('2026-09-20', ['a']),
        dayOf('2026-09-27', ['b']),
      ];
      expect(recentResultsIndex(days, const {}, Day.parse('2026-09-25')), 1);
    });

    test('a decided match strictly after today is never picked', () {
      final days = [
        dayOf('2026-09-20', ['a']),
        dayOf('2026-10-04', ['b']),
      ];
      final results = {'b': resultOf('finished')};
      // Nothing decided at/before today, so this falls back to todayIndex.
      expect(recentResultsIndex(days, results, Day.parse('2026-09-25')), 1);
    });
  });

  group('freshnessLabel', () {
    final fetched = DateTime.utc(2026, 9, 23, 10, 0);

    test('under a minute reads as právě teď', () {
      expect(
        freshnessLabel(fetched, fetched.add(const Duration(seconds: 30))),
        'právě teď',
      );
    });

    test('minutes', () {
      expect(
        freshnessLabel(fetched, fetched.add(const Duration(minutes: 20))),
        'před 20 min',
      );
    });

    test('an hour or more shows hours', () {
      expect(
        freshnessLabel(fetched, fetched.add(const Duration(hours: 3))),
        'před 3 h',
      );
      expect(
        freshnessLabel(fetched, fetched.add(const Duration(minutes: 60))),
        'před 1 h',
      );
    });
  });

  group('venuesMatching', () {
    Venue venue({
      required String name,
      String? address,
      List<String> clubs = const [],
    }) => Venue.fromJson({
      'id': name,
      'slug': name,
      'name': name,
      'address': address,
      'clubs': clubs,
      'fetched_at': '2026-09-23T01:00:00+00:00',
    });

    final venues = [
      venue(name: 'KS Devítka Brno', address: 'Kotlářská 21, Brno'),
      venue(
        name: 'TJ Sokol Husovice',
        address: 'Dukelská 1, Brno',
        clubs: const ['TJ Sokol Husovice'],
      ),
      venue(name: 'Áčko Blansko'),
    ];

    test('empty query returns everything, Czech-sorted by name', () {
      final result = venuesMatching(venues, '');
      expect(result.map((v) => v.name), [
        'Áčko Blansko',
        'KS Devítka Brno',
        'TJ Sokol Husovice',
      ]);
    });

    test('accent- and case-insensitive match on the name', () {
      final result = venuesMatching(venues, 'devitka');
      expect(result.map((v) => v.name), ['KS Devítka Brno']);
    });

    test('matches address too', () {
      final result = venuesMatching(venues, 'dukelska');
      expect(result.map((v) => v.name), ['TJ Sokol Husovice']);
    });

    test('matches clubs too', () {
      final result = venuesMatching(venues, 'husovice');
      expect(result.map((v) => v.name), ['TJ Sokol Husovice']);
    });

    test('no hit → empty', () {
      expect(venuesMatching(venues, 'nikdenic'), isEmpty);
    });
  });
}

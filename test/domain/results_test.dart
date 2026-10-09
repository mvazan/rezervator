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

  group('formatParts', () {
    test('TEAMS_OF_6 + T120', () {
      final f = formatParts('TEAMS_OF_6', 'T120');
      expect(f.players, 6);
      expect(f.throws, '120 HS');
    });
    test('TEAMS_OF_4 alone', () {
      final f = formatParts('TEAMS_OF_4', '');
      expect(f.players, 4);
      expect(f.throws, isNull);
    });
    test('unknown match type is null, discipline still reads', () {
      final f = formatParts('', 'T100');
      expect(f.players, isNull);
      expect(f.throws, '100 HS');
    });
    test('codes it does not know are null', () {
      final f = formatParts('MIXED', 'X1');
      expect(f.players, isNull);
      expect(f.throws, isNull);
    });
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

  group('isCorrectable', () {
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

    test('a finished match or a forfeit, within 14 days of its start', () {
      final later = start.add(const Duration(days: 3));
      expect(isCorrectable(slot(), result('finished'), later), isTrue);
      expect(isCorrectable(slot(), result('forfeit'), later), isTrue);
      expect(
        isCorrectable(
          slot(),
          result('finished'),
          start.add(const Duration(days: 13, hours: 23)),
        ),
        isTrue,
      );
    });

    test('not after 14 days, and never a match that is not final', () {
      expect(
        isCorrectable(
          slot(),
          result('finished'),
          start.add(const Duration(days: 14, minutes: 1)),
        ),
        isFalse,
      );
      expect(isCorrectable(slot(), result('in_progress'), start), isFalse);
      expect(isCorrectable(slot(), result('scheduled'), start), isFalse);
      expect(isCorrectable(slot(), null, start), isFalse);
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

    test('preparation is live until 12 hours after start', () {
      expect(
        isLive(
          slot(),
          result('preparation'),
          start.add(const Duration(hours: 2)),
        ),
        isTrue,
      );
      expect(
        isLive(
          slot(),
          result('preparation'),
          start.add(const Duration(hours: 12, minutes: 1)),
        ),
        isFalse,
      );
    });

    // The site shows preparation days before some matches: until an hour
    // before the start it reads like scheduled.
    test('preparation two weeks before the start is not live', () {
      expect(
        isLive(
          slot(),
          result('preparation'),
          start.subtract(const Duration(days: 14)),
        ),
        isFalse,
      );
    });

    test('preparation 2 hours before the start is not live yet', () {
      expect(
        isLive(
          slot(),
          result('preparation'),
          start.subtract(const Duration(hours: 2)),
        ),
        isFalse,
      );
    });

    test('preparation 30 minutes before the start is live', () {
      expect(
        isLive(
          slot(),
          result('preparation'),
          start.subtract(const Duration(minutes: 30)),
        ),
        isTrue,
      );
    });

    test('preparation 1 hour after the start is live', () {
      expect(
        isLive(
          slot(),
          result('preparation'),
          start.add(const Duration(hours: 1)),
        ),
        isTrue,
      );
    });

    test(
      'in_progress the site never closed stops being live after 12 hours',
      () {
        expect(
          isLive(
            slot(),
            result('in_progress'),
            start.add(const Duration(hours: 11, minutes: 59)),
          ),
          isTrue,
        );
        expect(
          isLive(
            slot(),
            result('in_progress'),
            start.add(const Duration(hours: 12, minutes: 1)),
          ),
          isFalse,
        );
      },
    );

    test('scheduled stays live until 6 hours after start', () {
      expect(
        isLive(
          slot(),
          result('scheduled'),
          start.add(const Duration(hours: 5, minutes: 59)),
        ),
        isTrue,
      );
      expect(
        isLive(
          slot(),
          result('scheduled'),
          start.add(const Duration(hours: 6, minutes: 1)),
        ),
        isFalse,
      );
    });

    test('forfeit is never live', () {
      expect(isLive(slot(), result('forfeit'), start), isFalse);
    });
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

    test('same-time matches of a day follow Czech order (H before Ch)', () {
      final days = resultsTimeline(
        slots: [
          match(
            id: 'ch',
            date: '2026-10-04',
            startsAt: '10:00:00',
            home: 'Chrudim',
            away: 'X',
          ),
          match(
            id: 'h',
            date: '2026-10-04',
            startsAt: '10:00:00',
            home: 'Hradec',
            away: 'Y',
          ),
        ],
        mineOnly: false,
        followedTeams: const [],
        exceptions: const {},
      );
      expect(days.single.matches.map((m) => m.title), [
        'Hradec – Y',
        'Chrudim – X',
      ]);
    });

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

  group('mostRecentDecidedMatchId', () {
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

    test('picks the LAST decided match across multiple days, not just the '
        'last day', () {
      final days = [
        dayOf('2026-09-13', ['a']),
        dayOf('2026-09-20', ['b']),
        dayOf('2026-09-27', ['c']),
      ];
      final results = {'a': resultOf('finished'), 'b': resultOf('forfeit')};
      expect(
        mostRecentDecidedMatchId(days, results, Day.parse('2026-09-27')),
        'b',
      );
    });

    test('ignores anything strictly after today', () {
      final days = [
        dayOf('2026-09-20', ['a']),
        dayOf('2026-10-04', ['b']),
      ];
      final results = {'a': resultOf('finished'), 'b': resultOf('finished')};
      expect(
        mostRecentDecidedMatchId(days, results, Day.parse('2026-09-25')),
        'a',
      );
    });

    test(
      'ignores non-decided statuses (scheduled/preparation/in_progress)',
      () {
        final days = [
          dayOf('2026-09-20', ['a', 'b', 'c']),
        ];
        final results = {
          'a': resultOf('scheduled'),
          'b': resultOf('preparation'),
          'c': resultOf('in_progress'),
        };
        expect(
          mostRecentDecidedMatchId(days, results, Day.parse('2026-09-27')),
          isNull,
        );
      },
    );

    test('null when nothing has been decided yet', () {
      final days = [
        dayOf('2026-09-20', ['a']),
      ];
      expect(
        mostRecentDecidedMatchId(days, const {}, Day.parse('2026-09-27')),
        isNull,
      );
    });

    test('a tie within one day is resolved by list order (already '
        'chronological)', () {
      final days = [
        dayOf('2026-09-20', ['a', 'b']),
      ];
      final results = {'a': resultOf('finished'), 'b': resultOf('forfeit')};
      expect(
        mostRecentDecidedMatchId(days, results, Day.parse('2026-09-27')),
        'b',
      );
    });
  });

  group('ageLabel', () {
    final fetched = DateTime.utc(2026, 9, 23, 10, 0);
    String age(Duration d) => ageLabel(fetched, fetched.add(d));

    test('without „před“: teď, minutes, hours', () {
      expect(age(const Duration(seconds: 30)), 'teď');
      expect(age(const Duration(minutes: 20)), '20 min');
      expect(age(const Duration(minutes: 59)), '59 min');
      expect(age(const Duration(hours: 1)), '1 h');
      expect(age(const Duration(hours: 23, minutes: 59)), '23 h');
    });

    test('days in the nominative, Czech agreement', () {
      expect(age(const Duration(days: 1)), '1 den');
      expect(age(const Duration(days: 3)), '3 dny');
      expect(age(const Duration(days: 5)), '5 dní');
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
      expect(
        freshnessLabel(fetched, fetched.add(const Duration(hours: 23))),
        'před 23 h',
      );
    });

    test('a day or more shows days', () {
      expect(
        freshnessLabel(fetched, fetched.add(const Duration(hours: 25))),
        'před 1 dnem',
      );
      expect(
        freshnessLabel(fetched, fetched.add(const Duration(days: 3))),
        'před 3 dny',
      );
      expect(
        freshnessLabel(fetched, fetched.add(const Duration(days: 18))),
        'před 18 dny',
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
      venue(name: 'Áčko Blansko', clubs: const ['SKK Veverky Brno']),
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
      final result = venuesMatching(venues, 'veverky');
      expect(result.map((v) => v.name), ['Áčko Blansko']);
    });

    test('no hit → empty', () {
      expect(venuesMatching(venues, 'nikdenic'), isEmpty);
    });
  });

  // Výsledky „Soutěže“ (0055): a whole competition by round, foreign matches
  // included.
  group('competition view', () {
    const matchType = PrioritySlotType(
      id: 'match-type',
      name: 'Zápas',
      isMatch: true,
    );
    const slug = 'liga-x-2026';

    PrioritySlot ours(
      int siteId,
      String date,
      int round, {
      String? parent,
      String comp = slug,
    }) =>
        PrioritySlot.fromJson({
          'id': 'slot$siteId',
          'date': date,
          'starts_at': '10:00:00',
          'ends_at': '13:00:00',
          'type_id': 'match-type',
          'home_team': 'Naše $siteId',
          'away_team': 'Soupeř',
          'description': '',
          'import_key': 'cka:$siteId',
          'site_slug': '$comp-kolo-$round-x-y',
          'site_match_id': siteId,
          'round': round,
          'parent_id': parent,
        }, {'match-type': matchType});

    LeagueMatch league(
      int siteId,
      String date,
      int round, {
      String? startsAt = '10:00:00',
      String comp = slug,
      String home = 'KK A',
      String away = 'KK B',
    }) => LeagueMatch.fromJson({
      'id': 'lg$siteId',
      'site_match_id': siteId,
      'site_slug': '$comp-kolo-$round-a-b',
      'competition_slug': comp,
      'competition': 'Liga X',
      'round': round,
      'date': date,
      'starts_at': startsAt,
      'home_team': home,
      'away_team': away,
      'status': 'finished',
      'home_points': 6,
      'away_points': 2,
      'home_total': 3200,
      'away_total': 3100,
      'fetched_at': '2026-09-20T10:00:00+00:00',
      'detail_status': null,
    });

    test('LeagueMatch: result, slot view, needs a detail once finished', () {
      final l = league(9001, '2026-10-10', 3);
      expect(l.result.matchId, 'lg9001');
      expect(l.result.status, MatchStatus.finished);
      expect(pointsLabel(l.result.homePoints, l.result.awayPoints), '6 : 2');
      expect(l.needsDetail, isTrue);
      final slot = l.asSlot();
      expect(slot.id, 'lg9001');
      expect(slot.fromFederation, isTrue);
      expect(slot.siteUrl, contains('$slug-kolo-3-a-b'));
      expect(slot.isAway, isFalse);
      // A match with no time yet.
      final timeless = league(9002, '2026-10-17', 4, startsAt: null);
      expect(timeless.timeKnown, isFalse);
      expect(timeless.asSlot().startsAt, const HourMinute(0, 0));
    });

    test('needsDetail: a final match whose lines are not final yet', () {
      LeagueMatch with_(String status, String? detail) => LeagueMatch.fromJson({
        'id': 'x',
        'site_match_id': 1,
        'site_slug': 's',
        'competition_slug': slug,
        'date': '2026-10-10',
        'starts_at': '10:00:00',
        'home_team': 'A',
        'away_team': 'B',
        'status': status,
        'fetched_at': '2026-10-10T10:00:00+00:00',
        'detail_status': detail,
      });
      expect(with_('finished', null).needsDetail, isTrue);
      expect(with_('finished', 'in_progress').needsDetail, isTrue);
      expect(with_('finished', 'finished').needsDetail, isFalse);
      // The detail settled on forfeit where the round page says finished.
      expect(with_('finished', 'forfeit').needsDetail, isFalse);
      expect(with_('scheduled', null).needsDetail, isFalse);
    });

    test('refreshable: from an hour before the start to 30 hours after it, '
        'whatever the stale status says; never final, never without a time', () {
      final l = league(1, '2026-10-10', 3, startsAt: '10:00:00');
      DateTime at(int day, int h, [int m = 0]) => DateTime(2026, 10, day, h, m);
      // The fixture's status is 'finished': not refreshable at all.
      expect(l.refreshable(at(10, 12)), isFalse);
      LeagueMatch open(String status, {String? startsAt = '10:00:00'}) =>
          LeagueMatch.fromJson({
            'id': 'x',
            'site_match_id': 1,
            'site_slug': 's',
            'competition_slug': slug,
            'date': '2026-10-10',
            'starts_at': startsAt,
            'home_team': 'A',
            'away_team': 'B',
            'status': status,
            'fetched_at': '2026-10-10T10:00:00+00:00',
          });
      final scheduled = open('scheduled');
      expect(scheduled.refreshable(at(10, 8, 30)), isFalse, reason: '1.5 h before');
      expect(scheduled.refreshable(at(10, 9, 30)), isTrue, reason: '30 min before');
      expect(scheduled.refreshable(at(10, 18)), isTrue, reason: '8 h after');
      expect(scheduled.refreshable(at(11, 15)), isTrue, reason: '29 h after');
      expect(scheduled.refreshable(at(11, 17)), isFalse, reason: '31 h after');
      expect(open('in_progress').refreshable(at(10, 11)), isTrue);
      expect(open('forfeit').refreshable(at(10, 11)), isFalse);
      expect(open('scheduled', startsAt: null).refreshable(at(10, 11)), isFalse);
    });

    test('a match with no time yet is never live', () {
      final timeless = league(1, '2026-10-10', 3, startsAt: null);
      final scheduled = MatchResult(
        matchId: 'lg1',
        status: MatchStatus.scheduled,
        fetchedAt: DateTime.utc(2026, 10, 9),
      );
      // Ten past midnight of its day would be „one hour before 00:00“.
      expect(
        isLive(timeless.asSlot(), scheduled, DateTime(2026, 10, 10, 0, 10)),
        isFalse,
      );
      expect(
        isLive(
          league(2, '2026-10-10', 3).asSlot(),
          scheduled,
          DateTime(2026, 10, 10, 9, 30),
        ),
        isTrue,
      );
    });

    test('our matches of the competition plus the league ones, once', () {
      final slots = [
        ours(1, '2026-10-10', 3),
        ours(2, '2026-10-10', 3, parent: 'slot1'),
        ours(3, '2026-10-10', 3, comp: 'other-comp'),
        ours(4, '2026-10-10', 3),
      ];
      final r = competitionMatches(slots, [
        league(9001, '2026-10-10', 3),
        league(9004, '2026-10-10', 3, comp: 'other'),
      ], slug);
      expect(r.matches.map((m) => m.id), ['slot1', 'slot4', 'lg9001']);
      expect(r.foreignIds, {'lg9001'});
    });

    test('a switched-off team\'s slot that also has a league row (same site '
        'id) is one tile: the league one', () {
      final slots = [
        ours(1, '2026-10-10', 3),
        ours(2, '2026-10-17', 4),
      ];
      final r = competitionMatches(slots, [
        // The server kept the row (with its details) of the switched-off
        // team's match; the slot 1 of the same site match is not listed.
        league(1, '2026-10-10', 3),
      ], slug);
      expect(r.matches.map((m) => m.id), ['slot2', 'lg1']);
      expect(r.foreignIds, {'lg1'});
    });

    test('rounds are grouped and ordered by their dates, not their numbers', () {
      final all = competitionMatches([
        ours(1, '2026-10-17', 4),
        ours(2, '2026-10-03', 5),
      ], [
        league(9001, '2026-10-10', 3, home: 'KK Hvězda'),
        league(9002, '2026-10-10', 3, home: 'KK Chodov', away: 'KK C'),
        league(9003, '2026-10-03', 5, startsAt: '09:00:00'),
      ], slug).matches;
      final rounds = competitionRounds(all);
      // 5th round first (3. 10.), then the 3rd (10. 10.), the 4th (17. 10.).
      expect(rounds.map((g) => g.round), [5, 3, 4]);
      expect(rounds[0].matches.map((m) => m.id), ['lg9003', 'slot2']);
      // Inside a round: the same time → Czech title order (H before Ch,
      // which plain compareTo gets the other way round).
      expect(rounds[1].matches.map((m) => m.homeTeam), ['KK Hvězda', 'KK Chodov']);
    });

    test('a round played over several days spans them', () {
      final rounds = competitionRounds([
        league(1, '2026-10-10', 3).asSlot(),
        league(2, '2026-10-11', 3).asSlot(),
      ]);
      expect(rounds.single.first, Day(2026, 10, 10));
      expect(rounds.single.last, Day(2026, 10, 11));
      expect(roundLabel(rounds.single), '3. kolo · 10.10.–11.10.');
      expect(
        roundLabel(competitionRounds([league(1, '2026-10-10', 3).asSlot()]).single),
        '3. kolo · 10. 10.',
      );
    });

    test('the last decided match is found in display order, not by day list', () {
      final all = competitionMatches([
        ours(1, '2026-10-03', 5),
        ours(2, '2026-10-10', 3),
      ], const [], slug).matches;
      final results = {
        'slot1': MatchResult(
          matchId: 'slot1',
          status: MatchStatus.finished,
          fetchedAt: DateTime.utc(2026, 10, 4),
        ),
        'slot2': MatchResult(
          matchId: 'slot2',
          status: MatchStatus.scheduled,
          fetchedAt: DateTime.utc(2026, 10, 4),
        ),
      };
      final ordered = [for (final g in competitionRounds(all)) ...g.matches];
      expect(mostRecentDecidedInOrder(ordered, results, Day(2026, 10, 12)), 'slot1');
      expect(mostRecentDecidedInOrder(ordered, results, Day(2026, 10, 1)), isNull);
    });
  });
}

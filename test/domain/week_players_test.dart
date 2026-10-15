import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/week_players.dart';

/// „Hráči týdne“ (0078): the pure half — the server's rows, the rankings
/// (one entry per player, best first, ties), the categories, groups and
/// filters, the week before today in Prague and its label, and the read
/// with the gender lookups. Every date is fixed; nothing reads the clock.
/// Run with TZ=Europe/Prague, as the whole suite.
void main() {
  WeekLine line(
    String name,
    int total, {
    String? slug,
    int errors = 0,
    int? throws = 120,
    WeekGender? gender = WeekGender.male,
    bool away = false,
    String? competition = 'Divize AS',
    String team = 'Termínátor A',
    String match = 'm1',
    String? clubId,
    String? clubName,
    int clubColor = -1,
  }) => WeekLine(
    matchId: match,
    date: Day(2026, 10, 10),
    playerName: name,
    playerSlug: slug ?? name.toLowerCase().replaceAll(' ', '-'),
    total: total,
    errors: errors,
    throws: throws,
    isAway: away,
    competition: competition,
    teamName: team,
    opponent: 'KK Slavoj',
    clubId: clubId,
    clubName: clubName,
    clubColor: clubColor,
    gender: gender,
  );

  List<String> names(List<WeekLine> lines) => [
    for (final l in lines) l.playerName,
  ];

  group('WeekLine.fromJson', () {
    test('reads a kiosk_week_players row', () {
      final l = WeekLine.fromJson({
        'match_id': 'a1b2',
        'date': '2026-10-10',
        'player_name': 'Jan Novák',
        'player_slug': 'jan-novak',
        'total': 598,
        'errors': 3,
        'throws': 120,
        'is_away': true,
        'competition': 'Divize AS',
        'team_name': 'Termínátor A',
        'opponent': 'KK Slavoj',
        'club_id': 'c1',
        'club_name': 'Termínátor',
        'club_color': 4,
        'gender': 'm',
      });
      expect(l.matchId, 'a1b2');
      expect(l.date, Day(2026, 10, 10));
      expect(l.playerName, 'Jan Novák');
      expect(l.playerSlug, 'jan-novak');
      expect(l.total, 598);
      expect(l.errors, 3);
      expect(l.throws, 120);
      expect(l.isAway, isTrue);
      expect(l.competition, 'Divize AS');
      expect(l.teamName, 'Termínátor A');
      expect(l.opponent, 'KK Slavoj');
      expect(l.clubId, 'c1');
      expect(l.clubName, 'Termínátor');
      expect(l.clubColor, 4);
      expect(l.gender, WeekGender.male);
      expect(l.key, 'jan-novak');
      expect(l.needsGender, isFalse);
    });

    test('nulls and unknowns: no slug keys by the name, a gender other '
        'than m/f is unknown, no club is -1', () {
      final l = WeekLine.fromJson({
        'match_id': 'a1b2',
        'date': '2026-10-10',
        'player_name': 'Jana Pavlů',
        'player_slug': '',
        'total': 401,
        'errors': null,
        'throws': null,
        'is_away': false,
        'competition': null,
        'team_name': 'Termínátor B',
        'opponent': 'TJ Sokol',
        'club_id': null,
        'club_name': null,
        'club_color': -1,
        'gender': 'x',
      });
      expect(l.playerSlug, isNull);
      expect(l.key, 'Jana Pavlů');
      expect(l.errors, 0);
      expect(l.throws, isNull);
      expect(l.competition, isNull);
      expect(l.clubId, isNull);
      expect(l.clubColor, -1);
      expect(l.gender, isNull);
      // Without a slug the register is never asked.
      expect(l.needsGender, isFalse);
      expect(
        WeekLine.fromJson({
          'match_id': 'a',
          'date': '2026-10-10',
          'player_name': 'Jana Pavlů',
          'player_slug': 'jana-pavlu',
          'total': 401,
          'gender': 'f',
        }).gender,
        WeekGender.female,
      );
      expect(line('Petr Malý', 500, gender: null).needsGender, isTrue);
    });
  });

  group('weekRanked', () {
    test('best first: more pins, then fewer errors, then the name in Czech '
        'order', () {
      final ranked = weekRanked([
        line('Zdeněk Říha', 540),
        line('Šimon Hrubý', 560, errors: 4),
        line('Adam Čech', 560, errors: 2),
        line('Cyril Bárta', 560, errors: 4),
      ]);
      // Cyril before Šimon: equal pins and errors, C before Š.
      expect(names(ranked), [
        'Adam Čech',
        'Cyril Bárta',
        'Šimon Hrubý',
        'Zdeněk Říha',
      ]);
    });

    test('one entry per player — his best line; two matches in a week do '
        'not take two places', () {
      final ranked = weekRanked([
        line('Jan Novák', 540, match: 'm1'),
        line('Petr Malý', 550, match: 'm1'),
        line('Jan Novák', 571, match: 'm2'),
        line('Jan Novák', 571, errors: 1, match: 'm3'),
      ]);
      expect(names(ranked), ['Jan Novák', 'Petr Malý']);
      expect(ranked.first.matchId, 'm2');
      expect(ranked.first.total, 571);
    });

    test('by the slug: two players of one name are two entries; without '
        'slugs the name is the player', () {
      final twoJans = weekRanked([
        line('Jan Novák', 540, slug: 'jan-novak'),
        line('Jan Novák', 530, slug: 'jan-novak-2'),
      ]);
      expect(twoJans.length, 2);
      final noSlugs = weekRanked([
        WeekLine(
          matchId: 'm1',
          date: Day(2026, 10, 6),
          playerName: 'Jan Novák',
          total: 540,
        ),
        WeekLine(
          matchId: 'm2',
          date: Day(2026, 10, 10),
          playerName: 'Jan Novák',
          total: 560,
        ),
      ]);
      expect(noSlugs.single.matchId, 'm2');
    });

    test('weekPlaces: equal pins and errors share a place, the next one '
        'skips it', () {
      final ranked = weekRanked([
        line('A', 600),
        line('B', 580, errors: 2),
        line('C', 580, errors: 2),
        line('D', 580, errors: 5),
        line('E', 570),
      ]);
      expect(weekPlaces(ranked), [1, 2, 2, 4, 5]);
      expect(weekPlaces(const []), isEmpty);
    });
  });

  group('categories, groups, filters', () {
    test('weekCategories: Muži 120, Ženy 120, Muži 100, Ženy 100 — empty '
        'ones left out, unknown gender or throws in none', () {
      final categories = weekCategories([
        line('Jana Pavlů', 410, throws: 100, gender: WeekGender.female),
        line('Tomáš Pavlů', 590),
        line('Petr Malý', 600),
        line('Bez Pohlaví', 650, gender: null),
        line('Bez Hodů', 650, throws: null),
        line('Eva Malá', 520, gender: WeekGender.female),
      ]);
      expect(categories.keys, [
        WeekCategory.men120,
        WeekCategory.women120,
        WeekCategory.women100,
      ]);
      expect(names(categories[WeekCategory.men120]!), [
        'Petr Malý',
        'Tomáš Pavlů',
      ]);
      expect(names(categories[WeekCategory.women120]!), ['Eva Malá']);
      expect(names(categories[WeekCategory.women100]!), ['Jana Pavlů']);
      expect(WeekCategory.men120.label, 'Muži · 120 HS');
      expect(WeekCategory.women100.label, 'Ženy · 100 HS');
      expect(weekCategories(const []), isEmpty);
    });

    test('weekByCompetition: groups in Czech order, each ranked, every '
        'line in one — unknown gender too; none named last', () {
      final groups = weekByCompetition([
        line('A', 500, competition: 'Divize AS'),
        line('B', 520, competition: 'Česká liga', gender: null),
        line('C', 510, competition: 'Celostátní liga', throws: null),
        line('D', 530, competition: 'Divize AS'),
        line('E', 480, competition: null),
      ]);
      expect([for (final g in groups) g.name], [
        'Celostátní liga',
        'Česká liga',
        'Divize AS',
        weekOtherGroup,
      ]);
      expect(names(groups[2].lines), ['D', 'A']);
      expect(names(groups.last.lines), ['E']);
    });

    test('weekByClub: by our team\'s club, Czech order, with its colour; '
        'teams without a club last', () {
      final groups = weekByClub([
        line('A', 500, clubId: 's', clubName: 'Sokol', clubColor: 2),
        line('B', 520, clubId: 'c', clubName: 'Čechie', clubColor: 5),
        line('C', 540),
        line('D', 560, clubId: 's', clubName: 'Sokol', clubColor: 2),
      ]);
      expect([for (final g in groups) g.name], [
        'Čechie',
        'Sokol',
        weekOtherGroup,
      ]);
      expect([for (final g in groups) g.color], [5, 2, -1]);
      expect(names(groups[1].lines), ['D', 'A']);
    });

    test('weekWhere: home, away or all', () {
      final lines = [
        line('Doma', 500),
        line('Venku', 510, away: true),
      ];
      expect(names(weekWhere(lines)), ['Doma', 'Venku']);
      expect(names(weekWhere(lines, away: false)), ['Doma']);
      expect(names(weekWhere(lines, away: true)), ['Venku']);
    });
  });

  group('the week', () {
    test('previousWeekMonday: the Monday of the week before, from Monday '
        '00:00 on', () {
      // Thursday.
      expect(previousWeekMonday(DateTime(2026, 10, 15, 12)), Day(2026, 10, 5));
      // Monday just past midnight: last week is the one that just ended.
      expect(previousWeekMonday(DateTime(2026, 10, 12, 0, 30)), Day(2026, 10, 5));
      // Sunday late: the week is still on, the one before it shows.
      expect(previousWeekMonday(DateTime(2026, 10, 11, 23, 30)), Day(2026, 9, 28));
    });

    test('previousWeekMonday reads a UTC instant on the Prague clock', () {
      // Monday 00:30 in Prague (CEST, UTC+2) is still Sunday in UTC.
      expect(
        previousWeekMonday(DateTime.utc(2026, 10, 11, 22, 30)),
        Day(2026, 10, 5),
      );
      // Sunday 23:30 in Prague.
      expect(
        previousWeekMonday(DateTime.utc(2026, 10, 11, 21, 30)),
        Day(2026, 9, 28),
      );
      // Monday 00:30 after the clocks went back (CET, UTC+1).
      expect(
        previousWeekMonday(DateTime.utc(2026, 10, 25, 23, 30)),
        Day(2026, 10, 19),
      );
    });

    test('weekRangeLabel: the month once when shared', () {
      expect(weekRangeLabel(Day(2026, 10, 5)), '5.–11. 10.');
      expect(weekRangeLabel(Day(2026, 9, 28)), '28. 9.–4. 10.');
      expect(weekRangeLabel(Day(2026, 12, 28)), '28. 12.–3. 1.');
    });
  });

  group('loadWeekLines', () {
    final monday = Day(2026, 10, 5);

    test('every line with a slug has its gender: one read, no lookup', () async {
      var reads = 0;
      var lookups = 0;
      final lines = await loadWeekLines(
        monday,
        read: (m) async {
          expect(m, monday);
          reads++;
          return [
            line('Jan Novák', 500),
            WeekLine(
              matchId: 'm1',
              date: monday,
              playerName: 'Bez Slugu',
              total: 480,
            ),
          ];
        },
        lookup: (_) async {
          lookups++;
          return false;
        },
      );
      expect(reads, 1);
      expect(lookups, 0);
      expect(lines.length, 2);
    });

    test('a gender missing: asks while there is more, at most four times, '
        'then reads again', () async {
      var reads = 0;
      var lookups = 0;
      final lines = await loadWeekLines(
        monday,
        read: (_) async {
          reads++;
          return [
            line('Jan Novák', 500, gender: reads == 1 ? null : WeekGender.male),
          ];
        },
        lookup: (m) async {
          expect(m, monday);
          lookups++;
          return true;
        },
      );
      expect(lookups, weekGenderRounds);
      expect(reads, 2);
      expect(lines.single.gender, WeekGender.male);
    });

    test('the lookup done in one round: no second ask', () async {
      var lookups = 0;
      await loadWeekLines(
        monday,
        read: (_) async => [line('Jan Novák', 500, gender: null)],
        lookup: (_) async {
          lookups++;
          return false;
        },
      );
      expect(lookups, 1);
    });

    test('a failed lookup still reads again (an earlier round may have '
        'found some); a failed second read keeps the first', () async {
      final errors = <Object>[];
      var reads = 0;
      final again = await loadWeekLines(
        monday,
        read: (_) async {
          reads++;
          return [line('Jan Novák', 500 + reads, gender: null)];
        },
        lookup: (_) async => throw StateError('offline'),
        onError: errors.add,
      );
      expect(reads, 2);
      expect(again.single.total, 502);
      expect(errors.single, isA<StateError>());

      errors.clear();
      reads = 0;
      final first = await loadWeekLines(
        monday,
        read: (_) async {
          if (++reads > 1) throw StateError('offline');
          return [line('Jan Novák', 500, gender: null)];
        },
        lookup: (_) async => false,
        onError: errors.add,
      );
      expect(first.single.total, 500);
      expect(errors.single, isA<StateError>());
    });

    test('a failed first read is the caller\'s error', () async {
      await expectLater(
        loadWeekLines(
          monday,
          read: (_) async => throw StateError('offline'),
          lookup: (_) async => false,
        ),
        throwsStateError,
      );
    });
  });
}

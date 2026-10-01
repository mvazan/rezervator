import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/duties.dart';
import 'package:rezervator/domain/models.dart';

/// Služby na kantýně (0050): the pure half — the generator's preview, the
/// seasons, the counts, the week header and "my duty". Every date is fixed;
/// nothing here reads the clock.
void main() {
  DutyPeriod period(String id, Day from, Day to, {String note = ''}) =>
      DutyPeriod(id: id, startsOn: from, endsOn: to, note: note);
  DutyAssignment assign(String periodId, String userId) =>
      DutyAssignment(periodId: periodId, userId: userId);

  group('labels', () {
    test('dutyDayLabel writes „po 5. 10.“', () {
      expect(dutyDayLabel(Day(2026, 10, 5)), 'po 5. 10.');
      expect(dutyDayLabel(Day(2026, 10, 11)), 'ne 11. 10.');
    });

    test('dutyRangeLabel: „po 5. 10. – ne 11. 10.“, one day named once', () {
      expect(
        dutyRangeLabel(period('a', Day(2026, 10, 5), Day(2026, 10, 11))),
        'po 5. 10. – ne 11. 10.',
      );
      expect(
        dutyRangeLabel(period('a', Day(2026, 10, 10), Day(2026, 10, 10))),
        'so 10. 10.',
      );
    });

    test('joinNames: „A“, „A a B“, „A, B a C“', () {
      expect(joinNames(const []), '');
      expect(joinNames(const ['Jan Novák']), 'Jan Novák');
      expect(
        joinNames(const ['Jan Novák', 'Petr Svoboda']),
        'Jan Novák a Petr Svoboda',
      );
      expect(
        joinNames(const ['Adam Beneš', 'Jan Novák', 'Petr Svoboda']),
        'Adam Beneš, Jan Novák a Petr Svoboda',
      );
    });

    test('dutyCountLabel: „3 služby · 21 dní (2 odslouženy)“, zero „—“', () {
      expect(dutyCountLabel(DutyCount.zero), '—');
      expect(
        dutyCountLabel(const DutyCount(duties: 3, days: 21, served: 2)),
        '3 služby · 21 dní (2 odslouženy)',
      );
      expect(
        dutyCountLabel(const DutyCount(duties: 1, days: 7, served: 1)),
        '1 služba · 7 dní (1 odsloužena)',
      );
      expect(
        dutyCountLabel(const DutyCount(duties: 5, days: 35, served: 5)),
        '5 služeb · 35 dní (5 odslouženo)',
      );
      // Nothing served yet: no parenthesis at all.
      expect(
        dutyCountLabel(const DutyCount(duties: 1, days: 1)),
        '1 služba · 1 den',
      );
      expect(
        dutyCountLabel(const DutyCount(duties: 2, days: 2)),
        '2 služby · 2 dny',
      );
    });
  });

  group('planDutyPeriods mirrors duty_generate', () {
    // Tuesday — „Týdně, mění se v út“.
    final tue = Day(2026, 10, 6);

    test('weekly from a Tuesday: consecutive periods, the last clipped', () {
      final plan = planDutyPeriods(tue, 7, Day(2026, 10, 22), const []);
      expect(plan.error, isNull);
      expect(plan.created, 3);
      expect(plan.skipped, 0);
      expect(
        [for (final p in plan.periods) '${p.startsOn}..${p.endsOn}'],
        [
          '2026-10-06..2026-10-12',
          '2026-10-13..2026-10-19',
          '2026-10-20..2026-10-22',
        ],
      );
      expect(plan.lastClippedDays, 3);
    });

    test('a range that ends on a period boundary clips nothing', () {
      final plan = planDutyPeriods(tue, 7, Day(2026, 10, 26), const []);
      expect(plan.created, 3);
      expect(plan.periods.last.endsOn, Day(2026, 10, 26));
      expect(plan.lastClippedDays, isNull);
    });

    test('a period overlapping an existing one is skipped whole', () {
      final plan = planDutyPeriods(tue, 7, Day(2026, 10, 26), [
        period('x', Day(2026, 10, 14), Day(2026, 10, 15)),
      ]);
      expect(plan.created, 2);
      expect(plan.skipped, 1);
      expect(
        [for (final p in plan.periods) p.startsOn],
        [Day(2026, 10, 6), Day(2026, 10, 20)],
      );
    });

    test('touching an existing period on its last day is an overlap', () {
      // Both ends are included, like daterange(…, '[]') in SQL.
      final plan = planDutyPeriods(tue, 7, Day(2026, 10, 12), [
        period('x', Day(2026, 10, 1), Day(2026, 10, 6)),
      ]);
      expect(plan.created, 0);
      expect(plan.skipped, 1);
    });

    test('running it again over what it created creates nothing', () {
      final first = planDutyPeriods(tue, 7, Day(2026, 10, 22), const []);
      final existing = [
        for (final (i, p) in first.periods.indexed)
          period('p$i', p.startsOn, p.endsOn),
      ];
      final again = planDutyPeriods(tue, 7, Day(2026, 10, 22), existing);
      expect(again.created, 0);
      expect(again.skipped, 3);
      expect(again.lastClippedDays, isNull);
    });

    test('a clipped last period that is skipped reports no clip', () {
      final plan = planDutyPeriods(tue, 7, Day(2026, 10, 22), [
        period('x', Day(2026, 10, 21), Day(2026, 10, 21)),
      ]);
      expect(plan.created, 2);
      expect(plan.skipped, 1);
      expect(plan.lastClippedDays, isNull);
    });

    test('„Po N dnech“: N-day periods, one-day ones too', () {
      final plan = planDutyPeriods(tue, 1, Day(2026, 10, 8), const []);
      expect(plan.created, 3);
      expect(
        [for (final p in plan.periods) p.startsOn == p.endsOn],
        [true, true, true],
      );
      expect(plan.lastClippedDays, isNull);
    });

    test('a one-day range: one period of that day', () {
      final plan = planDutyPeriods(tue, 7, tue, const []);
      expect(plan.created, 1);
      expect(plan.periods.single.endsOn, tue);
      expect(plan.lastClippedDays, 1);
    });

    test(
      'the SQL errors: days 1–31, the range forward and at most 400 days',
      () {
        expect(
          planDutyPeriods(tue, 0, Day(2026, 10, 22), const []).error,
          'invalid_days',
        );
        expect(
          planDutyPeriods(tue, 32, Day(2026, 10, 22), const []).error,
          'invalid_days',
        );
        expect(
          planDutyPeriods(tue, 7, Day(2026, 10, 5), const []).error,
          'invalid_range',
        );
        // 400 days with both ends counted is fine, 401 is not.
        expect(
          planDutyPeriods(tue, 7, tue.addDays(399), const []).error,
          isNull,
        );
        expect(
          planDutyPeriods(tue, 7, tue.addDays(400), const []).error,
          'invalid_range',
        );
        final bad = planDutyPeriods(tue, 0, Day(2026, 10, 22), const []);
        expect(bad.created, 0);
        expect(bad.skipped, 0);
        expect(bad.lastClippedDays, isNull);
      },
    );
  });

  group('periodOn', () {
    final periods = [
      period('a', Day(2026, 10, 6), Day(2026, 10, 12)),
      period('b', Day(2026, 10, 13), Day(2026, 10, 19)),
    ];

    test('finds the period covering a day, both ends included', () {
      expect(periodOn(periods, Day(2026, 10, 6))?.id, 'a');
      expect(periodOn(periods, Day(2026, 10, 12))?.id, 'a');
      expect(periodOn(periods, Day(2026, 10, 13))?.id, 'b');
    });

    test('null in a gap', () {
      expect(periodOn(periods, Day(2026, 10, 5)), isNull);
      expect(periodOn(periods, Day(2026, 10, 20)), isNull);
    });
  });

  group('assigneeIds', () {
    test('the users of one period, in no particular order', () {
      final ids = assigneeIds([
        assign('a', 'jan'),
        assign('b', 'petr'),
        assign('a', 'jana'),
      ], 'a');
      expect(ids.toSet(), {'jan', 'jana'});
    });
  });

  group('seasons', () {
    final s25 = DutySeason(startedOn: Day(2025, 9, 1), name: '2025/26');
    final s26 = DutySeason(startedOn: Day(2026, 9, 1), name: '2026/27');

    test('no boundary: one implicit season, open on both ends', () {
      final ranges = seasonRanges(const []);
      expect(ranges, hasLength(1));
      expect(ranges.single.isImplicit, isTrue);
      expect(ranges.single.name, isNull);
      expect(ranges.single.from, isNull);
      expect(ranges.single.until, isNull);
      expect(ranges.single.contains(Day(2000, 1, 1)), isTrue);
    });

    test(
      'boundaries sorted chronologically after the implicit first season',
      () {
        final ranges = seasonRanges([s26, s25]);
        expect([for (final r in ranges) r.name], [null, '2025/26', '2026/27']);
        expect(ranges[0].from, isNull);
        expect(ranges[0].until, Day(2025, 8, 31));
        expect(ranges[1].from, Day(2025, 9, 1));
        expect(ranges[1].until, Day(2026, 8, 31));
        expect(ranges[2].from, Day(2026, 9, 1));
        expect(ranges[2].until, isNull);
      },
    );

    test('a period belongs to the season it starts in', () {
      final ranges = seasonRanges([s25, s26]);
      final straddling = period('x', Day(2026, 8, 28), Day(2026, 9, 3));
      expect(ranges[1].containsPeriod(straddling), isTrue);
      expect(ranges[2].containsPeriod(straddling), isFalse);
    });

    test('currentSeason: the range holding today, not a future boundary', () {
      final future = DutySeason(startedOn: Day(2026, 11, 1), name: 'zimní');
      final ranges = seasonRanges([s25, s26, future]);
      expect(currentSeason(ranges, Day(2026, 9, 26)).name, '2026/27');
      expect(currentSeason(ranges, Day(2026, 11, 1)).name, 'zimní');
      expect(currentSeason(ranges, Day(2020, 1, 1)).isImplicit, isTrue);
    });

    test('seasonNameFor: the July–June year, „2026/27“', () {
      expect(seasonNameFor(Day(2026, 9, 26)), '2026/27');
      expect(seasonNameFor(Day(2027, 3, 1)), '2026/27');
      expect(seasonNameFor(Day(2026, 7, 1)), '2026/27');
      expect(seasonNameFor(Day(2026, 6, 30)), '2025/26');
      expect(seasonNameFor(Day(2099, 12, 31)), '2099/00');
      expect(seasonNameFor(Day(2000, 7, 1)), '2000/01');
    });

    test('seasonEndFor: the next 30. 6., today included', () {
      expect(seasonEndFor(Day(2026, 9, 26)), Day(2027, 6, 30));
      expect(seasonEndFor(Day(2027, 6, 30)), Day(2027, 6, 30));
      expect(seasonEndFor(Day(2027, 7, 1)), Day(2028, 6, 30));
      expect(seasonEndFor(Day(2027, 1, 15)), Day(2027, 6, 30));
    });
  });

  group('dutyCounts', () {
    final lastSeason = period('d', Day(2026, 8, 24), Day(2026, 8, 30));
    final past = period('a', Day(2026, 9, 7), Day(2026, 9, 13));
    final running = period('b', Day(2026, 9, 21), Day(2026, 9, 27));
    final future = period('c', Day(2026, 10, 5), Day(2026, 10, 11));
    final periods = [future, lastSeason, running, past];
    final assignments = [
      assign('a', 'jana'),
      assign('b', 'jana'),
      assign('c', 'jana'),
      assign('d', 'jana'),
      assign('b', 'petr'),
      assign('c', 'bez-uctu'),
      assign('gone', 'petr'),
    ];
    final ranges = seasonRanges([
      DutySeason(startedOn: Day(2026, 9, 1), name: '2026/27'),
    ]);

    test('counts the season\'s periods per player: duties, days, served', () {
      final counts = dutyCounts(
        periods,
        assignments,
        ranges.last,
        today: Day(2026, 9, 26),
      );
      expect(counts.keys.toSet(), {'jana', 'petr', 'bez-uctu'});
      expect(counts['jana'], const DutyCount(duties: 3, days: 21, served: 1));
      expect(counts['petr'], const DutyCount(duties: 1, days: 7));
      expect(counts['bez-uctu'], const DutyCount(duties: 1, days: 7));
    });

    test('a duty is served once its last day is over', () {
      final onLastDay = dutyCounts(
        periods,
        assignments,
        ranges.last,
        today: Day(2026, 9, 27),
      );
      expect(onLastDay['petr']!.served, 0);
      final dayAfter = dutyCounts(
        periods,
        assignments,
        ranges.last,
        today: Day(2026, 9, 28),
      );
      expect(dayAfter['petr']!.served, 1);
    });

    test('the implicit first season holds what came before the boundary', () {
      final counts = dutyCounts(
        periods,
        assignments,
        ranges.first,
        today: Day(2026, 9, 26),
      );
      expect(counts, {'jana': const DutyCount(duties: 1, days: 7, served: 1)});
    });

    test('a new season starts everyone at zero', () {
      final later = seasonRanges([
        DutySeason(startedOn: Day(2026, 9, 1), name: '2026/27'),
        DutySeason(startedOn: Day(2026, 12, 1), name: 'zimní'),
      ]);
      expect(
        dutyCounts(periods, assignments, later.last, today: Day(2026, 12, 1)),
        isEmpty,
      );
    });
  });

  group('dutyHeaderLabel', () {
    final monday = Day(2026, 10, 5);
    const names = {
      'jan': 'Jan Novák',
      'petr': 'Petr Svoboda',
      'adam': 'Adam Beneš',
      'cyril': 'Čestmír Cimrman',
    };
    final farToday = Day(2026, 9, 1);

    DutyHeader? label(
      List<DutyPeriod> periods,
      List<DutyAssignment> assignments, {
      String? me = 'someone-else',
      Day? today,
      Day? week,
    }) => dutyHeaderLabel(
      week ?? monday,
      periods,
      assignments,
      names,
      me,
      today: today ?? farToday,
    );

    test(
      'one period for the whole week: „Služba: Jan Novák a Petr Svoboda“',
      () {
        final h = label(
          [period('a', monday, monday.addDays(6))],
          [assign('a', 'petr'), assign('a', 'jan')],
        );
        expect(h?.text, 'Služba: Jan Novák a Petr Svoboda');
        expect(h?.mine, isFalse);
      },
    );

    test('a period reaching past both ends of the week is the whole week', () {
      final h = label(
        [period('a', Day(2026, 10, 1), Day(2026, 10, 14))],
        [assign('a', 'jan'), assign('a', 'petr'), assign('a', 'adam')],
      );
      expect(h?.text, 'Služba: Adam Beneš, Jan Novák a Petr Svoboda');
    });

    test('names are sorted Czech-alphabetically (Č after C)', () {
      final h = label(
        [period('a', monday, monday.addDays(6))],
        [assign('a', 'cyril'), assign('a', 'jan')],
      );
      expect(h?.text, 'Služba: Čestmír Cimrman a Jan Novák');
    });

    test(
      'a change inside the week: „po–st Jan Novák · čt–ne Petr Svoboda“',
      () {
        final h = label(
          [
            period('b', Day(2026, 10, 8), Day(2026, 10, 14)),
            period('a', Day(2026, 10, 1), Day(2026, 10, 7)),
          ],
          [assign('a', 'jan'), assign('b', 'petr')],
        );
        expect(h?.text, 'Služba: po–st Jan Novák · čt–ne Petr Svoboda');
      },
    );

    test('two adjacent periods of mine are one part, not „po–st ty · čt–ne ty“',
        () {
      final h = label(
        [
          period('a', Day(2026, 10, 1), Day(2026, 10, 7)),
          period('b', Day(2026, 10, 8), Day(2026, 10, 14)),
        ],
        [assign('a', 'jan'), assign('b', 'jan')],
        me: 'jan',
      );
      expect(h?.text, 'Služba: po–ne ty');
    });

    test('adjacent periods with the same names merge; the names keep their '
        'order, and a different pair stays apart', () {
      final same = label(
        [
          period('a', Day(2026, 10, 1), Day(2026, 10, 7)),
          period('b', Day(2026, 10, 8), Day(2026, 10, 14)),
        ],
        [
          assign('a', 'jan'), assign('a', 'petr'),
          assign('b', 'petr'), assign('b', 'jan'),
        ],
        me: 'jan',
      );
      expect(same?.text, 'Služba: po–ne Petr Svoboda a ty');
      final firstDays = label(
        [
          period('a', Day(2026, 10, 1), Day(2026, 10, 5)),
          period('b', Day(2026, 10, 6), Day(2026, 10, 8)),
          period('c', Day(2026, 10, 9), Day(2026, 10, 14)),
        ],
        [assign('a', 'jan'), assign('b', 'jan'), assign('c', 'petr')],
      );
      expect(firstDays?.text, 'Služba: po–čt Jan Novák · pá–ne Petr Svoboda');
    });

    test('three adjacent periods with the same names are one part', () {
      final h = label(
        [
          period('a', Day(2026, 10, 5), Day(2026, 10, 6)),
          period('b', Day(2026, 10, 7), Day(2026, 10, 9)),
          period('c', Day(2026, 10, 10), Day(2026, 10, 11)),
        ],
        [assign('a', 'jan'), assign('b', 'jan'), assign('c', 'jan')],
      );
      expect(h?.text, 'Služba: po–ne Jan Novák');
    });

    test('the same names with a gap between the periods stay two parts', () {
      final h = label(
        [
          period('a', Day(2026, 10, 5), Day(2026, 10, 6)),
          period('b', Day(2026, 10, 8), Day(2026, 10, 9)),
        ],
        [assign('a', 'jan'), assign('b', 'jan')],
      );
      expect(h?.text, 'Služba: po–út Jan Novák · čt–pá Jan Novák');
    });

    test('a merge of the same names hides no other part between them', () {
      final h = label(
        [
          period('a', Day(2026, 10, 5), Day(2026, 10, 6)),
          period('b', Day(2026, 10, 7), Day(2026, 10, 8)),
          period('c', Day(2026, 10, 9), Day(2026, 10, 11)),
        ],
        [assign('a', 'jan'), assign('b', 'petr'), assign('c', 'jan')],
      );
      expect(h?.text,
          'Služba: po–út Jan Novák · st–čt Petr Svoboda · pá–ne Jan Novák');
    });

    test('a one-day part names its day once', () {
      final h = label(
        [
          period('a', Day(2026, 9, 29), monday),
          period('b', Day(2026, 10, 6), Day(2026, 10, 12)),
        ],
        [assign('a', 'jan'), assign('b', 'petr')],
      );
      expect(h?.text, 'Služba: po Jan Novák · út–ne Petr Svoboda');
    });

    test('a period covering part of the week alone keeps its days', () {
      final h = label(
        [period('a', Day(2026, 10, 8), Day(2026, 10, 14))],
        [assign('a', 'petr')],
      );
      expect(h?.text, 'Služba: čt–ne Petr Svoboda');
    });

    test('an unassigned period says nothing; no period, no line', () {
      expect(label(const [], const []), isNull);
      expect(label([period('a', monday, monday.addDays(6))], const []), isNull);
      final h = label(
        [
          period('a', Day(2026, 10, 1), Day(2026, 10, 7)),
          period('b', Day(2026, 10, 8), Day(2026, 10, 14)),
        ],
        [assign('a', 'jan')],
      );
      expect(h?.text, 'Služba: po–st Jan Novák');
    });

    test('periods outside the week are ignored', () {
      expect(
        label(
          [period('a', Day(2026, 9, 28), Day(2026, 10, 4))],
          [assign('a', 'jan')],
        ),
        isNull,
      );
    });

    test('a user the roster does not know is left out', () {
      final h = label(
        [period('a', monday, monday.addDays(6))],
        [assign('a', 'jan'), assign('a', 'unknown')],
      );
      expect(h?.text, 'Služba: Jan Novák');
    });

    test('me on duty in the week with today: „Sloužíš ty · do st 7. 10.“', () {
      final h = label(
        [
          period('a', Day(2026, 10, 1), Day(2026, 10, 7)),
          period('b', Day(2026, 10, 8), Day(2026, 10, 14)),
        ],
        [assign('a', 'jan'), assign('b', 'petr')],
        me: 'jan',
        today: Day(2026, 10, 6),
      );
      expect(h?.text, 'Sloužíš ty · do st 7. 10.');
      expect(h?.mine, isTrue);
    });

    test('a co-assignee is named too: „Sloužíš ty · do st 7. 10. · spolu s: '
        'Petr Svoboda“', () {
      final h = label(
        [period('a', Day(2026, 10, 1), Day(2026, 10, 7))],
        [assign('a', 'jan'), assign('a', 'petr')],
        me: 'jan',
        today: Day(2026, 10, 6),
      );
      expect(h?.text, 'Sloužíš ty · do st 7. 10. · spolu s: Petr Svoboda');
      expect(h?.mine, isTrue);
    });

    test('several co-assignees are Czech-sorted; one unknown to the roster '
        'is left out', () {
      final h = label(
        [period('a', Day(2026, 10, 1), Day(2026, 10, 7))],
        [
          assign('a', 'jan'),
          assign('a', 'petr'),
          assign('a', 'cyril'),
          assign('a', 'unknown'),
        ],
        me: 'jan',
        today: Day(2026, 10, 6),
      );
      expect(
        h?.text,
        'Sloužíš ty · do st 7. 10. · spolu s: Čestmír Cimrman a Petr Svoboda',
      );
    });

    test('my duty in another week says „ty“, not my name', () {
      final periods = [period('a', monday, monday.addDays(6))];
      final assignments = [assign('a', 'jan')];
      // Next week's duty, seen today (not in the week).
      final ahead = label(periods, assignments, me: 'jan', today: Day(2026, 9, 30));
      expect(ahead?.text, 'Služba: ty');
      // Not tinted: „Sloužíš ty“ is the running duty's line.
      expect(ahead?.mine, isFalse);
      // On duty today, looking at the week after.
      final h = label(
        periods,
        assignments,
        me: 'jan',
        today: Day(2026, 10, 6),
        week: Day(2026, 10, 12),
      );
      expect(h, isNull);
    });

    test('in the week of today but not on duty today: the plain line', () {
      final h = label(
        [
          period('a', Day(2026, 10, 1), Day(2026, 10, 7)),
          period('b', Day(2026, 10, 8), Day(2026, 10, 14)),
        ],
        [assign('a', 'petr'), assign('b', 'jan')],
        me: 'jan',
        today: Day(2026, 10, 6),
      );
      expect(h?.text, 'Služba: po–st Petr Svoboda · čt–ne ty');
      expect(h?.mine, isFalse);
    });

    test('me in a change inside the week: „ty“ in my days, names in the '
        'others\'', () {
      final periods = [
        period('a', Day(2026, 10, 1), Day(2026, 10, 7)),
        period('b', Day(2026, 10, 8), Day(2026, 10, 14)),
      ];
      final assignments = [assign('a', 'jan'), assign('b', 'petr')];
      expect(
        label(periods, assignments, me: 'jan')?.text,
        'Služba: po–st ty · čt–ne Petr Svoboda',
      );
      expect(
        label(periods, assignments, me: 'petr')?.text,
        'Služba: po–st Jan Novák · čt–ne ty',
      );
    });

    test('with others on the period „ty“ closes the list, whatever the '
        'alphabet says', () {
      final periods = [period('a', monday, monday.addDays(6))];
      // Jan sorts after Adam and before Petr; „ty“ is still last.
      expect(
        label(periods, [assign('a', 'jan'), assign('a', 'petr')], me: 'jan')?.text,
        'Služba: Petr Svoboda a ty',
      );
      expect(
        label(
          periods,
          [assign('a', 'jan'), assign('a', 'petr'), assign('a', 'adam')],
          me: 'jan',
        )?.text,
        'Služba: Adam Beneš, Petr Svoboda a ty',
      );
    });

    test('I am „ty“ even when the roster does not know me (yet)', () {
      final h = dutyHeaderLabel(
        monday,
        [period('a', monday, monday.addDays(6))],
        [assign('a', 'me'), assign('a', 'jan')],
        const {'jan': 'Jan Novák'},
        'me',
        today: farToday,
      );
      expect(h?.text, 'Služba: Jan Novák a ty');
    });

    test('someone else\'s view names me as anyone', () {
      final h = label(
        [period('a', monday, monday.addDays(6))],
        [assign('a', 'jan'), assign('a', 'petr')],
        me: 'adam',
      );
      expect(h?.text, 'Služba: Jan Novák a Petr Svoboda');
    });
  });

  group('myDuty', () {
    final current = period('now', Day(2026, 10, 5), Day(2026, 10, 11));
    final next = period('next', Day(2026, 10, 19), Day(2026, 10, 25));
    final later = period('later', Day(2026, 11, 2), Day(2026, 11, 8));
    final past = period('past', Day(2026, 9, 21), Day(2026, 9, 27));
    final periods = [later, past, next, current];
    final assignments = [
      assign('now', 'me'),
      assign('now', 'jana'),
      assign('now', 'petr'),
      assign('next', 'me'),
      assign('next', 'adam'),
      assign('later', 'me'),
      assign('past', 'me'),
    ];

    test('on duty: the running period, the next one and who is with me', () {
      final d = myDuty(periods, assignments, 'me', Day(2026, 10, 6));
      expect(d.onDuty, isTrue);
      expect(d.current?.id, 'now');
      expect(d.next?.id, 'next');
      expect(d.coAssignees.toSet(), {'jana', 'petr'});
    });

    test('a period starting today is current, one ending today still is', () {
      expect(
        myDuty(periods, assignments, 'me', Day(2026, 10, 5)).current?.id,
        'now',
      );
      expect(
        myDuty(periods, assignments, 'me', Day(2026, 10, 11)).current?.id,
        'now',
      );
      final after = myDuty(periods, assignments, 'me', Day(2026, 10, 12));
      expect(after.onDuty, isFalse);
      expect(after.current, isNull);
    });

    test('off duty: only the earliest upcoming period, no co-assignees', () {
      final d = myDuty(periods, assignments, 'me', Day(2026, 10, 12));
      expect(d.next?.id, 'next');
      expect(d.coAssignees, isEmpty);
    });

    test('someone else\'s periods are not mine', () {
      final d = myDuty(periods, assignments, 'jana', Day(2026, 10, 12));
      expect(d, MyDuty.none);
      final adam = myDuty(periods, assignments, 'adam', Day(2026, 10, 6));
      expect(adam.onDuty, isFalse);
      expect(adam.next?.id, 'next');
    });

    test('nothing ahead, or nobody signed in: none', () {
      expect(myDuty(periods, assignments, 'me', Day(2026, 11, 9)), MyDuty.none);
      expect(myDuty(periods, assignments, null, Day(2026, 10, 6)), MyDuty.none);
    });

    test('equal inputs give equal values (no rebuild on a re-emit)', () {
      expect(
        myDuty(periods, assignments, 'me', Day(2026, 10, 6)),
        myDuty([...periods], [...assignments], 'me', Day(2026, 10, 7)),
      );
      expect(
        myDuty(periods, assignments, 'me', Day(2026, 10, 6)),
        isNot(myDuty(periods, assignments, 'me', Day(2026, 10, 12))),
      );
    });

    List<String> ids(MyDuty d) => [for (final p in d.mine) p.id];

    test('mine: every period of mine that has not ended, in date order', () {
      // Running, ahead and later; the one already over is left out.
      expect(
        ids(myDuty(periods, assignments, 'me', Day(2026, 10, 6))),
        ['now', 'next', 'later'],
      );
      // A period ending today has not ended; the day after, it has.
      expect(
        ids(myDuty(periods, assignments, 'me', Day(2026, 10, 11))),
        ['now', 'next', 'later'],
      );
      expect(
        ids(myDuty(periods, assignments, 'me', Day(2026, 10, 12))),
        ['next', 'later'],
      );
      // Not on duty today, still all of mine ahead — more than `next`.
      final off = myDuty(periods, assignments, 'me', Day(2026, 10, 12));
      expect(off.onDuty, isFalse);
      expect(off.next?.id, 'next');
      expect(ids(off), ['next', 'later']);
      expect(ids(myDuty(periods, assignments, 'me', Day(2026, 11, 9))), isEmpty);
    });

    test('coversDay: the days of my own periods, on duty today or not', () {
      final onDuty = myDuty(periods, assignments, 'me', Day(2026, 10, 6));
      // Inside the running period, both edges included.
      expect(onDuty.coversDay(Day(2026, 10, 5)), isTrue);
      expect(onDuty.coversDay(Day(2026, 10, 11)), isTrue);
      // The gap after it, then my next period, edges included.
      expect(onDuty.coversDay(Day(2026, 10, 12)), isFalse);
      expect(onDuty.coversDay(Day(2026, 10, 18)), isFalse);
      expect(onDuty.coversDay(Day(2026, 10, 19)), isTrue);
      expect(onDuty.coversDay(Day(2026, 10, 25)), isTrue);
      expect(onDuty.coversDay(Day(2026, 10, 26)), isFalse);
      // Off duty today: the days of my periods ahead are mine all the same.
      final off = myDuty(periods, assignments, 'me', Day(2026, 10, 12));
      expect(off.onDuty, isFalse);
      expect(off.coversDay(Day(2026, 10, 20)), isTrue);
      expect(off.coversDay(Day(2026, 11, 3)), isTrue);
      expect(off.coversDay(Day(2026, 10, 18)), isFalse);
    });

    test('a duty next week Monday to Wednesday: those three days only', () {
      final week = period('week', Day(2026, 10, 12), Day(2026, 10, 14));
      final d = myDuty([week], [assign('week', 'me')], 'me', Day(2026, 10, 6));
      expect(d.onDuty, isFalse);
      expect(d.current, isNull);
      expect(d.coversDay(Day(2026, 10, 11)), isFalse);
      expect(d.coversDay(Day(2026, 10, 12)), isTrue);
      expect(d.coversDay(Day(2026, 10, 13)), isTrue);
      expect(d.coversDay(Day(2026, 10, 14)), isTrue);
      expect(d.coversDay(Day(2026, 10, 15)), isFalse);
      expect(d.coversDay(Day(2026, 10, 6)), isFalse);
    });

    test('two consecutive periods of mine are both covered, no gap between', () {
      final first = period('a', Day(2026, 10, 5), Day(2026, 10, 11));
      final second = period('b', Day(2026, 10, 12), Day(2026, 10, 18));
      final d = myDuty(
        [second, first],
        [assign('a', 'me'), assign('b', 'me')],
        'me',
        Day(2026, 10, 6),
      );
      expect(ids(d), ['a', 'b']);
      for (var day = 5; day <= 18; day++) {
        expect(d.coversDay(Day(2026, 10, day)), isTrue, reason: '$day. 10.');
      }
      expect(d.coversDay(Day(2026, 10, 19)), isFalse);
    });

    test('someone else\'s periods and no one signed in cover nothing', () {
      final adam = myDuty(periods, assignments, 'adam', Day(2026, 10, 6));
      expect(adam.coversDay(Day(2026, 10, 6)), isFalse);
      expect(adam.coversDay(Day(2026, 10, 20)), isTrue);
      expect(MyDuty.none.coversDay(Day(2026, 10, 6)), isFalse);
      expect(
        myDuty(periods, assignments, null, Day(2026, 10, 6)).coversDay(
          Day(2026, 10, 6),
        ),
        isFalse,
      );
    });

    test('a further period of mine makes a different value', () {
      // Same running and next period, one more ahead: the calendar's rights
      // differ, so the provider must notify.
      final a = myDuty(periods, assignments, 'me', Day(2026, 10, 6));
      final b = myDuty(
        [...periods, period('far', Day(2026, 12, 1), Day(2026, 12, 7))],
        [...assignments, assign('far', 'me')],
        'me',
        Day(2026, 10, 6),
      );
      expect(b.current, a.current);
      expect(b.next, a.next);
      expect(b, isNot(a));
    });

    test('firstDayFrom: today while a period of mine covers it, else the '
        'start of the next one', () {
      final onDuty = myDuty(periods, assignments, 'me', Day(2026, 10, 6));
      expect(onDuty.firstDayFrom(Day(2026, 10, 6)), Day(2026, 10, 6));
      // The last day of a period is still today's.
      final lastDay = myDuty(periods, assignments, 'me', Day(2026, 10, 11));
      expect(lastDay.firstDayFrom(Day(2026, 10, 11)), Day(2026, 10, 11));
      // In the gap between two: the next period's first day.
      final gap = myDuty(periods, assignments, 'me', Day(2026, 10, 12));
      expect(gap.firstDayFrom(Day(2026, 10, 12)), Day(2026, 10, 19));
      // Off duty with nothing before the far one: that one's first day.
      final far = myDuty(periods, assignments, 'me', Day(2026, 10, 26));
      expect(far.firstDayFrom(Day(2026, 10, 26)), Day(2026, 11, 2));
      // Nothing left, or nobody: none.
      expect(
        myDuty(periods, assignments, 'me', Day(2026, 11, 9))
            .firstDayFrom(Day(2026, 11, 9)),
        isNull,
      );
      expect(MyDuty.none.firstDayFrom(Day(2026, 10, 6)), isNull);
    });

    test('lastDay: the end of my latest period that has not ended', () {
      expect(
        myDuty(periods, assignments, 'me', Day(2026, 10, 6)).lastDay,
        Day(2026, 11, 8),
      );
      expect(
        myDuty(periods, assignments, 'me', Day(2026, 11, 8)).lastDay,
        Day(2026, 11, 8),
      );
      expect(myDuty(periods, assignments, 'me', Day(2026, 11, 9)).lastDay, isNull);
      expect(MyDuty.none.lastDay, isNull);
    });
  });

  group('dutyLeadLabel', () {
    test('days in Czech, seven as a week', () {
      expect(dutyLeadLabel(1), '1 den');
      expect(dutyLeadLabel(2), '2 dny');
      expect(dutyLeadLabel(3), '3 dny');
      expect(dutyLeadLabel(5), '5 dní');
      expect(dutyLeadLabel(7), 'týden');
    });
  });

  group('splitDuties', () {
    DutyPeriod period(String id, Day from, Day to) =>
        DutyPeriod(id: id, startsOn: from, endsOn: to);
    final past2 = period('past2', Day(2026, 9, 28), Day(2026, 10, 4));
    final past1 = period('past1', Day(2026, 9, 21), Day(2026, 9, 27));
    final now = period('now', Day(2026, 10, 5), Day(2026, 10, 11));
    final next2 = period('next2', Day(2026, 10, 19), Day(2026, 10, 25));
    final next1 = period('next1', Day(2026, 10, 12), Day(2026, 10, 18));

    test('the running one, the ones ahead and the ones over, each in date '
        'order', () {
      final split = splitDuties(
        [next2, past2, now, next1, past1],
        Day(2026, 10, 7),
      );
      expect(split.current, now);
      expect(split.upcoming, [next1, next2]);
      expect(split.past, [past1, past2]);
    });

    test('a period ending today is still running, one starting tomorrow is '
        'ahead', () {
      final split = splitDuties([now, next1], Day(2026, 10, 11));
      expect(split.current, now);
      expect(split.upcoming, [next1]);
      expect(split.past, isEmpty);
    });

    test('no period running between two duties', () {
      final gap = splitDuties([past1, next1], Day(2026, 10, 7));
      expect(gap.current, isNull);
      expect(gap.upcoming, [next1]);
      expect(gap.past, [past1]);
    });
  });
}

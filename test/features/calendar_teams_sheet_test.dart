import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/profile/widgets/calendar_teams_sheet.dart';
import 'package:rezervator/features/profile/widgets/event_color_picker.dart';

/// showCalendarTeamsSheet is the richer sibling of showTeamPickerSheet:
/// every ticked team carries its own colour and, once the second calendar
/// is on, which of the two calendars it goes to. Task 4 left a shim
/// (_setTeamsPrimaryNoColor in calendar_link_card.dart) that saved every
/// ticked team back to primary with no colour, resetting anything already
/// chosen — these tests exist to prove the real sheet never does that: an
/// unrelated tick must leave every OTHER team's calendar/colour untouched.
PrioritySlot match(String id, String home, String away, {bool away_ = false}) =>
    PrioritySlot(
      id: id,
      date: Day(2026, 10, 1),
      startsAt: const HourMinute(18, 0),
      endsAt: const HourMinute(21, 0),
      type: PrioritySlot.fallbackMatchType,
      homeTeam: home,
      awayTeam: away,
      isAway: away_,
    );

final schedule = [
  match('m1', 'SKK Veverky Brno A', 'KK MS Brno D'),
  match('m2', 'KK Slovan Rosice D', 'KS Devítka Brno B', away_: true),
];

/// CalendarTeam has no == override (lib/domain/models.dart) — two separate
/// instances with the same fields are NOT equal, only identical ones are
/// (and const-canonicalization can make an untouched row's original
/// instance identical to a fresh const literal by accident). Tests compare
/// its fields structurally instead of relying on ==.
(String, CalendarSlot, int?) teamTuple(CalendarTeam t) =>
    (t.team, t.calendar, t.colorId);
List<(String, CalendarSlot, int?)> teamTuples(List<CalendarTeam> teams) =>
    teams.map(teamTuple).toList();

void main() {
  Widget harness({
    required Future<void> Function(List<CalendarTeam> teams) onChanged,
    List<PrioritySlot> matches = const [],
    List<CalendarTeam> teams = const [],
    CalendarLink link = CalendarLink.none,
  }) {
    return ProviderScope(
      overrides: [
        prioritySlotsProvider.overrideWithValue(matches),
        myCalendarTeamsProvider.overrideWith((ref) => Stream.value(teams)),
        myCalendarLinkProvider.overrideWith((ref) => Stream.value(link)),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () =>
                    showCalendarTeamsSheet(context, onChanged: onChanged),
                child: const Text('otevřít'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('otevřít'));
    await tester.pumpAndSettle();
  }

  Finder rowOf(String team) => find.byKey(ValueKey(team));
  Finder checkboxOf(String team) =>
      find.descendant(of: rowOf(team), matching: find.byType(Checkbox));
  Finder dotOf(String team) =>
      find.descendant(of: rowOf(team), matching: find.byType(EventColorDot));

  testWidgets('offers only the alley\'s own teams, Czech-sorted, unticked '
      'with an empty checkbox and no extra controls', (tester) async {
    await tester.pumpWidget(
      harness(
        matches: schedule,
        onChanged: (_) async => fail('unexpected save'),
      ),
    );
    await open(tester);

    expect(find.text('Zápasy v kalendáři'), findsOneWidget);
    expect(find.text('SKK Veverky Brno A'), findsOneWidget);
    expect(find.text('KS Devítka Brno B'), findsOneWidget);
    expect(find.text('KK MS Brno D'), findsNothing); // opponent, not ours
    expect(find.text('KK Slovan Rosice D'), findsNothing);
    // Devítka sorts before Veverky (Czech order).
    expect(
      tester.getTopLeft(find.text('KS Devítka Brno B')).dy,
      lessThan(tester.getTopLeft(find.text('SKK Veverky Brno A')).dy),
    );

    expect(
      tester.widget<Checkbox>(checkboxOf('SKK Veverky Brno A')).value,
      isFalse,
    );
    expect(dotOf('SKK Veverky Brno A'), findsNothing);
    expect(
      find.descendant(
        of: rowOf('SKK Veverky Brno A'),
        matching: find.byType(SegmentedButton<CalendarSlot>),
      ),
      findsNothing,
    );
  });

  testWidgets('a chosen team that left the schedule stays listed so it can '
      'be unticked', (tester) async {
    await tester.pumpWidget(
      harness(
        matches: schedule,
        teams: const [CalendarTeam(team: 'TJ Sokol Husovice E')],
        onChanged: (_) async {},
      ),
    );
    await open(tester);

    expect(find.text('TJ Sokol Husovice E'), findsOneWidget);
    expect(
      tester.widget<Checkbox>(checkboxOf('TJ Sokol Husovice E')).value,
      isTrue,
    );
  });

  testWidgets('an empty schedule says so, with no rows', (tester) async {
    await tester.pumpWidget(harness(onChanged: (_) async {}));
    await open(tester);

    expect(find.text('Zatím žádné zápasy v rozvrhu'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets('ticking a team saves it to primary with no colour', (
    tester,
  ) async {
    final saved = <List<CalendarTeam>>[];
    await tester.pumpWidget(
      harness(matches: schedule, onChanged: (t) async => saved.add(t)),
    );
    await open(tester);

    await tester.tap(checkboxOf('SKK Veverky Brno A'));
    await tester.pumpAndSettle();

    expect(saved.map(teamTuples).toList(), [
      [('SKK Veverky Brno A', CalendarSlot.primary, null)],
    ]);
    // The row redraws ticked right away (optimistic), with its colour dot.
    expect(
      tester.widget<Checkbox>(checkboxOf('SKK Veverky Brno A')).value,
      isTrue,
    );
    expect(dotOf('SKK Veverky Brno A'), findsOneWidget);
  });

  testWidgets('unticking one team saves the rest UNCHANGED — colour and '
      'calendar of every other ticked team survive the save (this is the '
      'whole point of the richer sheet: Task 4\'s shim would have reset '
      'them)', (tester) async {
    final saved = <List<CalendarTeam>>[];
    await tester.pumpWidget(
      harness(
        matches: schedule,
        teams: const [
          CalendarTeam(team: 'SKK Veverky Brno A'),
          CalendarTeam(
            team: 'KS Devítka Brno B',
            calendar: CalendarSlot.secondary,
            colorId: 7,
          ),
        ],
        link: const CalendarLink(
          status: CalendarLinkStatus.linked,
          secondaryEnabled: true,
        ),
        onChanged: (t) async => saved.add(t),
      ),
    );
    await open(tester);

    await tester.tap(checkboxOf('SKK Veverky Brno A'));
    await tester.pumpAndSettle();

    expect(saved.map(teamTuples).toList(), [
      [('KS Devítka Brno B', CalendarSlot.secondary, 7)],
    ]);
  });

  testWidgets('the colour dot opens the eleven Google colours plus bez '
      'barvy, and picking one saves it with the calendar preserved', (
    tester,
  ) async {
    final saved = <List<CalendarTeam>>[];
    await tester.pumpWidget(
      harness(
        matches: schedule,
        teams: const [
          CalendarTeam(
            team: 'SKK Veverky Brno A',
            calendar: CalendarSlot.secondary,
          ),
        ],
        link: const CalendarLink(
          status: CalendarLinkStatus.linked,
          secondaryEnabled: true,
        ),
        onChanged: (t) async => saved.add(t),
      ),
    );
    await open(tester);

    await tester.tap(dotOf('SKK Veverky Brno A'));
    await tester.pumpAndSettle();

    final picker = find.byType(EventColorPicker);
    expect(picker, findsOneWidget);
    for (final name in const [
      'Levandulová',
      'Šalvějová',
      'Švestková',
      'Lososová',
      'Banánová',
      'Mandarinková',
      'Paví',
      'Grafitová',
      'Borůvková',
      'Bazalková',
      'Rajčatová',
    ]) {
      expect(
        find.descendant(of: picker, matching: find.byTooltip(name)),
        findsOneWidget,
      );
    }
    expect(
      find.descendant(of: picker, matching: find.byTooltip('Bez barvy')),
      findsOneWidget,
    );

    await tester.tap(
      find.descendant(of: picker, matching: find.byTooltip('Šalvějová')),
    );
    await tester.pumpAndSettle();

    expect(saved.map(teamTuples).toList(), [
      [('SKK Veverky Brno A', CalendarSlot.secondary, 2)],
    ]);
  });

  testWidgets('dismissing the colour picker without a tap changes nothing', (
    tester,
  ) async {
    var saves = 0;
    await tester.pumpWidget(
      harness(
        matches: schedule,
        teams: const [CalendarTeam(team: 'SKK Veverky Brno A', colorId: 3)],
        onChanged: (_) async => saves++,
      ),
    );
    await open(tester);

    await tester.tap(dotOf('SKK Veverky Brno A'));
    await tester.pumpAndSettle();
    // Tap the barrier above the sheet to dismiss it without picking.
    await tester.tapAt(const Offset(400, 20));
    await tester.pumpAndSettle();

    expect(saves, 0);
  });

  testWidgets('the Hlavní/Druhý picker is hidden unless the second calendar '
      'is on, even for a ticked team', (tester) async {
    await tester.pumpWidget(
      harness(
        matches: schedule,
        teams: const [CalendarTeam(team: 'SKK Veverky Brno A')],
        link: const CalendarLink(status: CalendarLinkStatus.linked),
        onChanged: (_) async {},
      ),
    );
    await open(tester);

    expect(find.byType(SegmentedButton<CalendarSlot>), findsNothing);
    expect(find.text('Hlavní'), findsNothing);
    expect(find.text('Druhý'), findsNothing);
  });

  testWidgets('once the second calendar is on, a ticked team offers Hlavní '
      '| Druhý, defaulting to Hlavní, and picking Druhý saves it with the '
      'colour preserved', (tester) async {
    final saved = <List<CalendarTeam>>[];
    await tester.pumpWidget(
      harness(
        matches: schedule,
        teams: const [CalendarTeam(team: 'SKK Veverky Brno A', colorId: 9)],
        link: const CalendarLink(
          status: CalendarLinkStatus.linked,
          secondaryEnabled: true,
        ),
        onChanged: (t) async => saved.add(t),
      ),
    );
    await open(tester);

    final segmented = find.descendant(
      of: rowOf('SKK Veverky Brno A'),
      matching: find.byType(SegmentedButton<CalendarSlot>),
    );
    expect(segmented, findsOneWidget);
    expect(tester.widget<SegmentedButton<CalendarSlot>>(segmented).selected, {
      CalendarSlot.primary,
    });

    await tester.tap(
      find.descendant(
        of: rowOf('SKK Veverky Brno A'),
        matching: find.text('Druhý'),
      ),
    );
    await tester.pumpAndSettle();

    expect(saved.map(teamTuples).toList(), [
      [('SKK Veverky Brno A', CalendarSlot.secondary, 9)],
    ]);
  });

  testWidgets('two quick ticks both land — the second save carries both, '
      'Czech-sorted', (tester) async {
    final saved = <List<CalendarTeam>>[];
    await tester.pumpWidget(
      harness(matches: schedule, onChanged: (t) async => saved.add(t)),
    );
    await open(tester);

    await tester.tap(checkboxOf('SKK Veverky Brno A'));
    await tester.pump();
    await tester.tap(checkboxOf('KS Devítka Brno B'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(saved.length, 2);
    expect(teamTuples(saved.last), [
      ('KS Devítka Brno B', CalendarSlot.primary, null),
      ('SKK Veverky Brno A', CalendarSlot.primary, null),
    ]);
  });

  testWidgets('a failed colour change rolls back to the EXACT previous row '
      '(calendar and colour), not a fresh default', (tester) async {
    await tester.pumpWidget(
      harness(
        matches: schedule,
        teams: const [
          CalendarTeam(
            team: 'SKK Veverky Brno A',
            calendar: CalendarSlot.secondary,
            colorId: 4,
          ),
        ],
        link: const CalendarLink(
          status: CalendarLinkStatus.linked,
          secondaryEnabled: true,
        ),
        onChanged: (_) async => throw Exception('not_allowed'),
      ),
    );
    await open(tester);

    await tester.tap(dotOf('SKK Veverky Brno A'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(EventColorPicker),
        matching: find.byTooltip('Rajčatová'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Na tohle nemáš oprávnění.'), findsOneWidget);
    // Rolled back to secondary/colorId 4, NOT unticked and NOT primary/none.
    expect(
      tester.widget<Checkbox>(checkboxOf('SKK Veverky Brno A')).value,
      isTrue,
    );
    final segmented = find.descendant(
      of: rowOf('SKK Veverky Brno A'),
      matching: find.byType(SegmentedButton<CalendarSlot>),
    );
    expect(tester.widget<SegmentedButton<CalendarSlot>>(segmented).selected, {
      CalendarSlot.secondary,
    });
  });
}

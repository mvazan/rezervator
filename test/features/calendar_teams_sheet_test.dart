import 'dart:async';

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

  /// The sheet edits locally and saves the whole list once, on close — so a
  /// test that wants to see the save has to close it first, the way the
  /// player does.
  Future<void> close(WidgetTester tester) async {
    Navigator.of(tester.element(find.text('Zápasy v kalendáři'))).pop();
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

    // The row redraws ticked right away, with its colour dot — but nothing
    // has gone out yet; the save waits for the sheet to close.
    expect(
      tester.widget<Checkbox>(checkboxOf('SKK Veverky Brno A')).value,
      isTrue,
    );
    expect(dotOf('SKK Veverky Brno A'), findsOneWidget);
    expect(saved, isEmpty);

    await close(tester);
    expect(saved.map(teamTuples).toList(), [
      [('SKK Veverky Brno A', CalendarSlot.primary, null)],
    ]);
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
    await close(tester);

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
    await close(tester);

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
    await close(tester);

    expect(saved.map(teamTuples).toList(), [
      [('SKK Veverky Brno A', CalendarSlot.secondary, 9)],
    ]);
  });

  testWidgets('several ticks are ONE save on close, Czech-sorted — not one '
      'round trip per tap', (tester) async {
    final saved = <List<CalendarTeam>>[];
    await tester.pumpWidget(
      harness(matches: schedule, onChanged: (t) async => saved.add(t)),
    );
    await open(tester);

    await tester.tap(checkboxOf('SKK Veverky Brno A'));
    await tester.pump();
    await tester.tap(checkboxOf('KS Devítka Brno B'));
    await tester.pumpAndSettle();
    expect(saved, isEmpty, reason: 'nothing goes out while the sheet is open');

    await close(tester);
    expect(saved.length, 1, reason: 'one call carries the whole list');
    expect(teamTuples(saved.single), [
      ('KS Devítka Brno B', CalendarSlot.primary, null),
      ('SKK Veverky Brno A', CalendarSlot.primary, null),
    ]);
  });

  testWidgets('a failed save says so on the screen underneath, and the row '
      'keeps what the server still holds', (tester) async {
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
    await close(tester);

    // The sheet is gone by the time the answer comes back, so the snack
    // belongs to the screen that is still there.
    expect(find.text('Na tohle nemáš oprávnění.'), findsOneWidget);

    // Nothing was saved, so reopening shows the row exactly as the server
    // still has it: secondary, colour 4 — not a fresh default.
    await open(tester);
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

  testWidgets('several teams ticked in a row all reach the server, even when '
      'the sheet closes before the saves finish', (tester) async {
    // One save is a slow round trip: the edge function refreshes the Google
    // token and rewrites every future match. Ticking a second team while the
    // first is still in the air used to queue it behind — and closing the
    // sheet threw the queue away, so only the first tick ever landed.
    final saved = <List<CalendarTeam>>[];
    final gates = <Completer<void>>[];
    await tester.pumpWidget(harness(
      matches: schedule,
      onChanged: (teams) {
        saved.add(teams);
        final gate = Completer<void>();
        gates.add(gate);
        return gate.future;
      },
    ));
    await open(tester);

    await tester.tap(checkboxOf('KS Devítka Brno B'));
    await tester.pump();
    await tester.tap(checkboxOf('SKK Veverky Brno A'));
    await tester.pump();

    // Both are ticked on screen straight away.
    expect(
      tester.widget<Checkbox>(checkboxOf('KS Devítka Brno B')).value,
      isTrue,
    );
    expect(
      tester.widget<Checkbox>(checkboxOf('SKK Veverky Brno A')).value,
      isTrue,
    );

    // The player closes the sheet without waiting — and it is really gone,
    // disposed, before the first save even answers.
    Navigator.of(tester.element(find.byType(Checkbox).first)).pop();
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNothing, reason: 'sheet closed');

    for (var i = 0; i < 4 && gates.isNotEmpty; i++) {
      for (final gate in [...gates]) {
        if (!gate.isCompleted) gate.complete();
      }
      await tester.pumpAndSettle();
    }

    expect(saved, isNotEmpty);
    expect(
      saved.last.map((t) => t.team).toList(),
      ['KS Devítka Brno B', 'SKK Veverky Brno A'],
      reason: 'the last save must carry both ticks, not just the first',
    );
  });
}

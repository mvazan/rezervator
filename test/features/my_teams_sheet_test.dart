import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/profile/widgets/event_color_picker.dart';
import 'package:rezervator/features/profile/widgets/my_teams_sheet.dart';
import 'package:rezervator/features/profile/widgets/picker_sheet.dart';

/// Moje týmy is ONE sheet now: a row per team with three boxes — Přehled
/// (profiles.followed_teams, what Můj přehled draws), Kalendář
/// (calendar_teams, what Google gets) and the shared colour (team_colors).
/// The three still save through three separate calls, and only the ones
/// that actually changed; the sheet is the only place that knows all three.
///
/// The layout carries a promise of its own: the boxes live in fixed
/// columns, so a tick never shifts what is beside it — the colour cell is
/// as wide empty as it is full.
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

/// CalendarTeam has no == override (lib/domain/models.dart), so tests
/// compare its fields structurally.
(String, CalendarSlot) teamTuple(CalendarTeam t) => (t.team, t.calendar);
List<(String, CalendarSlot)> teamTuples(List<CalendarTeam> teams) =>
    teams.map(teamTuple).toList();

Future<void> _failColors(Map<String, int?> _) async =>
    fail('unexpected colour save');
Future<void> _failCalendar(List<CalendarTeam> _) async =>
    fail('unexpected calendar save');
Future<void> _failFollowed(List<String> _) async =>
    fail('unexpected overview save');

const _linked = CalendarLink(status: CalendarLinkStatus.linked);
const _linkedWithSecond = CalendarLink(
  status: CalendarLinkStatus.linked,
  secondaryEnabled: true,
);

void main() {
  // A phone-tall window: the sheet caps at 9/16 of the screen, and the
  // default 800×600 leaves room for barely three rows — a test asking about
  // the fourth team would be asking about a row the lazy list never built.
  setUp(() {
    final view =
        TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher.views.first;
    view.physicalSize = const Size(800, 1600);
    view.devicePixelRatio = 1.0;
  });
  tearDown(() {
    final view =
        TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher.views.first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  Widget harness({
    Future<void> Function(List<String> teams) onFollowedChanged =
        _failFollowed,
    Future<void> Function(List<CalendarTeam> teams) onCalendarChanged =
        _failCalendar,
    Future<void> Function(Map<String, int?> colors) onColorsChanged =
        _failColors,
    List<PrioritySlot> matches = const [],
    List<String> followed = const [],
    List<CalendarTeam> teams = const [],
    Map<String, int> colors = const {},
    CalendarLink link = CalendarLink.none,
    bool calendarAvailable = true,
  }) {
    final me = Profile(
      id: 'me',
      displayName: 'Já Hráč',
      email: 'me@example.com',
      role: Role.player,
      status: ProfileStatus.approved,
      followedTeams: followed,
    );
    return ProviderScope(
      overrides: [
        myProfileProvider.overrideWith((ref) => Stream.value(me)),
        prioritySlotsProvider.overrideWithValue(matches),
        myCalendarTeamsProvider.overrideWith((ref) => Stream.value(teams)),
        myTeamColorsProvider.overrideWith((ref) => Stream.value(colors)),
        myCalendarLinkProvider.overrideWith((ref) => Stream.value(link)),
        calendarAvailableProvider.overrideWithValue(calendarAvailable),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showMyTeamsSheet(
                  context,
                  onFollowedChanged: onFollowedChanged,
                  onCalendarChanged: onCalendarChanged,
                  onColorsChanged: onColorsChanged,
                ),
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

  /// Saving is the button and nothing else.
  Future<void> close(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, 'Uložit'));
    await tester.pumpAndSettle();
  }

  /// Closing WITHOUT the button — the scrim above the sheet.
  Future<void> dismiss(WidgetTester tester) async {
    await tester.tapAt(const Offset(400, 20));
    await tester.pumpAndSettle();
  }

  Finder cellOf(String team, String column) =>
      find.byKey(ValueKey('$team:$column'));
  Finder overviewBox(String team) => find.descendant(
      of: cellOf(team, 'overview'), matching: find.byType(Checkbox));
  Finder calendarBox(String team) => find.descendant(
      of: cellOf(team, 'calendar'), matching: find.byType(Checkbox));
  Finder dotOf(String team) => find.descendant(
      of: cellOf(team, 'color'), matching: find.byType(EventColorDot));
  bool ticked(WidgetTester tester, Finder box) =>
      tester.widget<Checkbox>(box).value == true;

  group('Uložit is the only way to save', () {
    testWidgets('the scrim asks before it throws the ticks away',
        (tester) async {
      final saved = <List<String>>[];
      await tester.pumpWidget(harness(
        matches: schedule,
        onFollowedChanged: (t) async => saved.add(t),
      ));
      await open(tester);
      await tester.tap(overviewBox('SKK Veverky Brno A'));
      await tester.pumpAndSettle();

      await dismiss(tester);
      expect(find.text('Zahodit změny?'), findsOneWidget,
          reason: 'a tick already made is worth a question');
      expect(find.byType(Checkbox), findsWidgets, reason: 'still open');

      // Staying keeps the tick.
      await tester.tap(find.text('Zpět'));
      await tester.pumpAndSettle();
      expect(ticked(tester, overviewBox('SKK Veverky Brno A')), isTrue);

      await dismiss(tester);
      await tester.tap(find.text('Zahodit'));
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsNothing, reason: 'sheet closed');
      expect(saved, isEmpty, reason: 'leaving is not saving');
    });

    testWidgets('Zrušit takes the word for it, and saves nothing',
        (tester) async {
      final saved = <List<String>>[];
      await tester.pumpWidget(harness(
        matches: schedule,
        onFollowedChanged: (t) async => saved.add(t),
      ));
      await open(tester);
      await tester.tap(overviewBox('SKK Veverky Brno A'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, 'Zrušit'));
      await tester.pumpAndSettle();
      expect(find.text('Zahodit změny?'), findsNothing,
          reason: 'an explicit cancel is not second-guessed');
      expect(find.byType(Checkbox), findsNothing);
      expect(saved, isEmpty);
    });

    testWidgets('nothing touched, nothing asked', (tester) async {
      await tester.pumpWidget(harness(matches: schedule));
      await open(tester);

      await dismiss(tester);
      expect(find.text('Zahodit změny?'), findsNothing);
      expect(find.byType(Checkbox), findsNothing);
    });

    testWidgets('the buttons stay in sight, however long the list',
        (tester) async {
      tester.view.physicalSize = const Size(400, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final saved = <List<String>>[];
      await tester.pumpWidget(harness(
        matches: [
          for (var i = 0; i < 20; i++) match('m$i', 'Tým ${i + 10}', 'Soupeř'),
        ],
        onFollowedChanged: (t) async => saved.add(t),
      ));
      await open(tester);

      // The last team is below the fold — the list scrolls…
      expect(find.text('Tým 29'), findsNothing);
      // …and the buttons did not scroll away with it.
      final button = find.widgetWithText(FilledButton, 'Uložit');
      expect(button, findsOneWidget);
      final sheet = tester.getRect(find.byType(PickerSheetFrame));
      expect(tester.getRect(button).bottom, lessThanOrEqualTo(sheet.bottom));

      // And they are not neighbours: the slip that costs something is
      // hitting Zrušit while aiming at Uložit, so they sit at opposite
      // ends with a thumb's width of nothing between them.
      final gap = tester.getRect(button).left -
          tester.getRect(find.widgetWithText(TextButton, 'Zrušit')).right;
      expect(gap, greaterThan(100), reason: 'mis-tap distance');

      await tester.tap(overviewBox('Tým 10'));
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(saved.single, ['Tým 10']);
    });
  });

  group('the columns', () {
    testWidgets('without a linked calendar there is Přehled and Barva, and '
        'no Kalendář at all', (tester) async {
      await tester.pumpWidget(harness(matches: schedule));
      await open(tester);

      expect(find.text('Moje týmy'), findsOneWidget);
      expect(find.text('Přehled'), findsOneWidget);
      expect(find.text('Barva'), findsOneWidget);
      expect(find.text('Kalendář'), findsNothing);
      expect(calendarBox('SKK Veverky Brno A'), findsNothing);
      expect(overviewBox('SKK Veverky Brno A'), findsOneWidget);
      expect(
        find.text('Zaškrtni týmy, jejichž zápasy chceš vidět v Můj přehled.'),
        findsOneWidget,
      );
    });

    testWidgets('a linked calendar adds the Kalendář column and says what '
        'the two mean', (tester) async {
      await tester.pumpWidget(harness(matches: schedule, link: _linked));
      await open(tester);

      expect(find.text('Kalendář'), findsOneWidget);
      expect(calendarBox('SKK Veverky Brno A'), findsOneWidget);
      expect(
        find.text('Přehled = Můj přehled v appce, Kalendář = Google kalendář.'),
        findsOneWidget,
      );
    });

    testWidgets('a calendar the app cannot offer is not offered — no client '
        'id baked in', (tester) async {
      await tester.pumpWidget(harness(
        matches: schedule,
        link: _linked,
        calendarAvailable: false,
      ));
      await open(tester);

      expect(find.text('Kalendář'), findsNothing);
      expect(calendarBox('SKK Veverky Brno A'), findsNothing);
    });

    // The colour cell is empty until the team is somewhere to be seen — and
    // an empty cell is exactly as wide as a full one, or every tick would
    // shove the row around under the finger doing the ticking.
    testWidgets('the empty colour cell holds its place', (tester) async {
      await tester.pumpWidget(harness(matches: schedule, link: _linked));
      await open(tester);

      const team = 'SKK Veverky Brno A';
      expect(dotOf(team), findsNothing, reason: 'nothing ticked yet');
      final before = (
        overview: tester.getRect(cellOf(team, 'overview')),
        calendar: tester.getRect(cellOf(team, 'calendar')),
        colour: tester.getRect(cellOf(team, 'color')),
      );

      await tester.tap(overviewBox(team));
      await tester.pumpAndSettle();

      expect(dotOf(team), findsOneWidget, reason: 'now there is a colour');
      expect(tester.getRect(cellOf(team, 'overview')), before.overview);
      expect(tester.getRect(cellOf(team, 'calendar')), before.calendar);
      expect(tester.getRect(cellOf(team, 'color')), before.colour);
    });

    testWidgets('offers only the alley\'s own teams, Czech-sorted and '
        'unticked', (tester) async {
      await tester.pumpWidget(harness(matches: schedule, link: _linked));
      await open(tester);

      expect(find.text('SKK Veverky Brno A'), findsOneWidget);
      expect(find.text('KS Devítka Brno B'), findsOneWidget);
      expect(find.text('KK MS Brno D'), findsNothing); // opponent, not ours
      expect(find.text('KK Slovan Rosice D'), findsNothing);
      // Devítka sorts before Veverky (Czech order).
      expect(
        tester.getTopLeft(find.text('KS Devítka Brno B')).dy,
        lessThan(tester.getTopLeft(find.text('SKK Veverky Brno A')).dy),
      );
      expect(ticked(tester, overviewBox('SKK Veverky Brno A')), isFalse);
      expect(ticked(tester, calendarBox('SKK Veverky Brno A')), isFalse);
    });

    testWidgets('a team that left the schedule stays listed — from either '
        'list — so it can be unticked', (tester) async {
      await tester.pumpWidget(harness(
        matches: schedule,
        followed: const ['TJ Sokol Husovice E'],
        teams: const [CalendarTeam(team: 'KK Vyškov B')],
        link: _linked,
      ));
      await open(tester);

      expect(ticked(tester, overviewBox('TJ Sokol Husovice E')), isTrue);
      expect(ticked(tester, calendarBox('TJ Sokol Husovice E')), isFalse);
      expect(ticked(tester, calendarBox('KK Vyškov B')), isTrue);
      expect(ticked(tester, overviewBox('KK Vyškov B')), isFalse);
    });

    testWidgets('an empty schedule says so, with no rows', (tester) async {
      await tester.pumpWidget(harness());
      await open(tester);

      expect(find.text('Zatím žádné zápasy v rozvrhu'), findsOneWidget);
      expect(find.byType(Checkbox), findsNothing);
    });
  });

  group('three boxes, three saves', () {
    testWidgets('a Přehled tick saves the overview list alone', (tester) async {
      final saved = <List<String>>[];
      await tester.pumpWidget(harness(
        matches: schedule,
        link: _linked,
        onFollowedChanged: (t) async => saved.add(t),
        // onCalendarChanged and onColorsChanged would fail() if called.
      ));
      await open(tester);

      await tester.tap(overviewBox('SKK Veverky Brno A'));
      await tester.pumpAndSettle();
      expect(ticked(tester, overviewBox('SKK Veverky Brno A')), isTrue);
      expect(ticked(tester, calendarBox('SKK Veverky Brno A')), isFalse,
          reason: 'the two boxes are independent');
      expect(saved, isEmpty, reason: 'nothing goes out while the sheet is up');

      await close(tester);
      expect(saved, [
        ['SKK Veverky Brno A'],
      ]);
    });

    testWidgets('a Kalendář tick saves the calendar list alone, to the main '
        'calendar', (tester) async {
      final saved = <List<CalendarTeam>>[];
      await tester.pumpWidget(harness(
        matches: schedule,
        link: _linked,
        onCalendarChanged: (t) async => saved.add(t),
      ));
      await open(tester);

      await tester.tap(calendarBox('SKK Veverky Brno A'));
      await tester.pumpAndSettle();
      expect(dotOf('SKK Veverky Brno A'), findsOneWidget,
          reason: 'in the calendar is reason enough for a colour');

      await close(tester);
      expect(saved.map(teamTuples).toList(), [
        [('SKK Veverky Brno A', CalendarSlot.primary)],
      ]);
    });

    testWidgets('all three change together: three calls, one action',
        (tester) async {
      final followed = <List<String>>[];
      final calendar = <List<CalendarTeam>>[];
      final colours = <Map<String, int?>>[];
      await tester.pumpWidget(harness(
        matches: schedule,
        link: _linked,
        onFollowedChanged: (t) async => followed.add(t),
        onCalendarChanged: (t) async => calendar.add(t),
        onColorsChanged: (c) async => colours.add(c),
      ));
      await open(tester);

      await tester.tap(overviewBox('SKK Veverky Brno A'));
      await tester.pumpAndSettle();
      await tester.tap(calendarBox('SKK Veverky Brno A'));
      await tester.pumpAndSettle();
      await tester.tap(dotOf('SKK Veverky Brno A'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
          of: find.byType(EventColorPicker),
          matching: find.byTooltip('Šalvějová')));
      await tester.pumpAndSettle();
      await close(tester);

      expect(followed, [
        ['SKK Veverky Brno A'],
      ]);
      expect(calendar.map(teamTuples).toList(), [
        [('SKK Veverky Brno A', CalendarSlot.primary)],
      ]);
      expect(colours, [
        {'SKK Veverky Brno A': 2},
      ]);
    });

    testWidgets('unticking one team leaves every other calendar row exactly '
        'as it was', (tester) async {
      final saved = <List<CalendarTeam>>[];
      await tester.pumpWidget(harness(
        matches: schedule,
        teams: const [
          CalendarTeam(team: 'SKK Veverky Brno A'),
          CalendarTeam(
              team: 'KS Devítka Brno B', calendar: CalendarSlot.secondary),
        ],
        colors: const {'KS Devítka Brno B': 7},
        link: _linkedWithSecond,
        onCalendarChanged: (t) async => saved.add(t),
      ));
      await open(tester);

      await tester.tap(calendarBox('SKK Veverky Brno A'));
      await tester.pumpAndSettle();
      await close(tester);

      expect(saved.map(teamTuples).toList(), [
        [('KS Devítka Brno B', CalendarSlot.secondary)],
      ]);
    });

    testWidgets('several ticks are ONE save, Czech-sorted — not one round '
        'trip per tap', (tester) async {
      final saved = <List<CalendarTeam>>[];
      await tester.pumpWidget(harness(
        matches: schedule,
        link: _linked,
        onCalendarChanged: (t) async => saved.add(t),
      ));
      await open(tester);

      await tester.tap(calendarBox('SKK Veverky Brno A'));
      await tester.pump();
      await tester.tap(calendarBox('KS Devítka Brno B'));
      await tester.pumpAndSettle();
      expect(saved, isEmpty);

      await close(tester);
      expect(saved.length, 1, reason: 'one call carries the whole list');
      expect(teamTuples(saved.single), [
        ('KS Devítka Brno B', CalendarSlot.primary),
        ('SKK Veverky Brno A', CalendarSlot.primary),
      ]);
    });

    testWidgets('ticking back off before saving sends nothing at all',
        (tester) async {
      await tester.pumpWidget(harness(matches: schedule, link: _linked));
      await open(tester);

      await tester.tap(overviewBox('SKK Veverky Brno A'));
      await tester.pumpAndSettle();
      await tester.tap(overviewBox('SKK Veverky Brno A'));
      await tester.pumpAndSettle();
      await close(tester);
      // All three callbacks fail() when called — reaching here is the test.
    });

    testWidgets('both ticks reach the server even when the sheet closes '
        'before the saves finish', (tester) async {
      // One calendar save is a slow round trip: the edge function refreshes
      // the Google token and rewrites every future match.
      final saved = <List<CalendarTeam>>[];
      final gates = <Completer<void>>[];
      await tester.pumpWidget(harness(
        matches: schedule,
        link: _linked,
        onCalendarChanged: (teams) {
          saved.add(teams);
          final gate = Completer<void>();
          gates.add(gate);
          return gate.future;
        },
      ));
      await open(tester);

      await tester.tap(calendarBox('KS Devítka Brno B'));
      await tester.pump();
      await tester.tap(calendarBox('SKK Veverky Brno A'));
      await tester.pump();
      expect(ticked(tester, calendarBox('KS Devítka Brno B')), isTrue);
      expect(ticked(tester, calendarBox('SKK Veverky Brno A')), isTrue);

      await tester.tap(find.widgetWithText(FilledButton, 'Uložit'));
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
  });

  group('the colour', () {
    testWidgets('opens the eleven Google colours plus bez barvy, and saves '
        'through onColorsChanged alone', (tester) async {
      final savedColors = <Map<String, int?>>[];
      await tester.pumpWidget(harness(
        matches: schedule,
        followed: const ['SKK Veverky Brno A'],
        link: _linked,
        onColorsChanged: (c) async => savedColors.add(c),
      ));
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
        expect(find.descendant(of: picker, matching: find.byTooltip(name)),
            findsOneWidget);
      }
      expect(find.descendant(of: picker, matching: find.byTooltip('Bez barvy')),
          findsOneWidget);

      await tester.tap(
          find.descendant(of: picker, matching: find.byTooltip('Šalvějová')));
      await tester.pumpAndSettle();
      await close(tester);

      expect(savedColors, [
        {'SKK Veverky Brno A': 2},
      ]);
      // The other two callbacks fail() when called — a pure colour change
      // never touches either list.
    });

    testWidgets('dismissing the picker without a tap changes nothing',
        (tester) async {
      await tester.pumpWidget(harness(
        matches: schedule,
        followed: const ['SKK Veverky Brno A'],
        colors: const {'SKK Veverky Brno A': 3},
      ));
      await open(tester);

      await tester.tap(dotOf('SKK Veverky Brno A'));
      await tester.pumpAndSettle();
      // Tap the barrier above the picker to dismiss it without picking.
      await tester.tapAt(const Offset(400, 20));
      await tester.pumpAndSettle();
      await close(tester);
      // Every callback fail()s when called.
    });

    testWidgets('picked back to what it already was sends nothing',
        (tester) async {
      await tester.pumpWidget(harness(
        matches: schedule,
        followed: const ['SKK Veverky Brno A'],
        colors: const {'SKK Veverky Brno A': 5},
      ));
      await open(tester);

      await tester.tap(dotOf('SKK Veverky Brno A'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
          of: find.byType(EventColorPicker),
          matching: find.byTooltip('Mandarinková'))); // id 6
      await tester.pumpAndSettle();
      await tester.tap(dotOf('SKK Veverky Brno A'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
          of: find.byType(EventColorPicker),
          matching: find.byTooltip('Banánová'))); // id 5, the original
      await tester.pumpAndSettle();

      expect(tester.widget<EventColorDot>(dotOf('SKK Veverky Brno A')).colorId,
          5);
      await close(tester);
      // onColorsChanged would have fail()ed had it been called.
    });

    testWidgets('a failed save says so on the screen underneath, and the row '
        'keeps what the server still holds', (tester) async {
      await tester.pumpWidget(harness(
        matches: schedule,
        teams: const [
          CalendarTeam(
              team: 'SKK Veverky Brno A', calendar: CalendarSlot.secondary),
        ],
        colors: const {'SKK Veverky Brno A': 4},
        link: _linkedWithSecond,
        onColorsChanged: (_) async => throw Exception('not_allowed'),
      ));
      await open(tester);

      await tester.tap(dotOf('SKK Veverky Brno A'));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(
          of: find.byType(EventColorPicker),
          matching: find.byTooltip('Rajčatová')));
      await tester.pumpAndSettle();
      await close(tester);

      // The sheet is gone by the time the answer comes back, so the snack
      // belongs to the screen that is still there.
      expect(find.text('Na tohle nemáš oprávnění.'), findsOneWidget);

      // Nothing was saved, so reopening shows the row as the server still
      // has it: in the calendar, second one, colour 4.
      await open(tester);
      expect(ticked(tester, calendarBox('SKK Veverky Brno A')), isTrue);
      expect(tester.widget<EventColorDot>(dotOf('SKK Veverky Brno A')).colorId,
          4);
      expect(
        find.descendant(
            of: cellOf('SKK Veverky Brno A', 'calendar'), matching: find.text('2')),
        findsOneWidget,
      );
    });
  });

  group('which of the two calendars', () {
    testWidgets('a long press does nothing while there is only one calendar',
        (tester) async {
      await tester.pumpWidget(harness(
        matches: schedule,
        teams: const [CalendarTeam(team: 'SKK Veverky Brno A')],
        link: _linked,
      ));
      await open(tester);

      await tester.longPress(find.text('SKK Veverky Brno A'));
      await tester.pumpAndSettle();
      expect(find.text('Hlavní kalendář'), findsNothing);
      expect(find.text('Druhý kalendář'), findsNothing);
      expect(
        find.descendant(
            of: cellOf('SKK Veverky Brno A', 'calendar'),
            matching: find.text('2')),
        findsNothing,
      );
    });

    testWidgets('with the second calendar on, a long press offers both and '
        'the choice shows on the row', (tester) async {
      final saved = <List<CalendarTeam>>[];
      await tester.pumpWidget(harness(
        matches: schedule,
        teams: const [CalendarTeam(team: 'SKK Veverky Brno A')],
        colors: const {'SKK Veverky Brno A': 9},
        link: _linkedWithSecond,
        onCalendarChanged: (t) async => saved.add(t),
      ));
      await open(tester);
      expect(
        find.text('Podržením týmu vybereš, do kterého kalendáře jeho zápasy '
            'patří.'),
        findsOneWidget,
      );

      await tester.longPress(find.text('SKK Veverky Brno A'));
      await tester.pumpAndSettle();
      expect(find.text('Zápasy — SKK Veverky Brno A'), findsOneWidget);
      expect(find.text('Hlavní kalendář'), findsOneWidget);

      await tester.tap(find.text('Druhý kalendář'));
      await tester.pumpAndSettle();
      // The row says where it goes, without growing a line for it.
      expect(
        find.descendant(
            of: cellOf('SKK Veverky Brno A', 'calendar'),
            matching: find.text('2')),
        findsOneWidget,
      );
      expect(saved, isEmpty, reason: 'still local until Uložit');

      await close(tester);
      expect(saved.map(teamTuples).toList(), [
        [('SKK Veverky Brno A', CalendarSlot.secondary)],
      ]);
    });

    testWidgets('a team that is not in the calendar has nothing to choose',
        (tester) async {
      await tester.pumpWidget(harness(
        matches: schedule,
        followed: const ['SKK Veverky Brno A'],
        link: _linkedWithSecond,
      ));
      await open(tester);

      await tester.longPress(find.text('SKK Veverky Brno A'));
      await tester.pumpAndSettle();
      expect(find.text('Hlavní kalendář'), findsNothing);
    });

    testWidgets('picking the calendar it already had sends nothing',
        (tester) async {
      await tester.pumpWidget(harness(
        matches: schedule,
        teams: const [
          CalendarTeam(
              team: 'SKK Veverky Brno A', calendar: CalendarSlot.secondary),
        ],
        link: _linkedWithSecond,
      ));
      await open(tester);

      await tester.longPress(find.text('SKK Veverky Brno A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Druhý kalendář'));
      await tester.pumpAndSettle();
      await close(tester);
      // onCalendarChanged would have fail()ed had it been called.
    });
  });
}

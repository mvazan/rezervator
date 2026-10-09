import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/ui.dart' show dayFull;
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/day_edit.dart';
import 'package:rezervator/domain/groups.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/schedule.dart' show FreeSlot;
import 'package:rezervator/features/admin/widgets/block_dialog.dart';
import 'package:rezervator/features/clubhouse/match_detail_screen.dart';
import 'package:rezervator/features/schedule/widgets/day_watch_button.dart';
import 'package:rezervator/features/schedule/widgets/gap_rows.dart';
import 'package:rezervator/features/schedule/calendar_focus.dart';
import 'package:rezervator/features/schedule/widgets/slot_tile.dart';
import 'package:rezervator/features/schedule/week_calendar_view.dart';
import 'package:rezervator/features/schedule/schedule_callbacks.dart';
import 'package:rezervator/features/schedule/week_screen.dart';
import 'package:rezervator/features/schedule/widgets/calendar_board.dart';
import 'package:rezervator/features/schedule/widgets/day_chip_strip.dart';
import 'package:rezervator/features/schedule/widgets/day_header.dart';
import 'package:rezervator/features/schedule/widgets/schedule_day_column.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // WeekScreen reads the schedule_view preference on its first frame
  // (see _resolveInitialView) — every test needs a mock handler for the
  // platform channel behind SharedPreferences.getInstance(), or the read
  // hangs forever and pumpAndSettle times out. No stored value means every
  // test hits the width-based default, which is `week` (width ≥ 700).
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // Make the surface WIDE (1600×1200, landscape → week calendar): the
  // calendar's day columns clamp to 220px, so 7 columns + the hour ruler
  // (1586px) all build without horizontal scrolling — a test asserting on
  // e.g. Sunday's column would otherwise depend on the surface width.
  void wideSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  // PORTRAIT surface → the day pager (the view follows orientation since
  // the toggle buttons were dropped).
  void portraitSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  // Day headers live in the sticky strip ABOVE the scrolling columns (not
  // inside the ValueKey(date) column subtree), so they're found by their
  // typed date.
  Finder headerOf(Day date) => find.byWidgetPredicate(
      (w) => w is BoardColumnHeader && w.date == date);

  const settings = ScheduleSettings(
    laneCount: 2,
    trainingWeekdays: {1, 2, 3, 4, 5, 6, 7},
    bookingHorizonDays: 14,
    maxActiveReservations: 3,
  );
  const b1 = TimeBlock(
    id: 'b1',
    startsAt: HourMinute(22, 58),
    endsAt: HourMinute(23, 59),
    position: 0,
    active: true,
  );

  // The clock is PINNED (see the nowProvider override in `app`) so the week
  // strip is identical on every run. With the real clock the suite failed
  // every Sunday — `tomorrow` then falls into the next strip, whose column
  // the week view does not build — and again after 22:58, when the harness
  // block b1 turned `inPast` and nothing was bookable.
  final now = DateTime(2026, 9, 9, 10, 0); // středa dopoledne
  final t = Day.fromDateTime(now);
  final tomorrow = t.addDays(1);

  const me = Profile(
    id: 'me',
    displayName: 'Já Hráč',
    email: 'me@example.com',
    role: Role.player,
    status: ProfileStatus.approved,
  );

  const admin = Profile(
    id: 'me',
    displayName: 'Já Hráč',
    email: 'me@example.com',
    role: Role.admin,
    status: ProfileStatus.approved,
  );

  const uklidType = PrioritySlotType(
    id: 't-uklid',
    name: 'Úklid před zápasem',
    builtin: true,
  );

  Reservation res(String id, String playerId, Day date) => Reservation(
    id: id,
    playerId: playerId,
    date: date,
    blockId: 'b1',
    lane: 2,
    createdVia: 'app',
    createdAt: DateTime.utc(2026, 1, 1),
  );

  // The roster behind `playersProvider` unless a test passes its own: the
  // signed-in player plus one ordinary teammate with a nick.
  const players = [
    PlayerName(id: 'me', displayName: 'Já Hráč'),
    PlayerName(
      id: 'p2',
      displayName: 'Petr Novák',
      nick: 'Péťa',
    ),
  ];

  Widget app({
    List<DayOverride> overrides = const [],
    List<PrioritySlot> matches = const [],
    List<Reservation> reservations = const [],
    List<TimeBlock> blocks = const [b1],
    List<Rental> rentals = const [],
    Stream<List<Rental>>? rentalsStream,
    Profile profile = me,
    List<Widget> trailing = const [],
    List<PlayerName> roster = players,
    Map<String, int> activeCounts = const {},
    MyGroup group = MyGroup.none,
    Map<String, MatchResult> matchResults = const {},
    List<DutyPeriod> dutyPeriods = const [],
    List<DutyAssignment> dutyAssignments = const [],
    ScheduleSettings schedule = settings,
  }) {
    return ProviderScope(
      overrides: [
        // What Api.activeReservationCount would answer: the cap counts every
        // future date, which the drawn week alone cannot know.
        activeReservationCountProvider
            .overrideWith((ref, playerId) async => activeCounts[playerId] ?? 0),
        settingsProvider.overrideWith((ref) => Stream.value(schedule)),
        timeBlocksProvider.overrideWith((ref) => Stream.value(blocks)),
        dayOverridesProvider.overrideWith((ref) => Stream.value(overrides)),
        prioritySlotsProvider.overrideWithValue(matches),
        // Never watched by WeekScreen itself, but MatchDetailScreen (pushed
        // from the day-matches dialog's tap-through) does — without these,
        // its own defaults would reach through to real Supabase.
        prioritySlotsLoadingProvider.overrideWithValue(false),
        matchResultsProvider.overrideWith((ref) => Stream.value(matchResults)),
        matchPlayerResultsProvider.overrideWith(
          (ref, id) => Stream.value(const []),
        ),
        venuesProvider.overrideWith((ref) => Stream.value(const [])),
        rentalsProvider.overrideWith(
            (ref) => rentalsStream ?? Stream.value(rentals)),
        weekReservationsProvider.overrideWith(
          (ref, monday) => Stream.value(reservations),
        ),
        myActiveReservationsProvider.overrideWith(
          (ref) => Stream.value(reservations),
        ),
        myProfileProvider.overrideWith((ref) => Stream.value(profile)),
        playersProvider.overrideWith((ref) async => roster),
        nowProvider.overrideWith((ref) => Stream.value(now)),
        myGroupProvider.overrideWithValue(group),
        dutyPeriodsProvider.overrideWith((ref) => Stream.value(dutyPeriods)),
        dutyAssignmentsProvider.overrideWith(
          (ref) => Stream.value(dutyAssignments),
        ),
      ],
      child: MaterialApp(home: Scaffold(body: WeekScreen(trailing: trailing))),
    );
  }

  testWidgets('closed override renders the dimmed column with the reason', (
    tester,
  ) async {
    wideSurface(tester);
    await tester.pumpWidget(
      app(
        overrides: [
          DayOverride(date: tomorrow, closed: true, reason: 'Malování'),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('✕ zavřeno — Malování'), findsOneWidget);
  });

  testWidgets('a closed day hosting a match shows the band, not the zavřeno '
      'label', (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(
      app(
        overrides: [
          DayOverride(date: tomorrow, closed: true, reason: 'Malování'),
        ],
        matches: [
          PrioritySlot(
            id: 'm1',
            date: tomorrow,
            startsAt: const HourMinute(18, 30),
            endsAt: const HourMinute(22, 30),
            type: PrioritySlot.fallbackMatchType,
            homeTeam: 'Brno IV',
            awayTeam: 'Dubňany',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    // The match shows as the day-header line and as the time band.
    expect(find.textContaining('Brno IV – Dubňany'), findsWidgets);
    expect(find.textContaining('✕ zavřeno'), findsNothing);
  });

  testWidgets('reserved cell shows player nick when set, never full name', (
    tester,
  ) async {
    wideSurface(tester);
    await tester.pumpWidget(app(reservations: [res('r2', 'p2', tomorrow)]));
    await tester.pumpAndSettle();
    expect(find.text('Péťa'), findsOneWidget);
    expect(find.text('Petr Novák'), findsNothing);
  });

  testWidgets('tapping another player at once replaces the full-name snack, '
      'not queues behind it', (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(
      app(
        roster: const [
          PlayerName(id: 'me', displayName: 'Já Hráč'),
          PlayerName(id: 'p2', displayName: 'Petr Novák', nick: 'Péťa'),
          PlayerName(id: 'p3', displayName: 'Dalibor Dvorník', nick: 'Dalas'),
        ],
        reservations: [
          res('r2', 'p2', tomorrow),
          Reservation(
            id: 'r3',
            playerId: 'p3',
            date: tomorrow,
            blockId: 'b1',
            lane: 1,
            createdVia: 'app',
            createdAt: DateTime.utc(2026, 1, 1),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    for (final nick in ['Péťa', 'Dalas']) {
      await tester.ensureVisible(find.text(nick));
      await tester.pumpAndSettle();
    }

    await tester.tap(find.text('Péťa'));
    await tester.pump();
    await tester.tap(find.text('Dalas'));
    await tester.pump();
    // One frame later the first is gone, not animating out ahead of the
    // second — a queued snack would show only the first for ~4 seconds.
    expect(find.text('Dalibor Dvorník'), findsOneWidget);
    expect(find.text('Petr Novák'), findsNothing);
    expect(find.byType(SnackBar), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 10));
  });

  testWidgets('the freed-spot bell sits by the free-spot count on the wide '
      'board, for a player and not for the kiosk', (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.textContaining('volných'), findsWidgets);
    expect(find.byType(DayWatchButton), findsWidgets);
  });

  testWidgets('no bell on the kiosk\'s calendar', (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(
      app(
        profile: const Profile(
          id: 'k',
          displayName: 'Tablet',
          email: 'k@example.com',
          role: Role.kiosk,
          status: ProfileStatus.approved,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DayWatchButton), findsNothing);
  });

  testWidgets('tap on own reservation opens cancel dialog', (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(app(reservations: [res('r1', 'me', tomorrow)]));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Já Hráč').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Já Hráč').first);
    await tester.pumpAndSettle();
    expect(find.text('Zrušit rezervaci?'), findsOneWidget);
  });

  testWidgets('free bookable cell opens booking dialog', (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    // Book in `tomorrow`'s column, never in today's — the harness block
    // (22:58–23:59) makes today's slot `inPast` (so not bookable) once the
    // suite runs after 22:58, which would flake a `.first` (Monday) tap.
    final addInTomorrow = find.descendant(
      of: find.byKey(ValueKey(tomorrow)),
      matching: find.byIcon(Icons.add),
    );
    await tester.ensureVisible(addInTomorrow.first);
    await tester.pumpAndSettle();
    await tester.tap(addInTomorrow.first);
    await tester.pumpAndSettle();
    expect(find.text('Rezervovat termín?'), findsOneWidget);
  });

  testWidgets('admin booking dialog opens with a focused player search, '
      'já preselected', (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(app(profile: admin));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add).first);
    await tester.pumpAndSettle();
    expect(find.text('Rezervovat termín?'), findsOneWidget);
    final field = find.byType(TextField);
    expect(field, findsOneWidget);
    // Focused on open — the phone keyboard is up at once.
    expect(tester.widget<TextField>(field).autofocus, isTrue);
    expect(find.text('Vybráno: já'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'já'), findsOneWidget);
  });

  // The reporter's phone, to the pixel: 1080×2186 at 2.625, so 411×833 in
  // logical pixels, of which the keyboard takes some 330 — the dialog is
  // left with 455 to live in.
  void reporterPhone(WidgetTester tester, {double keyboard = 330}) {
    tester.view.physicalSize = const Size(1080, 2186);
    tester.view.devicePixelRatio = 2.625;
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard * 2.625);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
  }

  const crowd = [
    PlayerName(id: 'me', displayName: 'Já Hráč'),
    PlayerName(id: 'p2', displayName: 'Blanka Sedláková', nick: 'Blanka'),
    PlayerName(id: 'p3', displayName: 'Dalibor Dvorník', nick: 'Dalas'),
    PlayerName(id: 'p4', displayName: 'Tomáš Pavlů'),
    PlayerName(id: 'p5', displayName: 'Petr Novák', nick: 'Péťa'),
    PlayerName(id: 'p6', displayName: 'Bohumil Kroupa', nick: 'Bob'),
    PlayerName(id: 'p7', displayName: 'Šimon Řezáč'),
    PlayerName(id: 'p8', displayName: 'Květa Malá'),
  ];

  /// The dialog's own surface — an AlertDialog's box is the whole screen.
  Rect dialogSurface(WidgetTester tester) => tester.getRect(find
      .descendant(of: find.byType(Dialog), matching: find.byType(Material))
      .first);

  testWidgets('with the keyboard up the names stay inside the dialog, under a '
      'search field that stays put', (tester) async {
    reporterPhone(tester);
    await tester.pumpWidget(app(profile: admin, roster: crowd));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add).first);
    await tester.pumpAndSettle();
    expect(find.text('Rezervovat termín?'), findsOneWidget);
    expect(tester.takeException(), isNull,
        reason: 'the content has to fit the room the keyboard leaves');

    // Nothing of the dialog is drawn past its own edge — that is what the
    // report showed: names across the page, Zrušit and Rezervovat on top.
    final surface = dialogSurface(tester);
    final list = find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(ListView));
    expect(tester.getRect(list).bottom, lessThanOrEqualTo(surface.bottom));
    expect(
        tester.getRect(find.widgetWithText(FilledButton, 'Rezervovat')).bottom,
        lessThanOrEqualTo(surface.bottom + 0.5),
        reason: 'the names must not push the buttons out of the dialog');

    // Only the NAMES scroll: the field you are typing in holds its place.
    final field = tester.getRect(find.byType(TextField));
    final last = find.text('Květa Malá');
    expect(last, findsNothing, reason: 'the last name is below the fold');
    await tester.drag(list, const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byType(TextField)), field);
    expect(tester.getRect(last).bottom,
        lessThanOrEqualTo(tester.getRect(list).bottom + 0.5),
        reason: 'and scrolling the list brings it into view');

    // Reaching for the names also lets the keyboard go, which is where the
    // dialog gets its height back from.
    expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus,
        isFalse);

    await tester.tap(find.widgetWithText(ListTile, 'Květa Malá'));
    await tester.pumpAndSettle();
    expect(find.text('Vybráno: Květa Malá'), findsOneWidget);
  });

  // Typing filters the list, and a list that shrinks used to take the
  // dialog with it: the box jumped under the finger doing the typing.
  for (final keyboard in [0.0, 330.0]) {
    testWidgets(
        'the dialog holds its height while the search narrows'
        '${keyboard == 0 ? '' : ' (keyboard up)'}', (tester) async {
      reporterPhone(tester, keyboard: keyboard);
      await tester.pumpWidget(app(profile: admin, roster: crowd));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.add).first);
      await tester.pumpAndSettle();
      final before = dialogSurface(tester);

      await tester.enterText(find.byType(TextField), 'kv');
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'Květa Malá'), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Petr Novák'), findsNothing);
      expect(dialogSurface(tester), before,
          reason: 'eight names down to one must not move the dialog');

      // Nor when nothing matches at all.
      await tester.enterText(find.byType(TextField), 'xyz');
      await tester.pumpAndSettle();
      expect(find.text('Nikdo neodpovídá hledání.'), findsOneWidget);
      expect(dialogSurface(tester), before);
    });
  }

  testWidgets('the cap warning waits for the keyboard to go', (tester) async {
    reporterPhone(tester);
    await tester.pumpWidget(app(
      profile: admin,
      roster: crowd,
      activeCounts: const {'me': 3},
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add).first);
    await tester.pumpAndSettle();

    // Three lines of warning while searching would be two names fewer.
    expect(find.textContaining('maximální počet rezervací'), findsNothing);

    // Picking a name closes the keyboard; the dialog gets its height back
    // and the warning is there to read before Rezervovat.
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();
    expect(
        find.text('Máš už maximální počet rezervací (3). Jako správce si ji '
            'můžeš vytvořit i tak.'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('player search matches the name or the board nick, '
      'tapping picks the player', (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(app(
      profile: admin,
      roster: const [
        PlayerName(id: 'p2', displayName: 'Petr Novák', nick: 'Péťa'),
        PlayerName(id: 'p3', displayName: 'Bohumil Kroupa', nick: 'Bob'),
        PlayerName(id: 'p4', displayName: 'Šimon Řezáč'),
      ],
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add).first);
    await tester.pumpAndSettle();

    // Nick, case- and diacritics-insensitive.
    await tester.enterText(find.byType(TextField), 'peta');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Petr Novák'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'já'), findsNothing);
    expect(find.text('Bohumil Kroupa'), findsNothing);

    // Surname fragment with diacritics folded.
    await tester.enterText(find.byType(TextField), 'rezac');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Šimon Řezáč'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Petr Novák'), findsNothing);

    await tester.tap(find.widgetWithText(ListTile, 'Šimon Řezáč'));
    await tester.pumpAndSettle();
    expect(find.text('Vybráno: Šimon Řezáč'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'xyz');
    await tester.pumpAndSettle();
    expect(find.text('Nikdo neodpovídá hledání.'), findsOneWidget);
    // The pick survives a search that hides it.
    expect(find.text('Vybráno: Šimon Řezáč'), findsOneWidget);
  });

  // create_reservation lets an ADMIN book past max_active_reservations
  // (the limit branch is skipped for admins) — so the dialog warns and
  // still books, rather than hiding the player or refusing.
  testWidgets('a player at the cap is flagged in the booking dialog, and the '
      'admin can book anyway', (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(app(
      profile: admin,
      roster: const [
        PlayerName(id: 'p2', displayName: 'Petr Novák'),
        PlayerName(id: 'p3', displayName: 'Eva Malá'),
      ],
      // settings.maxActiveReservations is 3 in this suite.
      activeCounts: const {'p2': 3, 'p3': 1},
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add).first);
    await tester.pumpAndSettle();
    expect(find.textContaining('maximální počet rezervací'), findsNothing,
        reason: 'já holds nothing here');

    await tester.tap(find.widgetWithText(ListTile, 'Petr Novák'));
    await tester.pumpAndSettle();
    expect(
      find.text('Petr Novák už má maximální počet rezervací (3). '
          'Jako správce ji můžeš vytvořit i tak.'),
      findsOneWidget,
    );
    // Warned, not blocked.
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Rezervovat'))
          .onPressed,
      isNotNull,
    );

    // Someone under the cap draws no warning.
    await tester.tap(find.widgetWithText(ListTile, 'Eva Malá'));
    await tester.pumpAndSettle();
    expect(find.textContaining('maximální počet rezervací'), findsNothing);
  });

  // An admin at their own cap is warned in the second person — "Já Hráč už
  // má maximální počet rezervací" reads like a note about a stranger.
  testWidgets('an admin at their own cap is told so in their own words',
      (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(app(
      profile: admin,
      activeCounts: const {'me': 3},
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add).first);
    await tester.pumpAndSettle();

    expect(
      find.text('Máš už maximální počet rezervací (3). Jako správce si ji '
          'můžeš vytvořit i tak.'),
      findsOneWidget,
    );
  });

  testWidgets('admin booking dialog marks players without an account', (
    tester,
  ) async {
    wideSurface(tester);
    await tester.pumpWidget(app(
      profile: admin,
      roster: [
        ...players,
        const PlayerName(
          id: 'p3',
          displayName: 'Bohumil Kroupa',
          hasAccount: false,
        ),
      ],
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add).first);
    await tester.pumpAndSettle();
    expect(find.text('Rezervovat termín?'), findsOneWidget);
    // A hand-made "hráč bez účtu" is flagged in the picker — the booking
    // will never reach an inbox, so the admin should know whom they pick…
    expect(find.widgetWithText(ListTile, 'Bohumil Kroupa · bez účtu'),
        findsOneWidget);
    // …while an ordinary teammate keeps a bare name.
    expect(find.widgetWithText(ListTile, 'Petr Novák'), findsOneWidget);
    expect(find.text('Petr Novák · bez účtu'), findsNothing);
  });

  testWidgets('admin tap on foreign reservation opens the cancel dialog with '
      'the notify choice, naming the player — the board nick alone is not '
      'always enough to tell who is who', (
    tester,
  ) async {
    wideSurface(tester);
    await tester.pumpWidget(
      app(profile: admin, reservations: [res('r2', 'p2', tomorrow)]),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Péťa').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Péťa').first);
    await tester.pumpAndSettle();
    expect(find.text('Zrušit rezervaci'), findsOneWidget);
    // 'Péťa' is the tapped nick; 'Petr Novák' is the name this dialog adds.
    expect(find.textContaining('Petr Novák'), findsOneWidget);
    expect(find.text('Zrušit a poslat zprávu'), findsOneWidget);
    expect(find.text('Zrušit bez zprávy'), findsOneWidget);
  });

  testWidgets("admin cancel of a hráč bez účtu's reservation asks plainly — "
      'nobody to message — and still names the player behind the board nick',
      (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(app(
      profile: admin,
      roster: const [
        ...players,
        PlayerName(
          id: 'p3',
          displayName: 'Bohumil Kroupa',
          nick: 'Bob',
          hasAccount: false,
        ),
      ],
      reservations: [res('r3', 'p3', tomorrow)],
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Bob').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bob').first);
    await tester.pumpAndSettle();

    expect(find.text('Zrušit rezervaci?'), findsOneWidget);
    // 'Bob' is the tapped nick; 'Bohumil Kroupa' is the name this dialog adds.
    expect(find.textContaining('Bohumil Kroupa'), findsOneWidget);
    expect(find.textContaining('Hráč bez účtu se o zrušení nedozví.'),
        findsOneWidget);
    expect(find.text('Zrušit a poslat zprávu'), findsNothing);
    expect(find.text('Zrušit bez zprávy'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Zpět'), findsOneWidget);
    expect(find.text('Zrušit rezervaci'), findsOneWidget);
  });

  testWidgets('non-admin tap on foreign reservation shows the full name — '
      'not a cancel dialog, they cannot cancel someone else\'s booking', (
    tester,
  ) async {
    wideSurface(tester);
    await tester.pumpWidget(app(reservations: [res('r2', 'p2', tomorrow)]));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Péťa').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Péťa').first);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Petr Novák'), findsOneWidget);
  });

  testWidgets('in a group a free cell asks for whom', (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(app(
      group: const MyGroup(groupId: 'g', memberIds: ['me', 'p2']),
    ));
    await tester.pumpAndSettle();
    // Book in `tomorrow`'s column, same cell-finding as the plain booking
    // test above.
    final addInTomorrow = find.descendant(
      of: find.byKey(ValueKey(tomorrow)),
      matching: find.byIcon(Icons.add),
    );
    await tester.ensureVisible(addInTomorrow.first);
    await tester.pumpAndSettle();
    await tester.tap(addInTomorrow.first);
    await tester.pumpAndSettle();
    expect(find.text('Pro koho'), findsOneWidget);
    expect(find.text('Petr Novák'), findsOneWidget);
  });

  // The group dialog knows the cap (0044): create_reservation holds every
  // booked player to their own, so offering someone at it only earns a
  // refusal. Two mates, so the preselection has one to skip.
  group('the group booking dialog at the cap', () {
    const trio = MyGroup(groupId: 'g', memberIds: ['me', 'p2', 'p3']);
    const roster = [
      ...players,
      PlayerName(id: 'p3', displayName: 'Žofie Adamová'),
    ];

    Future<void> openDialog(
      WidgetTester tester,
      Map<String, int> activeCounts,
    ) async {
      wideSurface(tester);
      await tester.pumpWidget(app(
        group: trio,
        roster: roster,
        activeCounts: activeCounts,
      ));
      await tester.pumpAndSettle();
      final addInTomorrow = find.descendant(
        of: find.byKey(ValueKey(tomorrow)),
        matching: find.byIcon(Icons.add),
      );
      await tester.ensureVisible(addInTomorrow.first);
      await tester.pumpAndSettle();
      await tester.tap(addInTomorrow.first);
      await tester.pumpAndSettle();
      expect(find.text('Pro koho'), findsOneWidget);
    }

    RadioListTile<String> option(WidgetTester tester, String name) =>
        tester.widget<RadioListTile<String>>(
          find.widgetWithText(RadioListTile<String>, name),
        );
    String? chosen(WidgetTester tester) => tester
        .widget<RadioGroup<String>>(find.byType(RadioGroup<String>))
        .groupValue;
    VoidCallback? book(WidgetTester tester) => tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Rezervovat'))
        .onPressed;

    testWidgets('under the cap nothing changes: Já first and chosen',
        (tester) async {
      await openDialog(tester, const {});
      expect(option(tester, 'Já').enabled, isNot(false));
      expect(option(tester, 'Petr Novák').enabled, isNot(false));
      expect(option(tester, 'Žofie Adamová').enabled, isNot(false));
      expect(chosen(tester), 'me');
      expect(book(tester), isNotNull);
      expect(find.textContaining('maximální počet'), findsNothing);
    });

    testWidgets('me at my cap: Já is disabled, the first mate is chosen',
        (tester) async {
      await openDialog(tester, const {'me': 3});
      expect(option(tester, 'Já').enabled, isFalse);
      expect(
        find.widgetWithText(
            RadioListTile<String>, 'Máš maximální počet rezervací.'),
        findsOneWidget,
      );
      expect(chosen(tester), 'p2');
      expect(book(tester), isNotNull);
    });

    testWidgets('a mate at their cap is disabled and skipped',
        (tester) async {
      await openDialog(tester, const {'me': 3, 'p2': 3});
      expect(option(tester, 'Petr Novák').enabled, isFalse);
      expect(
        find.widgetWithText(
            RadioListTile<String>, 'Má maximální počet rezervací.'),
        findsOneWidget,
      );
      expect(option(tester, 'Žofie Adamová').enabled, isNot(false));
      expect(chosen(tester), 'p3');
      expect(book(tester), isNotNull);
    });

    testWidgets('everybody at the cap: Rezervovat is disabled',
        (tester) async {
      await openDialog(tester, const {'me': 3, 'p2': 4, 'p3': 3});
      expect(option(tester, 'Já').enabled, isFalse);
      expect(option(tester, 'Petr Novák').enabled, isFalse);
      expect(option(tester, 'Žofie Adamová').enabled, isFalse);
      expect(book(tester), isNull);
    });
  });

  testWidgets('without a group the plain confirm stays', (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final addInTomorrow = find.descendant(
      of: find.byKey(ValueKey(tomorrow)),
      matching: find.byIcon(Icons.add),
    );
    await tester.ensureVisible(addInTomorrow.first);
    await tester.pumpAndSettle();
    await tester.tap(addInTomorrow.first);
    await tester.pumpAndSettle();
    expect(find.text('Rezervovat termín?'), findsOneWidget);
    expect(find.text('Pro koho'), findsNothing);
  });

  testWidgets('in a group at my own cap the free cells keep their full ＋; '
      'the past and beyond the horizon stay quiet, and without a group no ＋ '
      'at all', (
    tester,
  ) async {
    wideSurface(tester);
    // Three of my own ahead: the cap (3) is reached. A mate's booking
    // counts against the mate's cap, so the cells stay open for them.
    final mine = [
      for (var i = 1; i <= 3; i++) res('r$i', 'me', t.addDays(i)),
    ];
    // A two-day horizon: Sunday (t + 4) is drawn but beyond it.
    await tester.pumpWidget(app(
      group: const MyGroup(groupId: 'g', memberIds: ['me', 'p2']),
      reservations: mine,
      schedule: const ScheduleSettings(
        laneCount: 2,
        trainingWeekdays: {1, 2, 3, 4, 5, 6, 7},
        bookingHorizonDays: 2,
        maxActiveReservations: 3,
      ),
    ));
    await tester.pumpAndSettle();

    List<SlotTile> freeIn(Day day) => [
          for (final tile in tester.widgetList<SlotTile>(
            find.descendant(
              of: find.byKey(ValueKey(day)),
              matching: find.byType(SlotTile),
            ),
          ))
            if (tile.state is FreeSlot) tile,
        ];

    // Quiet is for cells only the admin exemption opens — tomorrow's are
    // ordinarily bookable for a mate.
    final future = freeIn(tomorrow);
    expect(future, isNotEmpty);
    expect(future.where((tile) => tile.onTap == null), isEmpty);
    expect(future.where((tile) => tile.quiet), isEmpty);

    // Yesterday stays locked: inert and quiet.
    final past = freeIn(t.addDays(-1));
    expect(past, isNotEmpty);
    expect(past.where((tile) => tile.onTap != null), isEmpty);
    expect(past.where((tile) => !tile.quiet), isEmpty);

    // Beyond the horizon the group opens nothing either: inert and quiet.
    final beyond = freeIn(t.addDays(4));
    expect(beyond, isNotEmpty);
    expect(beyond.where((tile) => tile.onTap != null), isEmpty);
    expect(beyond.where((tile) => !tile.quiet), isEmpty);

    // The same counts without a group: no ＋ in tomorrow's column.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app(reservations: mine));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(ValueKey(tomorrow)),
        matching: find.byIcon(Icons.add),
      ),
      findsNothing,
    );
  });

  testWidgets("a group mate's reservation offers the cancel, naming them",
      (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(app(
      reservations: [res('r1', 'p2', tomorrow)],
      group: const MyGroup(groupId: 'g', memberIds: ['me', 'p2']),
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Péťa').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Péťa').first);
    await tester.pumpAndSettle();
    expect(find.text('Zrušit rezervaci?'), findsOneWidget);
    // 'Péťa' is the tapped nick; 'Petr Novák' is the name this dialog adds.
    expect(find.textContaining('Petr Novák'), findsOneWidget);
    expect(find.textContaining('Dostane o tom zprávu.'), findsOneWidget);
  });

  testWidgets("outside the group the same tap only names the player",
      (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(app(reservations: [res('r1', 'p2', tomorrow)]));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Péťa').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Péťa').first);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('Petr Novák'), findsOneWidget);
  });

  group('the match bar in the day card', () {
    PrioritySlot match({String? importKey}) => PrioritySlot(
          id: 'm1',
          date: tomorrow,
          startsAt: const HourMinute(18, 0),
          endsAt: const HourMinute(21, 0),
          type: PrioritySlot.fallbackMatchType,
          homeTeam: 'Brno IV',
          awayTeam: 'Dubňany',
          importKey: importKey,
        );

    Future<void> openTomorrow(WidgetTester tester) async {
      final chips = find.descendant(
        of: find.byType(DayChipStrip),
        matching: find.byType(InkWell),
      );
      await tester.tap(chips.at(t.weekday));
      await tester.pumpAndSettle();
    }

    testWidgets('a federation match opens its detail on a tap', (
      tester,
    ) async {
      portraitSurface(tester);
      await tester.pumpWidget(app(matches: [match(importKey: 'cka:m1')]));
      await tester.pumpAndSettle();
      await openTomorrow(tester);

      final bar = find.byType(GapEventBanner);
      expect(bar, findsOneWidget);
      await tester.ensureVisible(bar);
      await tester.tap(bar);
      await tester.pumpAndSettle();
      expect(find.byType(MatchDetailScreen), findsOneWidget);
    });

    testWidgets('a match of our own entering is no federation match: no '
        'tap-through', (tester) async {
      portraitSurface(tester);
      await tester.pumpWidget(app(matches: [match()]));
      await tester.pumpAndSettle();
      await openTomorrow(tester);

      final bar = find.byType(GapEventBanner);
      await tester.ensureVisible(bar);
      await tester.tap(bar);
      await tester.pumpAndSettle();
      expect(find.byType(MatchDetailScreen), findsNothing);
    });
  });

  testWidgets('whole-alley match cancels the touched block for its day and '
      'renders as a true-time band', (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(
      app(
        matches: [
          PrioritySlot(
            type: PrioritySlot.fallbackMatchType,
            id: 'm1',
            date: tomorrow,
            startsAt: const HourMinute(22, 58),
            endsAt: const HourMinute(23, 59),
            homeTeam: '',
            awayTeam: 'KK Slavoj',
            prepMinutes: 0,
            description: '',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    // Once in the day header strip, once as the true-time band.
    expect(find.textContaining('KK Slavoj'), findsNWidgets(2));
    // Tomorrow's block card is CANCELLED (gone), and with it every bookable
    // lane row; the other six days keep the block.
    final cardInTomorrow = find.descendant(
      of: find.byKey(ValueKey(tomorrow)),
      matching: find.byKey(const ValueKey('cal-block-b1')),
    );
    expect(cardInTomorrow, findsNothing);
    expect(find.byKey(const ValueKey('cal-block-b1')), findsNWidgets(6));
    final addInTomorrow = find.descendant(
      of: find.byKey(ValueKey(tomorrow)),
      matching: find.byIcon(Icons.add),
    );
    expect(addInTomorrow, findsNothing);
  });

  testWidgets('the úklid child renders as its own band at its real time and '
      'cancels the block it covers', (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(
      app(
        matches: [
          PrioritySlot(
            type: PrioritySlot.fallbackMatchType,
            id: 'm2',
            date: tomorrow,
            startsAt: const HourMinute(23, 30),
            endsAt: const HourMinute(23, 59),
            homeTeam: '',
            awayTeam: 'KK Slavoj',
            description: '',
          ),
          PrioritySlot(
            type: uklidType,
            id: 'u2',
            date: tomorrow,
            startsAt: const HourMinute(22, 58),
            endsAt: const HourMinute(23, 30),
            parentId: 'm2',
            description: '',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('⛔ Úklid před zápasem\n22:58–23:30'),
      findsOneWidget,
    );
    // The úklid (whole-alley) cancelled b1 for that day.
    final cardInTomorrow = find.descendant(
      of: find.byKey(ValueKey(tomorrow)),
      matching: find.byKey(const ValueKey('cal-block-b1')),
    );
    expect(cardInTomorrow, findsNothing);
  });

  testWidgets('one-line header: action icons hug the right edge, the week '
      'nav sits in the middle (title takes no flex share)', (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(app(trailing: [
      IconButton(
        icon: const Icon(Icons.account_circle_outlined),
        onPressed: () {},
      ),
    ]));
    await tester.pumpAndSettle();

    final icon = tester.getCenter(find.byIcon(Icons.account_circle_outlined));
    expect(icon.dx, greaterThan(1600 - 80)); // pinned right
    final nav = tester.getCenter(find.byIcon(Icons.chevron_left));
    // Nav group centered in the middle region — a regression to the
    // Flexible-title bug parked it (and the icons) around 1/3 of the width.
    expect(nav.dx, greaterThan(500));
    expect(find.text('Rezervátor'), findsOneWidget);
  });

  testWidgets('the week calendar opens scrolled to the first TRAINING '
      'block, not to a morning match stretching the window', (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(
      app(
        matches: [
          PrioritySlot(
            type: PrioritySlot.fallbackMatchType,
            id: 'm-morning',
            date: tomorrow,
            startsAt: const HourMinute(9, 0),
            endsAt: const HourMinute(11, 0),
            homeTeam: '',
            awayTeam: 'KK Ranní',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // The window starts at the 9:00 match, but the initial scroll anchors
    // at the 22:58 block — the vertical offset is well past zero.
    final scrollable = tester
        .widgetList<Scrollable>(find.byType(Scrollable))
        .map((s) => s.controller)
        .whereType<ScrollController>()
        .where((c) => c.hasClients && c.position.axis == Axis.vertical)
        .toList();
    expect(scrollable, isNotEmpty);
    expect(scrollable.first.offset, greaterThan(100));
  });

  testWidgets('a morning event arriving AFTER the first frame re-anchors '
      'the initial scroll onto the training blocks', (tester) async {
    wideSurface(tester);
    final rentalsCtrl = StreamController<List<Rental>>();
    addTearDown(rentalsCtrl.close);
    await tester.pumpWidget(app(rentalsStream: rentalsCtrl.stream));
    await tester.pumpAndSettle();

    // Streams settle one by one in production: the morning rental lands
    // AFTER the board already rendered (and consumed a zero anchor).
    rentalsCtrl.add([
      Rental(
        id: 'n1',
        renterName: 'Firma X',
        lanes: const [1],
        date: tomorrow,
        weekday: null,
        startsAt: const HourMinute(9, 0),
        endsAt: const HourMinute(11, 0),
        validFrom: null,
        validUntil: null,
        note: '',
      ),
    ]);
    await tester.pumpAndSettle();

    final vertical = tester
        .widgetList<Scrollable>(find.byType(Scrollable))
        .map((s) => s.controller)
        .whereType<ScrollController>()
        .where((c) => c.hasClients && c.position.axis == Axis.vertical)
        .toList();
    expect(vertical, isNotEmpty);
    expect(vertical.first.offset, greaterThan(100));
  });

  testWidgets('the view follows orientation: landscape shows the week '
      'calendar, portrait the day pager — no toggle buttons', (
    tester,
  ) async {
    wideSurface(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.byType(WeekCalendarView), findsOneWidget);
    expect(find.byType(DayChipStrip), findsNothing);
    expect(find.bySubtype<SegmentedButton>(), findsNothing);
    expect(find.byIcon(Icons.fit_screen_outlined), findsNothing);

    // Rotate to portrait: the day pager takes over.
    tester.view.physicalSize = const Size(900, 1600);
    await tester.pumpAndSettle();
    expect(find.byType(DayChipStrip), findsOneWidget);
    expect(find.byType(WeekCalendarView), findsNothing);
  });

  testWidgets(
    'fit-width calendar has no horizontal Scrollable — columns share the '
    'width',
    (tester) async {
      SharedPreferences.setMockInitialValues({'fit_width': true});
      wideSurface(tester);
      await tester.pumpWidget(app(reservations: [res('r2', 'p2', tomorrow)]));
      await tester.pumpAndSettle();

      expect(find.byType(WeekCalendarView), findsOneWidget);
      final horizontalScrollables = find
          .byType(Scrollable)
          .evaluate()
          .map((e) => e.widget as Scrollable)
          .where((s) => s.axisDirection == AxisDirection.right)
          .toList();
      expect(horizontalScrollables, isEmpty);
      // All 7 day columns are present at once.
      expect(find.byType(BoardColumnHeader), findsNWidgets(7));
    },
  );

  testWidgets('day view: the time label sits level with its own row, at any '
      'text size', (tester) async {
    // It used to be nudged down by a fixed 14 px against a top-aligned row,
    // which lined up only at the default size: at 130 % the label wraps to
    // two lines and the cells grow, and the time floated above its row.
    for (final scale in [1.0, 1.3]) {
      portraitSurface(tester);
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      final chips = find.descendant(
        of: find.byType(DayChipStrip),
        matching: find.byType(InkWell),
      );
      await tester.tap(chips.at(t.weekday));
      await tester.pumpAndSettle();

      // A block label reads „15:30–16:30"; the week range „7.9.–13.9." must
      // not be mistaken for one.
      final label = find.textContaining(RegExp(r'^\d{1,2}:\d{2}–')).first;
      final labelBox = tester.getRect(label);
      final cells = find.byType(SlotTile);
      expect(cells, findsWidgets);

      // The cell of the label's own row: the one whose vertical span holds
      // the label's middle. If the label floats above its row, none does.
      final rowCells = [
        for (var i = 0; i < tester.widgetList(cells).length; i++)
          tester.getRect(cells.at(i)),
      ].where((r) => r.top <= labelBox.center.dy && labelBox.center.dy <= r.bottom);
      expect(rowCells, isNotEmpty,
          reason: 'at ${scale}x the time floats outside every cell of its row');

      final cell = rowCells.first;
      expect(
        (labelBox.center.dy - cell.center.dy).abs(),
        lessThan(6),
        reason: 'at ${scale}x the time is not centred on its row',
      );
    }
  });

  testWidgets('booking dialog opens from a large free tile in day view', (
    tester,
  ) async {
    portraitSurface(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.byType(DayChipStrip), findsOneWidget);

    // Tomorrow, which the pinned clock keeps inside this Mon..Sun strip and
    // in the future, so the day is bookable. `t.weekday` (1..7) is the
    // 0-based index of tomorrow in the strip.
    final chips = find.descendant(
      of: find.byType(DayChipStrip),
      matching: find.byType(InkWell),
    );
    await tester.tap(chips.at(t.weekday));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.add).first);
    await tester.pumpAndSettle();
    expect(find.text('Rezervovat termín?'), findsOneWidget);
  });

  testWidgets('off-block rental renders as a band with real times', (
    tester,
  ) async {
    wideSurface(tester);
    final rental = Rental(
      id: 'n1',
      renterName: 'Firma X',
      lanes: const [1],
      date: tomorrow,
      weekday: null,
      startsAt: const HourMinute(12, 0),
      endsAt: const HourMinute(14, 0),
      validFrom: null,
      validUntil: null,
      note: '',
    );
    await tester.pumpWidget(app(rentals: [rental]));
    await tester.pumpAndSettle();
    expect(find.text('🔒 Firma X\n12:00–14:00'), findsOneWidget);
  });

  // A weekly 'Firma X' series on lane 1 — by default over the harness block
  // b1, so its resolved occurrence lands in tomorrow's column as a rented
  // lane row (no off-block part, hence no band).
  Rental weeklyFirmaX({
    HourMinute startsAt = const HourMinute(22, 58),
    HourMinute endsAt = const HourMinute(23, 59),
  }) =>
      Rental(
        id: 'n1',
        renterName: 'Firma X',
        lanes: const [1],
        date: null,
        weekday: tomorrow.weekday,
        startsAt: startsAt,
        endsAt: endsAt,
        validFrom: null,
        validUntil: null,
        note: '',
      );

  // The rented lane-1 cell in tomorrow's block card. A band would carry a
  // different text ('🔒 Firma X\n…'), the header strip lists matches only.
  Finder rentedCellInTomorrow() => find.descendant(
        of: find.byKey(ValueKey(tomorrow)),
        matching: find.text('Firma X'),
      );

  testWidgets('admin taps a rented cell of a weekly rental into the '
      '"jen tento den" exception dialog for that date', (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(app(profile: admin, rentals: [weeklyFirmaX()]));
    await tester.pumpAndSettle();

    final cell = rentedCellInTomorrow();
    expect(cell, findsOneWidget);
    await tester.ensureVisible(cell);
    await tester.pumpAndSettle();
    await tester.tap(cell);
    await tester.pumpAndSettle();

    expect(find.text('Výjimka pronájmu'), findsOneWidget);
    expect(find.textContaining('jen ${dayFull(tomorrow)}'), findsOneWidget);
    // No exception row exists yet, so there is nothing to remove.
    expect(find.text('Zrušit výjimku'), findsNothing);
  });

  testWidgets('admin clicks an off-block rental band of a weekly rental '
      'into the same exception dialog', (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(app(
      profile: admin,
      rentals: [
        weeklyFirmaX(
          startsAt: const HourMinute(12, 0),
          endsAt: const HourMinute(14, 0),
        ),
      ],
    ));
    await tester.pumpAndSettle();

    final band = find.text('🔒 Firma X\n12:00–14:00');
    expect(band, findsOneWidget);
    await tester.ensureVisible(band);
    await tester.pumpAndSettle();
    await tester.tap(band);
    await tester.pumpAndSettle();

    expect(find.text('Výjimka pronájmu'), findsOneWidget);
    expect(find.textContaining('jen ${dayFull(tomorrow)}'), findsOneWidget);
  });

  testWidgets('admin taps a ONE-TIME rental cell into the plain edit dialog, '
      'not the exception one', (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(app(
      profile: admin,
      rentals: [
        Rental(
          id: 'n1',
          renterName: 'Firma X',
          lanes: const [1],
          date: tomorrow,
          weekday: null,
          startsAt: const HourMinute(22, 58),
          endsAt: const HourMinute(23, 59),
          validFrom: null,
          validUntil: null,
          note: '',
        ),
      ],
    ));
    await tester.pumpAndSettle();

    final cell = rentedCellInTomorrow();
    await tester.ensureVisible(cell);
    await tester.pumpAndSettle();
    await tester.tap(cell);
    await tester.pumpAndSettle();

    expect(find.text('Upravit pronájem'), findsOneWidget);
    expect(find.text('Nájemce'), findsOneWidget,
        reason: 'a lone one-off owns its name and colour');
    expect(find.text('Výjimka pronájmu'), findsNothing);
  });

  testWidgets('admin taps a GROUPED date into the one-date dialog, which '
      'offers no Nájemce and no Barva', (tester) async {
    // A date of a nepravidelný pronájem (0041): name and colour belong to
    // the group, and rental_group_guard copies them back over any PATCH.
    // Offering the plain rental form here would promise an edit the server
    // silently throws away and still snack "Pronájem uložen."
    wideSurface(tester);
    await tester.pumpWidget(app(
      profile: admin,
      rentals: [
        Rental(
          id: 'n1',
          renterName: 'Firma X',
          lanes: const [1],
          date: tomorrow,
          weekday: null,
          startsAt: const HourMinute(22, 58),
          endsAt: const HourMinute(23, 59),
          validFrom: null,
          validUntil: null,
          note: '',
          groupId: 'g1',
        ),
      ],
    ));
    await tester.pumpAndSettle();

    final cell = rentedCellInTomorrow();
    await tester.ensureVisible(cell);
    await tester.pumpAndSettle();
    await tester.tap(cell);
    await tester.pumpAndSettle();

    expect(find.text('Upravit termín'), findsOneWidget);
    expect(find.text('Upravit pronájem'), findsNothing);
    expect(find.text('Nájemce'), findsNothing,
        reason: 'the name lives on the group, not on the date');
    expect(find.text('Barva'), findsNothing,
        reason: 'so does the colour');
    // What the date DOES own is all there.
    expect(find.text('Datum'), findsOneWidget);
    expect(find.text('Poznámka'), findsOneWidget);
  });

  testWidgets('a rented cell already shaped by an exception row opens the '
      'dialog ON that row — Zrušit výjimku is offered', (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(app(
      profile: admin,
      rentals: [
        weeklyFirmaX(),
        // Tomorrow's exception row under the series: same lane and times.
        Rental(
          id: 'n1x',
          parentId: 'n1',
          renterName: 'Firma X',
          lanes: const [1],
          date: tomorrow,
          weekday: null,
          startsAt: const HourMinute(22, 58),
          endsAt: const HourMinute(23, 59),
          validFrom: null,
          validUntil: null,
          note: '',
        ),
      ],
    ));
    await tester.pumpAndSettle();

    final cell = rentedCellInTomorrow();
    expect(cell, findsOneWidget);
    await tester.ensureVisible(cell);
    await tester.pumpAndSettle();
    await tester.tap(cell);
    await tester.pumpAndSettle();

    expect(find.text('Výjimka pronájmu'), findsOneWidget);
    expect(find.text('Zrušit výjimku'), findsOneWidget);
  });

  testWidgets('a player tapping a rented cell opens nothing', (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(app(rentals: [weeklyFirmaX()]));
    await tester.pumpAndSettle();

    final cell = rentedCellInTomorrow();
    expect(cell, findsOneWidget);
    await tester.ensureVisible(cell);
    await tester.pumpAndSettle();
    await tester.tap(cell);
    await tester.pumpAndSettle();

    expect(find.text('Výjimka pronájmu'), findsNothing);
    expect(find.text('Upravit pronájem'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
  });

  const bEarly = TimeBlock(
    id: 'bEarly',
    startsAt: HourMinute(20, 0),
    endsAt: HourMinute(21, 0),
    position: 1,
    active: true,
  );

  testWidgets('admin clicks the card time header into the edit dialog', (
    tester,
  ) async {
    wideSurface(tester);
    await tester.pumpWidget(app(profile: admin));
    await tester.pumpAndSettle();

    // Every card carries a clickable time header with an edit glyph. Target
    // `tomorrow`'s column, never `.first` (Monday) — editing a past day is
    // guarded off, so `.first` only works when the suite runs on a Monday.
    expect(find.byIcon(Icons.edit_outlined), findsWidgets);
    final header = find.descendant(
      of: find.descendant(
        of: find.byKey(ValueKey(tomorrow)),
        matching: find.byKey(const ValueKey('cal-block-b1')),
      ),
      matching: find.text(b1.label),
    );
    await tester.tap(header);
    await tester.pumpAndSettle();

    expect(find.textContaining('Upravit blok — jen'), findsOneWidget);
    expect(find.text('Odebrat v tento den'), findsOneWidget);
    expect(find.text('Deaktivovat'), findsNothing); // global action lives in Rozvrh
  });

  // Only the label and the pencil shrink in a narrow column; the tap target
  // stays the header strip's full width, edge to edge.
  for (final (label, surface) in [
    ('wide', const Size(1600, 1200)),
    ('narrow', const Size(800, 400)),
  ]) {
    testWidgets('$label: the whole header strip opens the block edit', (
      tester,
    ) async {
      tester.view.physicalSize = surface;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(app(profile: admin));
      await tester.pumpAndSettle();

      final card = find.descendant(
        of: find.byKey(ValueKey(tomorrow)),
        matching: find.byKey(const ValueKey('cal-block-b1')),
      );
      await tester.ensureVisible(card);
      await tester.pumpAndSettle();
      final rect = tester.getRect(card);
      final labelWidth = tester
          .getRect(find.descendant(of: card, matching: find.text(b1.label)))
          .width;
      expect(rect.width, greaterThan(labelWidth));
      // Just inside the card's left edge, beside the label.
      await tester.tapAt(Offset(rect.left + 3, rect.top + 7));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('Upravit blok — jen'), findsOneWidget);
    });
  }

  testWidgets(
    'admin taps empty calendar space into a Nový blok dialog prefilled with '
    'the free gap',
    (tester) async {
      wideSurface(tester);
      // Blocks 20:00–21:00 and 22:58–23:59 leave an event-free hole between;
      // the window is 20:00–24:00.
      await tester.pumpWidget(app(blocks: const [bEarly, b1], profile: admin));
      await tester.pumpAndSettle();

      // Tap tomorrow's column at ~21:30 — inside the 21:00–22:58 gap. The
      // px/min scale is laneCount(2) * 40 / 60.
      const pxPerMinute = 2 * 40.0 / 60;
      final column = find.descendant(
        of: find.byKey(ValueKey(tomorrow)),
        matching: find.byType(CalendarColumn),
      );
      final columnTop = tester.getTopLeft(column);
      await tester.tapAt(
        columnTop + Offset(40, (21.5 - 20) * 60 * pxPerMinute),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Nový blok — jen'), findsOneWidget);
      // Prefilled with the gap's exact range.
      expect(find.text('21:00'), findsWidgets);
      expect(find.text('22:58'), findsWidgets);
    },
  );

  testWidgets('non-admin gets no edit glyph, no long-press dialog and no '
      'add-block tap', (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(app(blocks: const [bEarly, b1]));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.edit_outlined), findsNothing);
    await tester.longPress(find.byKey(const ValueKey('cal-block-b1')).first);
    await tester.pumpAndSettle();
    expect(find.textContaining('Upravit blok'), findsNothing);

    const pxPerMinute = 2 * 40.0 / 60;
    final column = find.descendant(
      of: find.byKey(ValueKey(tomorrow)),
      matching: find.byType(CalendarColumn),
    );
    final columnTop = tester.getTopLeft(column);
    await tester.tapAt(
      columnTop + Offset(40, (21.5 - 20) * 60 * pxPerMinute),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Nový blok'), findsNothing);
  });

  testWidgets(
    'day view: selecting the last day and swiping past the week boundary '
    'shifts the week with no exceptions',
    (tester) async {
      portraitSurface(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.byType(DayChipStrip), findsOneWidget);

      // The header's "20.4.–3.5." range label is the same Text shown above
      // both views (see WeekScreen.build's `header`) — capturing it before
      // and after the swipe is a week-offset-agnostic way to assert the
      // week actually shifted, without this test re-deriving the pinned
      // Monday itself.
      String rangeLabelText() => tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .whereType<String>()
          .firstWhere((s) => s.contains('–'));
      final before = rangeLabelText();

      // Select the last day (Sunday, chip index 6) — one InkWell per chip,
      // in Monday..Sunday order, under DayChipStrip.
      final chips = find.descendant(
        of: find.byType(DayChipStrip),
        matching: find.byType(InkWell),
      );
      expect(chips, findsNWidgets(7));
      await tester.tap(chips.at(6));
      await tester.pumpAndSettle();

      // A single fling on the PageView lands on exactly the next page
      // regardless of velocity (PageScrollPhysics always snaps to the
      // nearest page in the fling's direction) — from Sunday (the last real
      // page) that's the sentinel-after page, which is the boundary swipe
      // this fix targets (day_pager_view.dart's _onPageChanged sentinelAfter
      // branch → onShiftWeek → the shell's setState → didUpdateWidget's
      // programmatic resync of the PageController). Before the fix, that
      // resync's synchronous jumpToPage during didUpdateWidget (itself
      // called mid-build) threw "setState() or markNeedsBuild() called
      // during build" in debug — pumpAndSettle would surface it as a thrown
      // FlutterError, failing this test.
      await tester.fling(find.byType(PageView), const Offset(-400, 0), 800);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(rangeLabelText(), isNot(equals(before)));
    },
  );

  testWidgets(
    'day view: swiping the day chips turns the week and keeps the weekday',
    (tester) async {
      portraitSurface(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      String rangeLabelText() => tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .whereType<String>()
          .firstWhere((s) => s.contains('–'));
      final before = rangeLabelText();
      final chip = find.descendant(
        of: find.byType(DayChipStrip),
        matching: find.byType(InkWell),
      );

      await tester.fling(find.byType(DayChipStrip), const Offset(-200, 0), 800);
      await tester.pumpAndSettle();
      final next = rangeLabelText();
      expect(next, isNot(equals(before)));
      // A tap on a chip is still a tap, not a swipe.
      await tester.tap(chip.at(2));
      await tester.pumpAndSettle();
      expect(rangeLabelText(), next);

      await tester.fling(find.byType(DayChipStrip), const Offset(200, 0), 800);
      await tester.pumpAndSettle();
      expect(rangeLabelText(), before);
      expect(tester.takeException(), isNull);
    },
  );

  group('a „uvolnilo se místo“ push', () {
    // Next week's Thursday: another week than the one the screen opens on.
    final target = t.addDays(8);

    CalendarFocusNotifier focusOf(WidgetTester tester) => ProviderScope
        .containerOf(tester.element(find.byType(WeekScreen)))
        .read(calendarFocusProvider.notifier);

    CalendarFocus? focusState(WidgetTester tester) => ProviderScope
        .containerOf(tester.element(find.byType(WeekScreen)))
        .read(calendarFocusProvider);

    Finder cellOf(int lane) => find.byWidgetPredicate(
      (w) =>
          w is CellHighlight &&
          w.date == target &&
          w.blockId == 'b1' &&
          w.lane == lane,
    );

    Finder outline(int lane) => find.descendant(
      of: cellOf(lane),
      matching: find.byWidgetPredicate(
        (w) => w is DecoratedBox && w.position == DecorationPosition.foreground,
      ),
    );

    testWidgets('opens that day and outlines the cell while it is free', (
      tester,
    ) async {
      portraitSurface(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      focusOf(tester).request(
        CalendarFocus(date: target, blockId: 'b1', lane: 1),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 400));
      // The day is on screen at once…
      expect(cellOf(1), findsOneWidget);
      expect(outline(1), findsNothing);
      // …and the answer comes a moment later, from the data as it is then.
      await tester.pump(const Duration(milliseconds: 1300));
      await tester.pump();
      expect(outline(1), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);

      // The outline goes away by itself.
      await tester.pump(const Duration(seconds: 9));
      await tester.pump();
      expect(outline(1), findsNothing);
      expect(focusState(tester), isNull);
    });

    testWidgets('a spot taken again is said so, with what is left', (
      tester,
    ) async {
      portraitSurface(tester);
      await tester.pumpWidget(app(reservations: [res('r1', 'p2', target)]));
      await tester.pumpAndSettle();

      // Lane 2 of b1 is the reservation `res` makes.
      focusOf(tester).request(
        CalendarFocus(date: target, blockId: 'b1', lane: 2),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1300));
      await tester.pump();

      expect(find.textContaining('Místo už je zase obsazené'), findsOneWidget);
      expect(find.textContaining('zbývá ještě 1 volné místo'), findsOneWidget);
      expect(outline(2), findsNothing);
      expect(focusState(tester), isNull);
      await tester.pumpAndSettle();
    });

    testWidgets('a kiosk booking is outlined while it is still booked', (
      tester,
    ) async {
      portraitSurface(tester);
      await tester.pumpWidget(app(reservations: [res('r1', 'me', target)]));
      await tester.pumpAndSettle();

      focusOf(tester).request(
        CalendarFocus(
          date: target,
          blockId: 'b1',
          lane: 2,
          reservationId: 'r1',
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1300));
      await tester.pump();
      expect(outline(2), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      await tester.pump(const Duration(seconds: 9));
      await tester.pump();
      expect(outline(2), findsNothing);
      expect(focusState(tester), isNull);
    });

    testWidgets('a cancelled kiosk booking is said so', (tester) async {
      portraitSurface(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      focusOf(tester).request(
        CalendarFocus(
          date: target,
          blockId: 'b1',
          lane: 2,
          reservationId: 'r1',
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1300));
      await tester.pump();
      expect(find.text('Tahle rezervace už je zrušená.'), findsOneWidget);
      expect(outline(2), findsNothing);
      expect(focusState(tester), isNull);
      await tester.pumpAndSettle();
    });

    testWidgets('a push that names only the day just opens it', (
      tester,
    ) async {
      portraitSurface(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      focusOf(tester).request(CalendarFocus(date: target));
      await tester.pump();
      await tester.pump();
      expect(cellOf(1), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1300));
      await tester.pump();
      expect(find.byType(SnackBar), findsNothing);
      expect(outline(1), findsNothing);
      expect(focusState(tester), isNull);
    });
  });

  testWidgets('cells stay inert while weekReservationsProvider never emits', (
    tester,
  ) async {
    // Everything else has data, but this week's reservation stream is stuck
    // loading forever — no cell may be bookable while that's true.
    wideSurface(tester);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith((ref) => Stream.value(settings)),
          timeBlocksProvider.overrideWith((ref) => Stream.value(const [b1])),
          dayOverridesProvider.overrideWith((ref) => Stream.value(const [])),
          prioritySlotsProvider.overrideWithValue(const []),
          rentalsProvider.overrideWith((ref) => Stream.value(const [])),
          weekReservationsProvider.overrideWith(
            (ref, monday) => StreamController<List<Reservation>>().stream,
          ),
          myActiveReservationsProvider.overrideWith(
            (ref) => Stream.value(const []),
          ),
          myProfileProvider.overrideWith((ref) => Stream.value(me)),
          playersProvider.overrideWith(
            (ref) async => const [
              PlayerName(id: 'me', displayName: 'Já Hráč'),
            ],
          ),
          myGroupProvider.overrideWithValue(MyGroup.none),
        ],
        child: const MaterialApp(home: Scaffold(body: WeekScreen())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.add), findsNothing);
  });

  testWidgets('a lane-scoped slot keeps the block and labels its lane rows '
      'with the TYPE name and colour, not "Zápas"', (tester) async {
    wideSurface(tester);
    const laneType = PrioritySlotType(
      id: 't-lane',
      name: 'Údržba',
      colorIndex: 3,
      lanes: [1],
    );
    await tester.pumpWidget(
      app(
        matches: [
          PrioritySlot(
            type: laneType,
            id: 's1',
            date: tomorrow,
            startsAt: const HourMinute(22, 58),
            endsAt: const HourMinute(23, 59),
            prepMinutes: 0,
            description: '',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // Block survives on tomorrow (lane-scoped never cancels)…
    final cardInTomorrow = find.descendant(
      of: find.byKey(ValueKey(tomorrow)),
      matching: find.byKey(const ValueKey('cal-block-b1')),
    );
    expect(cardInTomorrow, findsOneWidget);
    // …and the blocked lane row carries the type's name: once in the day
    // header strip, once in the lane cell — never the generic 'Zápas'.
    // Once in the day header strip (with times), once in the lane cell.
    expect(find.textContaining('⛔ Údržba'), findsNWidgets(2));
    expect(find.text('Zápas'), findsNothing);
  });

  testWidgets(
      'tap in space freed by a cancelled block prefills the gap ending at '
      'the úklid band; a tap inside the band is a no-op; the day-scoped '
      'save proceeds without the weekly-overlap warning', (tester) async {
    wideSurface(tester);
    // bEarly 20:00–21:00 + b1 22:58–23:59; match tomorrow 21:00–22:00 with
    // its úklid child 20:30–21:00: both cancel bEarly on tomorrow only —
    // 20:00–20:30 is freed, 20:30–21:00 is the úklid band.
    await tester.pumpWidget(app(
      blocks: const [bEarly, b1],
      profile: admin,
      matches: [
        PrioritySlot(
          type: PrioritySlot.fallbackMatchType,
          id: 'm1',
          date: tomorrow,
          startsAt: const HourMinute(21, 0),
          endsAt: const HourMinute(22, 0),
          homeTeam: '',
          awayTeam: 'KK Slavoj',
          description: '',
        ),
        PrioritySlot(
          type: uklidType,
          id: 'u1',
          date: tomorrow,
          startsAt: const HourMinute(20, 30),
          endsAt: const HourMinute(21, 0),
          parentId: 'm1',
          description: '',
        ),
      ],
    ));
    await tester.pumpAndSettle();

    const pxPerMinute = 2 * 40.0 / 60;
    final column = find.descendant(
      of: find.byKey(ValueKey(tomorrow)),
      matching: find.byType(CalendarColumn),
    );
    final columnTop = tester.getTopLeft(column);

    // Tap inside the úklid band (20:45) — a click on a blocking band EDITS
    // it; the auto-managed úklid opens its parent match.
    await tester.tapAt(
      columnTop + Offset(40, (20.75 - 20) * 60 * pxPerMinute),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Upravit zápas'), findsOneWidget);
    await tester.tap(find.text('Zrušit'));
    await tester.pumpAndSettle();

    // Tap the freed 20:00–20:30 stripe (20:15) — prefilled gap dialog.
    await tester.tapAt(
      columnTop + Offset(40, (20.25 - 20) * 60 * pxPerMinute),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Nový blok — jen'), findsOneWidget);
    expect(find.text('20:00'), findsWidgets);
    expect(find.text('20:30'), findsWidgets);

    // bEarly is cancelled on this day (not rendered, no live rows in this
    // harness), so the save proceeds with no overlap warning; the backend
    // is absent here, so the dialog stays open with an error snack — the
    // request composition is pinned by block_dialog_day_test.dart.
    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();
    expect(find.text('Pozor — překryv bloků'), findsNothing);
  });

  testWidgets('day pager: a match day with every block cancelled shows the '
      'match and úklid banners at their real times and no lane grid', (
    tester,
  ) async {
    portraitSurface(tester);
    await tester.pumpWidget(app(
      matches: [
        PrioritySlot(
          type: PrioritySlot.fallbackMatchType,
          id: 'm1',
          date: tomorrow,
          startsAt: const HourMinute(23, 30),
          endsAt: const HourMinute(23, 59),
          homeTeam: '',
          awayTeam: 'KK Slavoj',
          description: '',
        ),
        PrioritySlot(
          type: uklidType,
          id: 'u1',
          date: tomorrow,
          startsAt: const HourMinute(22, 58),
          endsAt: const HourMinute(23, 30),
          parentId: 'm1',
          description: '',
        ),
      ],
    ));
    await tester.pumpAndSettle();
    expect(find.byType(DayChipStrip), findsOneWidget);

    // Navigate to tomorrow (same pattern as the day-view booking test).
    final chips = find.descendant(
      of: find.byType(DayChipStrip),
      matching: find.byType(InkWell),
    );
    await tester.tap(chips.at(t.weekday));
    await tester.pumpAndSettle();

    expect(find.textContaining('· 23:30–23:59'), findsWidgets);
    // Once in the day-header strip, once as the gap banner.
    expect(
      find.textContaining('⛔ Úklid před zápasem · 22:58–23:30'),
      findsWidgets,
    );
    expect(find.textContaining('Zavřeno'), findsNothing);
    expect(find.text('0 volných'), findsOneWidget);
    expect(find.text('Dráha 1'), findsNothing);
    expect(find.byIcon(Icons.add), findsNothing);
  });

  testWidgets('past days refuse calendar edits — long-press shows a snack, '
      'no dialog (history must not be rewritten)', (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(app(profile: admin));
    await tester.pumpAndSettle();

    // Go one week back: every visible day is strictly before today.
    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(
      of: find.byKey(const ValueKey('cal-block-b1')).first,
      matching: find.text(b1.label),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Minulé dny nelze upravovat.'), findsOneWidget);
    expect(find.textContaining('Upravit blok'), findsNothing);
  });

  testWidgets('tapping a closed day asks before REOPENING it; declining '
      'opens nothing', (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(app(
      profile: admin,
      overrides: [
        DayOverride(date: tomorrow, closed: true, reason: 'dovolená'),
      ],
    ));
    await tester.pumpAndSettle();

    const pxPerMinute = 2 * 40.0 / 60;
    final column = find.descendant(
      of: find.byKey(ValueKey(tomorrow)),
      matching: find.byType(CalendarColumn),
    );
    // The closed column is empty everywhere — tap mid-window.
    await tester.tapAt(
      tester.getTopLeft(column) + Offset(40, 30 * pxPerMinute),
    );
    await tester.pumpAndSettle();

    expect(find.text('Den je zavřený'), findsOneWidget);
    expect(find.textContaining('dovolená'), findsWidgets);
    await tester.tap(find.text('Zrušit'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Nový blok'), findsNothing);
  });

  testWidgets('admin tap on the day header opens the add dialog for that day '
      'without prefilled times; non-admin header is inert', (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(app(profile: admin));
    await tester.pumpAndSettle();

    final headerInTomorrow = headerOf(tomorrow);
    expect(headerInTomorrow, findsOneWidget);
    await tester.tap(headerInTomorrow);
    await tester.pumpAndSettle();

    expect(find.textContaining('Nový blok — jen'), findsOneWidget);
    expect(find.text('--:--'), findsNWidgets(2)); // times picked in dialog
  });

  testWidgets('non-admin day header is inert — no add dialog', (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await tester.tap(headerOf(tomorrow));
    await tester.pumpAndSettle();
    expect(find.textContaining('Nový blok'), findsNothing);
  });

  testWidgets('an away match shows "(venku)" in the day header only: no band, '
      'no cancelled block, lanes stay bookable', (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(
      app(
        matches: [
          PrioritySlot(
            type: PrioritySlot.fallbackMatchType,
            id: 'm-away',
            date: tomorrow,
            startsAt: const HourMinute(22, 58),
            endsAt: const HourMinute(23, 59),
            homeTeam: '',
            awayTeam: 'KK Slavoj',
            isAway: true,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // Header line (times, NO house icon — that's the away marker) — and
    // NOTHING else: the block card survives with all lanes free instead of
    // a match band.
    final headerLine = find.descendant(
      of: headerOf(tomorrow),
      matching: find.textContaining('KK Slavoj'),
    );
    expect(headerLine, findsOneWidget);
    final lineText = tester.widget<Text>(headerLine).data!;
    expect(lineText, 'KK Slavoj · 22:58–23:59');
    final cardInTomorrow = find.descendant(
      of: find.byKey(ValueKey(tomorrow)),
      matching: find.byKey(const ValueKey('cal-block-b1')),
    );
    expect(cardInTomorrow, findsOneWidget);
  });

  testWidgets('three matches on one day all fit the header — the header '
      'grows instead of clipping', (tester) async {
    wideSurface(tester);
    PrioritySlot awayAt(String id, String team, int hour) => PrioritySlot(
          type: PrioritySlot.fallbackMatchType,
          id: id,
          date: tomorrow,
          startsAt: HourMinute(hour, 0),
          endsAt: HourMinute(hour + 2, 0),
          homeTeam: '',
          awayTeam: team,
          isAway: true,
        );
    await tester.pumpWidget(
      app(
        matches: [
          awayAt('m-a', 'KK Slavoj', 8),
          awayAt('m-b', 'TJ Sokol', 11),
          awayAt('m-c', 'KK Vracov', 14),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final header = headerOf(tomorrow);
    for (final team in ['KK Slavoj', 'TJ Sokol', 'KK Vracov']) {
      expect(
        find.descendant(of: header, matching: find.textContaining(team)),
        findsOneWidget,
      );
    }
    // The busiest day dictates a taller header for EVERY column: base 56 +
    // one extra 13px line.
    expect(tester.getSize(header).height, 56.0 + 13.0);
  });

  testWidgets('the day header lists the match but never its úklid child',
      (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(
      app(
        matches: [
          PrioritySlot(
            type: PrioritySlot.fallbackMatchType,
            id: 'm-hdr',
            date: tomorrow,
            startsAt: const HourMinute(23, 30),
            endsAt: const HourMinute(23, 59),
            homeTeam: '',
            awayTeam: 'KK Slavoj',
          ),
          PrioritySlot(
            type: uklidType,
            id: 'u-hdr',
            date: tomorrow,
            startsAt: const HourMinute(22, 58),
            endsAt: const HourMinute(23, 30),
            parentId: 'm-hdr',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final header = headerOf(tomorrow);
    expect(
      find.descendant(of: header, matching: find.textContaining('KK Slavoj')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: header, matching: find.textContaining('Úklid')),
      findsNothing,
    );
    // The úklid still renders as its true-time band in the column below.
    expect(
      find.text('⛔ Úklid před zápasem\n22:58–23:30'),
      findsOneWidget,
    );
  });

  testWidgets('HOLD-drag moves a block onto empty space (handler fires); a '
      'drop onto occupied space is refused', (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(app(blocks: const [bEarly, b1], profile: admin));
    await tester.pumpAndSettle();

    const pxPerMinute = 2 * 40.0 / 60;
    final card = find
        .descendant(
          of: find.byKey(ValueKey(tomorrow)),
          matching: find.byKey(const ValueKey('cal-block-bEarly')),
        )
        .first;

    Future<void> holdDragBy(Offset delta) async {
      final gesture = await tester.startGesture(tester.getCenter(card));
      await tester.pump(const Duration(milliseconds: 300)); // > delay
      await gesture.moveBy(delta);
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
    }

    // Drop overlapping b1 (feedback top lands at 22:58): refused.
    await holdDragBy(Offset(0, (22.97 - 20.5) * 60 * pxPerMinute));
    expect(find.text('Tady není volné místo.'), findsOneWidget);
    // Let the refusal snack expire before the next drop's assertions.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    // Drop onto empty 21:30: accepted — the move handler fires (and dies
    // on the missing backend in this harness, which surfaces as an error
    // snack — proof the commit path ran).
    await holdDragBy(Offset(0, (21.5 + 0.5 - 20.5) * 60 * pxPerMinute));
    expect(find.text('Tady není volné místo.'), findsNothing);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  // Regression: match links (video + tap-through) must not depend on
  // booking readiness (db time blocks configured, reservations loaded) —
  // only on being signed in. Before the fix, a kuželna with no db blocks
  // yet fell back to the placeholder grid (`blocksFromDb == false`), which
  // also zeroed the dialog's own `interactive` and silently dropped the
  // video button and tap-through for a signed-in player.
  testWidgets('signed-in day pager with NO db time blocks still opens the '
      'match dialog with the video control and tap-through', (tester) async {
    portraitSurface(tester);
    final withVideo = PrioritySlot(
      type: PrioritySlot.fallbackMatchType,
      id: 'm-video',
      date: tomorrow,
      startsAt: const HourMinute(17, 0),
      endsAt: const HourMinute(19, 0),
      homeTeam: 'Domácí Tým',
      awayTeam: 'KK Hosté',
      importKey: 'cka:m-video',
      videoUrl: 'https://vysledky.kuzelky.cz/video/m-video',
    );
    await tester.pumpWidget(app(blocks: const [], matches: [withVideo]));
    await tester.pumpAndSettle();
    expect(find.byType(DayChipStrip), findsOneWidget);

    final chips = find.descendant(
      of: find.byType(DayChipStrip),
      matching: find.byType(InkWell),
    );
    await tester.tap(chips.at(t.weekday));
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('KK Hosté').first);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);

    await tester.tap(find.text('Domácí Tým – KK Hosté'));
    await tester.pumpAndSettle();

    expect(find.byType(MatchDetailScreen), findsOneWidget);
  });

  testWidgets(
      'the same fix applies to the landscape calendar header (signed-in, '
      'NO db time blocks): video control and tap-through both present',
      (tester) async {
    wideSurface(tester);
    final withVideo = PrioritySlot(
      type: PrioritySlot.fallbackMatchType,
      id: 'm-video-cal',
      date: tomorrow,
      startsAt: const HourMinute(17, 0),
      endsAt: const HourMinute(19, 0),
      homeTeam: 'Domácí Tým',
      awayTeam: 'KK Hosté',
      importKey: 'cka:m-video-cal',
      videoUrl: 'https://vysledky.kuzelky.cz/video/m-video-cal',
    );
    await tester.pumpWidget(app(blocks: const [], matches: [withVideo]));
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: headerOf(tomorrow),
        matching: find.textContaining('KK Hosté'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);

    await tester.tap(find.text('Domácí Tým – KK Hosté'));
    await tester.pumpAndSettle();

    expect(find.byType(MatchDetailScreen), findsOneWidget);
  });

  group('the canteen duty line under the week range (0050)', () {
    final week = DutyPeriod(
      id: 'd1',
      startsOn: Day(2026, 9, 7),
      endsOn: Day(2026, 9, 13),
    );

    testWidgets('names who serves this week and opens Klubovna → Služby', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          dutyPeriods: [week],
          dutyAssignments: const [DutyAssignment(periodId: 'd1', userId: 'p2')],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Služba: Petr Novák'), findsOneWidget);
      await tester.tap(find.text('Služba: Petr Novák'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(AppBar, 'Služby'), findsOneWidget);
    });

    testWidgets('my duty today: „Sloužíš ty“; no period: no line', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          dutyPeriods: [week],
          dutyAssignments: const [DutyAssignment(periodId: 'd1', userId: 'me')],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Sloužíš ty · do ne 13. 9.'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.textContaining('Služba'), findsNothing);
    });
  });

  group('the calendar while on canteen duty (0050)', () {
    final week = DutyPeriod(
      id: 'd1',
      startsOn: Day(2026, 9, 7),
      endsOn: Day(2026, 9, 13),
    );
    const onMe = [DutyAssignment(periodId: 'd1', userId: 'me')];
    const onPetr = [DutyAssignment(periodId: 'd1', userId: 'p2')];

    CalendarAdminHooks hooks(WidgetTester tester) =>
        tester.widget<WeekCalendarView>(find.byType(WeekCalendarView)).admin;
    SlotCallbacks slots(WidgetTester tester) =>
        tester.widget<WeekCalendarView>(find.byType(WeekCalendarView)).slot;

    testWidgets('on duty: the day-block hooks, none for matches, blockages '
        'or rentals', (tester) async {
      wideSurface(tester);
      await tester.pumpWidget(
        app(dutyPeriods: [week], dutyAssignments: onMe),
      );
      await tester.pumpAndSettle();

      final admin = hooks(tester);
      expect(admin.onEditBlock, isNotNull);
      expect(admin.onAddBlockInGap, isNotNull);
      expect(admin.onAddForDay, isNotNull);
      expect(admin.onMoveBlock, isNotNull);
      expect(admin.onCloseDay, isNotNull);
      expect(admin.onRestoreDay, isNotNull);
      expect(admin.onEditPrioritySlot, isNull);
      expect(admin.onMovePrioritySlot, isNull);
      expect(admin.onEditRental, isNull);
      expect(slots(tester).onRental, isNull);
      expect(slots(tester).onDuty, isTrue);
    });

    testWidgets('off duty (someone else serves): none of it', (tester) async {
      wideSurface(tester);
      await tester.pumpWidget(
        app(dutyPeriods: [week], dutyAssignments: onPetr),
      );
      await tester.pumpAndSettle();

      final admin = hooks(tester);
      expect(admin.onEditBlock, isNull);
      expect(admin.onAddBlockInGap, isNull);
      expect(admin.onAddForDay, isNull);
      expect(admin.onMoveBlock, isNull);
      expect(admin.onCloseDay, isNull);
      expect(admin.onRestoreDay, isNull);
      expect(admin.onEditPrioritySlot, isNull);
      expect(admin.onMovePrioritySlot, isNull);
      expect(admin.onEditRental, isNull);
      expect(slots(tester).onRental, isNull);
      expect(slots(tester).onDuty, isFalse);

      // A free cell asks the plain question — no player search.
      final addInTomorrow = find.descendant(
        of: find.byKey(ValueKey(tomorrow)),
        matching: find.byIcon(Icons.add),
      );
      await tester.ensureVisible(addInTomorrow.first);
      await tester.pumpAndSettle();
      await tester.tap(addInTomorrow.first);
      await tester.pumpAndSettle();
      expect(find.text('Rezervovat termín?'), findsOneWidget);
      expect(find.textContaining('Vybráno:'), findsNothing);
    });

    testWidgets('an admin keeps every hook and is not "on duty"', (
      tester,
    ) async {
      wideSurface(tester);
      await tester.pumpWidget(
        app(profile: admin, dutyPeriods: [week], dutyAssignments: onMe),
      );
      await tester.pumpAndSettle();

      final hooksOfAdmin = hooks(tester);
      expect(hooksOfAdmin.onEditPrioritySlot, isNotNull);
      expect(hooksOfAdmin.onEditRental, isNotNull);
      expect(hooksOfAdmin.onCloseDay, isNotNull);
      expect(slots(tester).onDuty, isFalse);
    });

    testWidgets('the header ＋ opens the day dialog with „Zavřít den“', (
      tester,
    ) async {
      wideSurface(tester);
      await tester.pumpWidget(
        app(dutyPeriods: [week], dutyAssignments: onMe),
      );
      await tester.pumpAndSettle();

      await tester.tap(headerOf(tomorrow));
      await tester.pumpAndSettle();
      expect(find.textContaining('Nový blok — jen'), findsOneWidget);
      expect(find.text('Zavřít den'), findsOneWidget);
    });

    testWidgets('the admin gets „Zavřít den“ too: header ＋ and portrait ⋮', (
      tester,
    ) async {
      wideSurface(tester);
      await tester.pumpWidget(
        app(profile: admin, dutyPeriods: [week], dutyAssignments: onPetr),
      );
      await tester.pumpAndSettle();
      await tester.tap(headerOf(tomorrow));
      await tester.pumpAndSettle();
      expect(find.textContaining('Nový blok — jen'), findsOneWidget);
      expect(find.text('Zavřít den'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      portraitSurface(tester);
      await tester.pumpWidget(
        app(profile: admin, dutyPeriods: [week], dutyAssignments: onPetr),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .descendant(
              of: find.byType(DayChipStrip),
              matching: find.byType(InkWell),
            )
            .at(t.weekday), // tomorrow
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('Zavřít den…'), findsOneWidget);
    });

    testWidgets('no „Zavřít den“ from a gap tap, nor on a closed day reopened '
        'through „Otevřít den“', (tester) async {
      wideSurface(tester);
      // bEarly 20:00–21:00 and b1 22:58–23:59 leave the 21:00–22:58 gap.
      await tester.pumpWidget(
        app(
          blocks: const [bEarly, b1],
          dutyPeriods: [week],
          dutyAssignments: onMe,
        ),
      );
      await tester.pumpAndSettle();
      // Tomorrow's column at ~21:30; px/min is laneCount(2) * 40 / 60.
      const pxPerMinute = 2 * 40.0 / 60;
      final columnTop = tester.getTopLeft(
        find.descendant(
          of: find.byKey(ValueKey(tomorrow)),
          matching: find.byType(CalendarColumn),
        ),
      );
      await tester.tapAt(
        columnTop + Offset(40, (21.5 - 20) * 60 * pxPerMinute),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Nový blok — jen'), findsOneWidget);
      expect(find.text('22:58'), findsWidgets);
      expect(find.text('Zavřít den'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        app(
          dutyPeriods: [week],
          dutyAssignments: onMe,
          overrides: [
            DayOverride(date: tomorrow, closed: true, reason: 'Malování'),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(headerOf(tomorrow));
      await tester.pumpAndSettle();
      expect(find.text('Den je zavřený'), findsOneWidget);
      await tester.tap(find.text('Otevřít den'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Nový blok — jen'), findsOneWidget);
      expect(find.text('Zavřít den'), findsNothing);
    });

    testWidgets('a free cell opens the player search; a player at the cap '
        'greys „Rezervovat“', (tester) async {
      wideSurface(tester);
      await tester.pumpWidget(
        app(
          dutyPeriods: [week],
          dutyAssignments: onMe,
          activeCounts: const {'p2': 3},
        ),
      );
      await tester.pumpAndSettle();

      final addInTomorrow = find.descendant(
        of: find.byKey(ValueKey(tomorrow)),
        matching: find.byIcon(Icons.add),
      );
      await tester.ensureVisible(addInTomorrow.first);
      await tester.pumpAndSettle();
      await tester.tap(addInTomorrow.first);
      await tester.pumpAndSettle();
      expect(find.text('Vybráno: já'), findsOneWidget);
      FilledButton book() => tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Rezervovat'),
      );
      expect(book().onPressed, isNotNull);

      await tester.tap(find.widgetWithText(ListTile, 'Petr Novák'));
      await tester.pumpAndSettle();
      expect(
        find.text('Petr Novák už má maximální počet rezervací (3).'),
        findsOneWidget,
      );
      expect(book().onPressed, isNull);
    });

    testWidgets('at my own cap the free cells keep their full ＋', (
      tester,
    ) async {
      wideSurface(tester);
      await tester.pumpWidget(
        app(
          dutyPeriods: [week],
          dutyAssignments: onMe,
          // Three of my own ahead: the cap (3) is reached.
          reservations: [
            for (var i = 1; i <= 3; i++) res('r$i', 'me', t.addDays(i)),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // Quiet is for cells only the admin exemption opens (past, beyond the
      // horizon) — tomorrow's are bookable for the others as usual.
      final free = [
        for (final t in tester.widgetList<SlotTile>(
          find.descendant(
            of: find.byKey(ValueKey(tomorrow)),
            matching: find.byType(SlotTile),
          ),
        ))
          if (t.state is FreeSlot) t,
      ];
      expect(free, isNotEmpty);
      expect(free.where((t) => t.onTap == null), isEmpty);
      expect(free.where((t) => t.quiet), isEmpty);
    });

    testWidgets('at my own cap: „Rezervovat“ only for another player; off '
        'duty the same counts leave no ＋', (tester) async {
      wideSurface(tester);
      final mine = [
        for (var i = 1; i <= 3; i++) res('m$i', 'me', tomorrow.addDays(i)),
      ];
      await tester.pumpWidget(
        app(
          dutyPeriods: [week],
          dutyAssignments: onMe,
          reservations: mine,
          activeCounts: const {'me': 3},
        ),
      );
      await tester.pumpAndSettle();

      final addInTomorrow = find.descendant(
        of: find.byKey(ValueKey(tomorrow)),
        matching: find.byIcon(Icons.add),
      );
      expect(addInTomorrow, findsWidgets);
      await tester.ensureVisible(addInTomorrow.first);
      await tester.pumpAndSettle();
      await tester.tap(addInTomorrow.first);
      await tester.pumpAndSettle();
      expect(find.text('Vybráno: já'), findsOneWidget);
      FilledButton book() => tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Rezervovat'),
      );
      expect(book().onPressed, isNull);

      await tester.tap(find.widgetWithText(ListTile, 'Petr Novák'));
      await tester.pumpAndSettle();
      expect(book().onPressed, isNotNull);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        app(
          dutyPeriods: [week],
          dutyAssignments: onPetr,
          reservations: mine,
          activeCounts: const {'me': 3},
        ),
      );
      await tester.pumpAndSettle();
      expect(addInTomorrow, findsNothing);
    });

    testWidgets("another player's future reservation opens the admin's "
        'notify-choice cancel', (tester) async {
      wideSurface(tester);
      await tester.pumpWidget(
        app(
          dutyPeriods: [week],
          dutyAssignments: onMe,
          reservations: [res('r2', 'p2', tomorrow)],
        ),
      );
      await tester.pumpAndSettle();

      final cell = find.descendant(
        of: find.byKey(ValueKey(tomorrow)),
        matching: find.text('Péťa'),
      );
      await tester.ensureVisible(cell);
      await tester.pumpAndSettle();
      await tester.tap(cell);
      await tester.pumpAndSettle();
      expect(find.text('Zrušit a poslat zprávu'), findsOneWidget);
      expect(find.text('Zrušit bez zprávy'), findsOneWidget);
    });

    testWidgets('portrait: the ⋮ day menu, „Obnovit“ only with an override; '
        'off duty no ⋮', (tester) async {
      portraitSurface(tester);
      Future<void> openTomorrow() async {
        final chips = find.descendant(
          of: find.byType(DayChipStrip),
          matching: find.byType(InkWell),
        );
        await tester.tap(chips.at(t.weekday));
        await tester.pumpAndSettle();
      }

      await tester.pumpWidget(
        app(dutyPeriods: [week], dutyAssignments: onMe),
      );
      await tester.pumpAndSettle();
      await openTomorrow();
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('Přidat blok…'), findsOneWidget);
      expect(find.text('Zavřít den…'), findsOneWidget);
      expect(find.text('Obnovit týdenní rozvrh'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        app(
          dutyPeriods: [week],
          dutyAssignments: onMe,
          overrides: [
            DayOverride(
              date: tomorrow,
              closed: false,
              reason: '',
              blockIds: const ['b1'],
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await openTomorrow();
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('Obnovit týdenní rozvrh'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        app(dutyPeriods: [week], dutyAssignments: onPetr),
      );
      await tester.pumpAndSettle();
      await openTomorrow();
      expect(find.byIcon(Icons.more_vert), findsNothing);
    });

    // Picks a day of the pinned week through the chip strip (Mon = 0) —
    // the pager's own first page follows the real clock.
    Future<void> openChip(WidgetTester tester, int index) async {
      await tester.tap(
        find
            .descendant(
              of: find.byType(DayChipStrip),
              matching: find.byType(InkWell),
            )
            .at(index),
      );
      await tester.pumpAndSettle();
    }

    Future<void> pickFromMenu(WidgetTester tester, String label) async {
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    testWidgets('portrait: each ⋮ item opens its own flow; no ⋮ on '
        'yesterday, no „Zavřít den…“ on a closed day', (tester) async {
      portraitSurface(tester);
      await tester.pumpWidget(
        app(dutyPeriods: [week], dutyAssignments: onMe),
      );
      await tester.pumpAndSettle();
      await openChip(tester, t.weekday); // tomorrow

      await pickFromMenu(tester, 'Zavřít den…');
      expect(find.text('Důvod zavření'), findsOneWidget);
      expect(find.byType(BlockDialog), findsNothing);
      await tester.tap(find.text('Zrušit'));
      await tester.pumpAndSettle();

      await pickFromMenu(tester, 'Přidat blok…');
      expect(find.textContaining('Nový blok — jen'), findsOneWidget);
      expect(find.text('Důvod zavření'), findsNothing);
      // No gap picked on an open day: the dialog offers closing it, like
      // the header ＋.
      expect(find.text('Zavřít den'), findsOneWidget);
      await tester.tap(find.text('Zrušit'));
      await tester.pumpAndSettle();

      await openChip(tester, t.weekday - 2); // yesterday
      expect(
        find.byWidgetPredicate(
          (w) => w is DayHeader && w.date == t.addDays(-1),
        ),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.more_vert), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        app(
          dutyPeriods: [week],
          dutyAssignments: onMe,
          overrides: [
            DayOverride(date: tomorrow, closed: true, reason: 'Malování'),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await openChip(tester, t.weekday);
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('Přidat blok…'), findsOneWidget);
      expect(find.text('Obnovit týdenní rozvrh'), findsOneWidget);
      expect(find.text('Zavřít den…'), findsNothing);
    });

    // Today (Wed 10:00): bMorning 9:00–11:00 is under way, bEarly (20:00)
    // is still ahead. The server holds the duty to blocks not yet started.
    const bMorning = TimeBlock(
      id: 'bMorning',
      startsAt: HourMinute(9, 0),
      endsAt: HourMinute(11, 0),
      position: 2,
      active: true,
    );

    Future<void> dismissSnack(WidgetTester tester) async {
      ScaffoldMessenger.of(tester.element(find.byType(WeekScreen)))
          .removeCurrentSnackBar();
      await tester.pumpAndSettle();
    }

    testWidgets('portrait: the next week’s preview page has no ⋮', (
      tester,
    ) async {
      portraitSurface(tester);
      await tester.pumpWidget(
        app(profile: admin, dutyPeriods: [week], dutyAssignments: onMe),
      );
      await tester.pumpAndSettle();
      // Sunday, the last real page; half a swipe on shows next Monday's
      // preview beside it without shifting the week.
      await tester.tap(
        find
            .descendant(
              of: find.byType(DayChipStrip),
              matching: find.byType(InkWell),
            )
            .at(6),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.more_vert), findsOneWidget);

      final drag = await tester.startGesture(
        tester.getCenter(find.byType(PageView)),
      );
      await drag.moveBy(const Offset(-40, 0));
      await drag.moveBy(const Offset(-360, 0));
      await tester.pump();
      expect(find.byType(DayHeader), findsNWidgets(2));
      // Sunday's own ⋮ only; the preview's would act on this week's data.
      expect(find.byIcon(Icons.more_vert), findsOneWidget);

      await drag.moveBy(const Offset(400, 0));
      await drag.up();
      await tester.pumpAndSettle();
    });

    testWidgets('today: a block under way is neither edited nor moved, and '
        'nothing moves onto a start that has passed', (tester) async {
      wideSurface(tester);
      await tester.pumpWidget(app(
        blocks: const [bMorning, bEarly, b1],
        dutyPeriods: [week],
        dutyAssignments: onMe,
      ));
      await tester.pumpAndSettle();

      hooks(tester).onEditBlock!(t, bMorning);
      await tester.pumpAndSettle();
      expect(find.text(blockStartedMessage), findsOneWidget);
      expect(find.byType(BlockDialog), findsNothing);
      await dismissSnack(tester);

      hooks(tester).onMoveBlock!(t, bMorning, const HourMinute(12, 0));
      await tester.pumpAndSettle();
      expect(find.text(blockStartedMessage), findsOneWidget);
      await dismissSnack(tester);

      hooks(tester).onMoveBlock!(t, bEarly, const HourMinute(9, 30));
      await tester.pumpAndSettle();
      expect(
        find.text('Blok nemůže začínat dřív než teď (10:00) — '
            'vyber pozdější začátek.'),
        findsOneWidget,
      );
      await dismissSnack(tester);

      // A block still ahead opens, held to starts after now.
      hooks(tester).onEditBlock!(t, bEarly);
      await tester.pumpAndSettle();
      expect(
        tester.widget<BlockDialog>(find.byType(BlockDialog)).dutyClock?.call(),
        const HourMinute(10, 0),
      );
    });

    testWidgets('no limit tomorrow, nor for the admin today', (tester) async {
      wideSurface(tester);
      await tester.pumpWidget(app(
        blocks: const [bMorning, bEarly, b1],
        dutyPeriods: [week],
        dutyAssignments: onMe,
      ));
      await tester.pumpAndSettle();
      hooks(tester).onEditBlock!(tomorrow, bMorning);
      await tester.pumpAndSettle();
      expect(
        tester.widget<BlockDialog>(find.byType(BlockDialog)).dutyClock?.call(),
        isNull,
      );

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app(
        profile: admin,
        blocks: const [bMorning, bEarly, b1],
        dutyPeriods: [week],
        dutyAssignments: onMe,
      ));
      await tester.pumpAndSettle();
      hooks(tester).onEditBlock!(t, bMorning);
      await tester.pumpAndSettle();
      expect(find.text(blockStartedMessage), findsNothing);
      expect(
        tester.widget<BlockDialog>(find.byType(BlockDialog)).dutyClock?.call(),
        isNull,
      );
    });

    testWidgets('the header ＋ on today hands the dialog the current time', (
      tester,
    ) async {
      wideSurface(tester);
      await tester.pumpWidget(app(
        blocks: const [bMorning, bEarly, b1],
        dutyPeriods: [week],
        dutyAssignments: onMe,
      ));
      await tester.pumpAndSettle();
      hooks(tester).onAddForDay!(t);
      await tester.pumpAndSettle();
      final dialog = tester.widget<BlockDialog>(find.byType(BlockDialog));
      expect(dialog.dutyClock?.call(), const HourMinute(10, 0));
      expect(dialog.offerCloseDay, isTrue);
    });
  });

  // Two rights, two clocks (0050): booking, cancelling and re-seating for
  // others is held WHILE on duty (a period covering today); the blocks of a
  // day are edited on the days of the player's OWN periods, from today on,
  // on duty today or not. The drawn week is Mon 7. 9. – Sun 13. 9., today
  // is Wednesday the 9th.
  group('block edits follow the days of my own periods (0050)', () {
    Day day(int d) => Day(2026, 9, d);
    DutyPeriod period(String id, int from, int to) =>
        DutyPeriod(id: id, startsOn: day(from), endsOn: day(to));
    const onMe = [DutyAssignment(periodId: 'd1', userId: 'me')];

    CalendarAdminHooks hooks(WidgetTester tester) =>
        tester.widget<WeekCalendarView>(find.byType(WeekCalendarView)).admin;
    SlotCallbacks slots(WidgetTester tester) =>
        tester.widget<WeekCalendarView>(find.byType(WeekCalendarView)).slot;

    // Which days of the drawn week (Monday the [from]th) the calendar lets me
    // edit: those whose header takes the ＋ tap.
    Set<int> addable(WidgetTester tester, {int from = 7}) => {
      for (var d = from; d < from + 7; d++)
        if (find
            .descendant(of: headerOf(day(d)), matching: find.byType(InkWell))
            .evaluate()
            .isNotEmpty)
          d,
    };

    Future<void> chip(WidgetTester tester, int d) async {
      await tester.tap(
        find
            .descendant(
              of: find.byType(DayChipStrip),
              matching: find.byType(InkWell),
            )
            .at(d - 7),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a duty later this week, not on duty today: its own days '
        'and no others', (tester) async {
      wideSurface(tester);
      await tester.pumpWidget(
        app(dutyPeriods: [period('d1', 10, 12)], dutyAssignments: onMe),
      );
      await tester.pumpAndSettle();

      // Thursday to Saturday; not today (not mine), not Sunday, not the past.
      expect(addable(tester), {10, 11, 12});
      expect(
        [for (var d = 7; d <= 13; d++) hooks(tester).canEditDay(day(d))],
        [false, false, false, true, true, true, false],
      );
      expect(slots(tester).onDuty, isFalse);
      // The hooks of a day outside it are gone; inside they are all there.
      expect(hooks(tester).forDay(day(13)).onEditBlock, isNull);
      expect(hooks(tester).forDay(day(9)).onCloseDay, isNull);
      expect(hooks(tester).forDay(day(11)).onEditBlock, isNotNull);
      expect(hooks(tester).forDay(day(11)).onCloseDay, isNotNull);
      expect(hooks(tester).forDay(day(11)).onEditPrioritySlot, isNull);
    });

    testWidgets('that duty books, and cancels, for nobody yet — its own '
        'days included', (tester) async {
      wideSurface(tester);
      await tester.pumpWidget(
        app(
          dutyPeriods: [period('d1', 10, 12)],
          dutyAssignments: onMe,
          reservations: [res('r2', 'p2', tomorrow)],
        ),
      );
      await tester.pumpAndSettle();

      final free = find.descendant(
        of: find.byKey(ValueKey(tomorrow)),
        matching: find.byIcon(Icons.add),
      );
      await tester.ensureVisible(free.first);
      await tester.pumpAndSettle();
      await tester.tap(free.first);
      await tester.pumpAndSettle();
      expect(find.text('Rezervovat termín?'), findsOneWidget);
      expect(find.textContaining('Vybráno:'), findsNothing);
      await tester.tap(find.text('Zrušit'));
      await tester.pumpAndSettle();

      final cell = find.descendant(
        of: find.byKey(ValueKey(tomorrow)),
        matching: find.text('Péťa'),
      );
      await tester.ensureVisible(cell);
      await tester.pumpAndSettle();
      await tester.tap(cell);
      await tester.pumpAndSettle();
      expect(find.text('Zrušit bez zprávy'), findsNothing);
      expect(find.text('Petr Novák'), findsOneWidget); // the info snack
    });

    // The columns themselves take the per-day hooks: long-press edit,
    // tap-a-gap add and drag exist on its own days only — the bundle and
    // the header ＋ alone would not show a column wired to the full set.
    testWidgets('a duty later this week: each day column gets the block '
        'gestures on its own days only', (tester) async {
      wideSurface(tester);
      await tester.pumpWidget(
        app(dutyPeriods: [period('d1', 10, 12)], dutyAssignments: onMe),
      );
      await tester.pumpAndSettle();
      final columns = tester.widgetList<ScheduleDayColumn>(
        find.byType(ScheduleDayColumn),
      );
      expect(columns, hasLength(7));
      for (final c in columns) {
        final mine = {10, 11, 12}.contains(c.day.date.day);
        final why = '${c.day.date.day}. 9.';
        expect(c.admin.onEditBlock != null, mine, reason: why);
        expect(c.admin.onAddBlockInGap != null, mine, reason: why);
        expect(c.admin.onMoveBlock != null, mine, reason: why);
      }
    });

    testWidgets('portrait: the ⋮ menu on its own days only', (tester) async {
      portraitSurface(tester);
      await tester.pumpWidget(
        app(dutyPeriods: [period('d1', 10, 12)], dutyAssignments: onMe),
      );
      await tester.pumpAndSettle();

      for (final d in [7, 8, 9, 13]) {
        await chip(tester, d);
        expect(find.byIcon(Icons.more_vert), findsNothing, reason: '$d. 9.');
      }
      for (final d in [10, 11, 12]) {
        await chip(tester, d);
        await tester.tap(find.byIcon(Icons.more_vert));
        await tester.pumpAndSettle();
        expect(find.text('Přidat blok…'), findsOneWidget, reason: '$d. 9.');
        expect(find.text('Zavřít den…'), findsOneWidget, reason: '$d. 9.');
        await tester.tapAt(const Offset(5, 5)); // dismiss the menu
        await tester.pumpAndSettle();
      }
    });

    testWidgets('on duty today: books and cancels for others on another '
        'duty\'s days, edits blocks on its own only', (tester) async {
      wideSurface(tester);
      await tester.pumpWidget(
        app(
          // Mine until today, then Petr's Thursday to Sunday.
          dutyPeriods: [period('d1', 7, 9), period('d2', 10, 13)],
          dutyAssignments: const [
            DutyAssignment(periodId: 'd1', userId: 'me'),
            DutyAssignment(periodId: 'd2', userId: 'p2'),
          ],
          reservations: [res('r2', 'p2', tomorrow)],
        ),
      );
      await tester.pumpAndSettle();

      // Today only: Monday and Tuesday are mine but past.
      expect(addable(tester), {9});
      expect(slots(tester).onDuty, isTrue);

      // Thursday is Petr's duty: a free cell still books for anyone ...
      final free = find.descendant(
        of: find.byKey(ValueKey(tomorrow)),
        matching: find.byIcon(Icons.add),
      );
      await tester.ensureVisible(free.first);
      await tester.pumpAndSettle();
      await tester.tap(free.first);
      await tester.pumpAndSettle();
      expect(find.text('Vybráno: já'), findsOneWidget);
      await tester.tap(find.text('Zrušit'));
      await tester.pumpAndSettle();

      // ... and another player's reservation there is cancelled with the
      // notify choice.
      final cell = find.descendant(
        of: find.byKey(ValueKey(tomorrow)),
        matching: find.text('Péťa'),
      );
      await tester.ensureVisible(cell);
      await tester.pumpAndSettle();
      await tester.tap(cell);
      await tester.pumpAndSettle();
      expect(find.text('Zrušit bez zprávy'), findsOneWidget);
    });

    testWidgets('two consecutive periods of mine: every day from today on',
        (tester) async {
      wideSurface(tester);
      await tester.pumpWidget(
        app(
          dutyPeriods: [period('d1', 7, 9), period('d2', 10, 13)],
          dutyAssignments: const [
            DutyAssignment(periodId: 'd1', userId: 'me'),
            DutyAssignment(periodId: 'd2', userId: 'me'),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(addable(tester), {9, 10, 11, 12, 13});
    });

    testWidgets('an admin edits every day of the week, past ones too, with '
        'or without a period', (tester) async {
      wideSurface(tester);
      await tester.pumpWidget(
        app(
          profile: admin,
          dutyPeriods: [period('d1', 10, 12)],
          dutyAssignments: const [
            DutyAssignment(periodId: 'd1', userId: 'p2'),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(addable(tester), {7, 8, 9, 10, 11, 12, 13});
      expect(hooks(tester).canEditDay(day(8)), isTrue);
      expect(hooks(tester).forDay(day(8)).onEditPrioritySlot, isNotNull);
    });

    testWidgets('a duty of mine far ahead: no day of this week is mine',
        (tester) async {
      wideSurface(tester);
      await tester.pumpWidget(
        app(
          dutyPeriods: [
            DutyPeriod(
              id: 'd1',
              startsOn: Day(2026, 10, 12),
              endsOn: Day(2026, 10, 14),
            ),
          ],
          dutyAssignments: onMe,
        ),
      );
      await tester.pumpAndSettle();

      expect(addable(tester), isEmpty);
      expect(slots(tester).onDuty, isFalse);
    });

    testWidgets('a duty next week Monday to Wednesday: those three days are '
        'editable already today, nothing else', (tester) async {
      wideSurface(tester);
      await tester.pumpWidget(
        app(dutyPeriods: [period('d1', 14, 16)], dutyAssignments: onMe),
      );
      await tester.pumpAndSettle();
      // This week nothing is mine, and nothing is booked for others.
      expect(addable(tester), isEmpty);
      expect(slots(tester).onDuty, isFalse);

      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();
      expect(addable(tester, from: 14), {14, 15, 16});
      expect(slots(tester).onDuty, isFalse);
    });

    // Writing to the players of a day or a block (0051) goes with the right
    // to change that day's blocks: the same days, on duty today or not.
    testWidgets('a duty later this week: the message hooks come with the '
        'block gestures, day by day', (tester) async {
      wideSurface(tester);
      await tester.pumpWidget(
        app(dutyPeriods: [period('d1', 10, 12)], dutyAssignments: onMe),
      );
      await tester.pumpAndSettle();
      for (final d in [10, 11, 12]) {
        expect(hooks(tester).forDay(day(d)).onMessageDay, isNotNull, reason: '$d');
        expect(hooks(tester).forDay(day(d)).onMessageBlock, isNotNull, reason: '$d');
      }
      for (final d in [7, 8, 9, 13]) {
        expect(hooks(tester).forDay(day(d)).onMessageDay, isNull, reason: '$d');
        expect(hooks(tester).forDay(day(d)).onMessageBlock, isNull, reason: '$d');
      }
    });

    testWidgets('portrait: its own day\'s ⋮ offers „Napsat hráčům dne…“ next '
        'to „Přidat blok…“, though it is not on duty today', (tester) async {
      portraitSurface(tester);
      await tester.pumpWidget(
        app(dutyPeriods: [period('d1', 10, 12)], dutyAssignments: onMe),
      );
      await tester.pumpAndSettle();
      await chip(tester, 11);
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('Přidat blok…'), findsOneWidget);
      expect(find.text('Napsat hráčům dne…'), findsOneWidget);
    });

    testWidgets('on duty today: the message hooks, like the block gestures, '
        'only on the days of its own period', (tester) async {
      wideSurface(tester);
      await tester.pumpWidget(
        app(
          dutyPeriods: [period('d1', 7, 9), period('d2', 10, 13)],
          dutyAssignments: const [
            DutyAssignment(periodId: 'd1', userId: 'me'),
            DutyAssignment(periodId: 'd2', userId: 'p2'),
          ],
        ),
      );
      await tester.pumpAndSettle();
      // Today is mine; Petr's Friday is not.
      expect(hooks(tester).forDay(day(9)).onMessageDay, isNotNull);
      expect(hooks(tester).forDay(day(9)).onMessageBlock, isNotNull);
      expect(hooks(tester).forDay(day(11)).onMessageDay, isNull);
      expect(hooks(tester).forDay(day(11)).onMessageBlock, isNull);
      expect(hooks(tester).forDay(day(11)).onAddForDay, isNull);
    });

    testWidgets('portrait: another duty\'s day has no ⋮ at all, not even '
        '„Napsat hráčům dne…“', (tester) async {
      portraitSurface(tester);
      await tester.pumpWidget(
        app(
          dutyPeriods: [period('d1', 7, 9), period('d2', 10, 13)],
          dutyAssignments: const [
            DutyAssignment(periodId: 'd1', userId: 'me'),
            DutyAssignment(periodId: 'd2', userId: 'p2'),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await chip(tester, 11);
      expect(find.byIcon(Icons.more_vert), findsNothing);
      await chip(tester, 9);
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      expect(find.text('Napsat hráčům dne…'), findsOneWidget);
    });

    testWidgets('an admin keeps the message hooks on every day, past ones too',
        (tester) async {
      wideSurface(tester);
      await tester.pumpWidget(
        app(
          profile: admin,
          dutyPeriods: [period('d1', 10, 12)],
          dutyAssignments: const [DutyAssignment(periodId: 'd1', userId: 'p2')],
        ),
      );
      await tester.pumpAndSettle();
      for (var d = 7; d <= 13; d++) {
        expect(hooks(tester).forDay(day(d)).onMessageDay, isNotNull, reason: '$d');
      }
    });
  });
}

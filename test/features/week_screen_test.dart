import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/ui.dart' show dayFull;
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/schedule/widgets/slot_tile.dart';
import 'package:rezervator/features/schedule/week_calendar_view.dart';
import 'package:rezervator/features/schedule/week_screen.dart';
import 'package:rezervator/features/schedule/widgets/calendar_board.dart';
import 'package:rezervator/features/schedule/widgets/day_chip_strip.dart';
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
  }) {
    return ProviderScope(
      overrides: [
        // What Api.activeReservationCount would answer: the cap counts every
        // future date, which the drawn week alone cannot know.
        activeReservationCountProvider
            .overrideWith((ref, playerId) async => activeCounts[playerId] ?? 0),
        settingsProvider.overrideWith((ref) => Stream.value(settings)),
        timeBlocksProvider.overrideWith((ref) => Stream.value(blocks)),
        dayOverridesProvider.overrideWith((ref) => Stream.value(overrides)),
        prioritySlotsProvider.overrideWithValue(matches),
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
      'the notify choice', (
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
    expect(find.text('Zrušit a poslat zprávu'), findsOneWidget);
    expect(find.text('Zrušit bez zprávy'), findsOneWidget);
  });

  testWidgets("admin cancel of a hráč bez účtu's reservation asks plainly — "
      'nobody to message', (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(app(
      profile: admin,
      roster: const [
        ...players,
        PlayerName(id: 'p3', displayName: 'Bohumil Kroupa', hasAccount: false),
      ],
      reservations: [res('r3', 'p3', tomorrow)],
    ));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Bohumil Kroupa').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bohumil Kroupa').first);
    await tester.pumpAndSettle();

    expect(find.text('Zrušit rezervaci?'), findsOneWidget);
    expect(find.textContaining('Hráč bez účtu se o zrušení nedozví.'),
        findsOneWidget);
    expect(find.text('Zrušit a poslat zprávu'), findsNothing);
    expect(find.text('Zrušit bez zprávy'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Zpět'), findsOneWidget);
    expect(find.text('Zrušit rezervaci'), findsOneWidget);
  });

  testWidgets('non-admin tap on foreign reservation stays inert', (
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
    expect(find.text('Výjimka pronájmu'), findsNothing);
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
}

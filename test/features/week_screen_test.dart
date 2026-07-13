import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/ui.dart' show today;
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
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

  // Make the surface WIDE (1600×1200): the calendar's day columns clamp to
  // 220px, so 7 columns + the hour ruler (1586px) all build without
  // horizontal scrolling — a test asserting on e.g. Sunday's column would
  // otherwise flake depending on which weekday the suite runs.
  void wideSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

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

  final t = today();
  final tomorrow = t.addDays(1);

  const me = Profile(
    id: 'me',
    displayName: 'Já Hráč',
    club: '',
    email: 'me@example.com',
    role: Role.player,
    status: ProfileStatus.approved,
  );

  const admin = Profile(
    id: 'me',
    displayName: 'Já Hráč',
    club: '',
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

  Widget app({
    List<DayOverride> overrides = const [],
    List<PrioritySlot> matches = const [],
    List<Reservation> reservations = const [],
    List<TimeBlock> blocks = const [b1],
    List<Rental> rentals = const [],
    Profile profile = me,
  }) {
    return ProviderScope(
      overrides: [
        settingsProvider.overrideWith((ref) => Stream.value(settings)),
        timeBlocksProvider.overrideWith((ref) => Stream.value(blocks)),
        dayOverridesProvider.overrideWith((ref) => Stream.value(overrides)),
        prioritySlotsProvider.overrideWithValue(matches),
        rentalsProvider.overrideWith((ref) => Stream.value(rentals)),
        weekReservationsProvider.overrideWith(
          (ref, monday) => Stream.value(reservations),
        ),
        myActiveReservationsProvider.overrideWith(
          (ref) => Stream.value(reservations),
        ),
        myProfileProvider.overrideWith((ref) => Stream.value(profile)),
        playersProvider.overrideWith(
          (ref) async => const [
            PlayerName(id: 'me', displayName: 'Já Hráč', club: ''),
            PlayerName(
              id: 'p2',
              displayName: 'Petr Novák',
              club: '',
              nick: 'Péťa',
            ),
          ],
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: WeekScreen())),
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

  testWidgets('admin booking dialog shows a player-picker dropdown', (
    tester,
  ) async {
    wideSurface(tester);
    await tester.pumpWidget(app(profile: admin));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add).first);
    await tester.pumpAndSettle();
    expect(find.text('Rezervovat termín?'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
  });

  testWidgets('admin tap on foreign reservation opens the note prompt', (
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
    expect(find.text('Zrušit rezervaci — poznámka'), findsOneWidget);
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

  testWidgets('AppBar toggle switches day/week view and persists the choice', (
    tester,
  ) async {
    wideSurface(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    // Default at the test surface's 1600px width (>= 700) is week view:
    // the calendar is showing, no day chip strip yet.
    expect(find.byType(WeekCalendarView), findsOneWidget);
    expect(find.byType(DayChipStrip), findsNothing);

    await tester.tap(find.byTooltip('Den'));
    await tester.pumpAndSettle();

    expect(find.byType(DayChipStrip), findsOneWidget);
    expect(find.byType(WeekCalendarView), findsNothing);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('schedule_view'), 'day');

    // Toggling back switches the view again and updates the stored value.
    await tester.tap(find.byTooltip('Týden'));
    await tester.pumpAndSettle();

    expect(find.byType(WeekCalendarView), findsOneWidget);
    expect(find.byType(DayChipStrip), findsNothing);
    expect(
      (await SharedPreferences.getInstance()).getString('schedule_view'),
      'week',
    );
  });

  testWidgets(
    'fit-width AppBar toggle flips the icon and persists the choice',
    (tester) async {
      wideSurface(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      // At 1600px width the fit-width default is false, so the toggle offers
      // to switch it ON ("Roztáhnout na šířku").
      expect(find.byTooltip('Roztáhnout na šířku'), findsOneWidget);
      expect(find.byTooltip('Zpět na posuvnou mřížku'), findsNothing);

      await tester.tap(find.byTooltip('Roztáhnout na šířku'));
      await tester.pumpAndSettle();

      // Now the button reads as selected; the pref is persisted as true.
      expect(find.byTooltip('Zpět na posuvnou mřížku'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('fit_width'), true);

      // Toggling back flips it and updates the stored value.
      await tester.tap(find.byTooltip('Zpět na posuvnou mřížku'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Roztáhnout na šířku'), findsOneWidget);
      expect(
        (await SharedPreferences.getInstance()).getBool('fit_width'),
        false,
      );
    },
  );

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

  testWidgets('booking dialog opens from a large free tile in day view', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'schedule_view': 'day'});
    wideSurface(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.byType(DayChipStrip), findsOneWidget);

    // Select a day strictly after today within the shown week, so the visible
    // day is never `inPast` (today's slot goes past once the suite runs after
    // the harness block's start). today.weekday (1..7) is the 0-based index of
    // tomorrow within this Mon..Sun strip; when today is Sunday there is no
    // later day in-week, so tap the current week's Saturday and shift a week
    // forward instead — every path lands on a future, bookable day.
    final chips = find.descendant(
      of: find.byType(DayChipStrip),
      matching: find.byType(InkWell),
    );
    final t = today();
    if (t.weekday < DateTime.sunday) {
      await tester.tap(chips.at(t.weekday)); // tomorrow, same week
    } else {
      // Sunday: go to next week and land on its Monday.
      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();
      await tester.tap(chips.at(0));
    }
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

    // Every card carries a clickable time header with an edit glyph.
    expect(find.byIcon(Icons.edit_outlined), findsWidgets);
    final header = find.descendant(
      of: find.byKey(const ValueKey('cal-block-b1')).first,
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
      SharedPreferences.setMockInitialValues({'schedule_view': 'day'});
      wideSurface(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.byType(DayChipStrip), findsOneWidget);

      // The header's "20.4.–3.5." range label is the same Text shown above
      // both views (see WeekScreen.build's `header`) — capturing it before
      // and after the swipe is a week-offset-agnostic way to assert the
      // week actually shifted, without this test re-deriving `today()`'s
      // Monday itself (today() is real wall-clock time, not fixed here).
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
              PlayerName(id: 'me', displayName: 'Já Hráč', club: ''),
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
    expect(find.text('⛔ Údržba'), findsNWidgets(2));
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
    SharedPreferences.setMockInitialValues({'schedule_view': 'day'});
    wideSurface(tester);
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
    final t = today();
    if (t.weekday < DateTime.sunday) {
      await tester.tap(chips.at(t.weekday));
    } else {
      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();
      await tester.tap(chips.at(0));
    }
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

    final headerInTomorrow = find.descendant(
      of: find.byKey(ValueKey(tomorrow)),
      matching: find.byType(BoardColumnHeader),
    );
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

    await tester.tap(find
        .descendant(
          of: find.byKey(ValueKey(tomorrow)),
          matching: find.byType(BoardColumnHeader),
        )
        .first);
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

    // Header line (with the venku marker) — and NOTHING else: the block
    // card survives with all lanes free instead of a match band.
    expect(find.textContaining('KK Slavoj (venku)'), findsOneWidget);
    final cardInTomorrow = find.descendant(
      of: find.byKey(ValueKey(tomorrow)),
      matching: find.byKey(const ValueKey('cal-block-b1')),
    );
    expect(cardInTomorrow, findsOneWidget);
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

    final header = find.descendant(
      of: find.byKey(ValueKey(tomorrow)),
      matching: find.byType(BoardColumnHeader),
    );
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

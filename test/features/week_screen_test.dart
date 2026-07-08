import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/ui.dart' show today;
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/schedule/week_screen.dart';
import 'package:rezervator/features/schedule/widgets/day_chip_strip.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // WeekScreen now reads the schedule_view preference on its first frame
  // (see _resolveInitialView) — every test needs a mock handler for the
  // platform channel behind SharedPreferences.getInstance(), or the read
  // hangs forever and pumpAndSettle times out. No stored value means every
  // pre-existing test keeps hitting the width-based default, which is
  // `week` at the default 800×600 test surface — i.e. unchanged behavior.
  setUp(() => SharedPreferences.setMockInitialValues({}));

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
    List<Match> matches = const [],
    List<Reservation> reservations = const [],
    Profile profile = me,
  }) {
    return ProviderScope(
      overrides: [
        settingsProvider.overrideWith((ref) => Stream.value(settings)),
        timeBlocksProvider.overrideWith((ref) => Stream.value(const [b1])),
        dayOverridesProvider.overrideWith((ref) => Stream.value(overrides)),
        matchesProvider.overrideWith((ref) => Stream.value(matches)),
        rentalsProvider.overrideWith((ref) => Stream.value(const [])),
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
            PlayerName(id: 'p2', displayName: 'Petr Novák', club: ''),
          ],
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: WeekScreen())),
    );
  }

  testWidgets('closed override renders reason', (tester) async {
    await tester.pumpWidget(
      app(
        overrides: [
          DayOverride(date: tomorrow, closed: true, reason: 'Malování'),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Zavřeno — Malování'), findsOneWidget);
  });

  testWidgets('reserved cell shows player name; own name bold', (tester) async {
    await tester.pumpWidget(app(reservations: [res('r2', 'p2', tomorrow)]));
    await tester.pumpAndSettle();
    expect(find.text('Petr Novák'), findsOneWidget);
  });

  testWidgets('tap on own reservation opens cancel dialog', (tester) async {
    await tester.pumpWidget(app(reservations: [res('r1', 'me', tomorrow)]));
    await tester.pumpAndSettle();
    // `tomorrow`'s day card can sit past the default 800x600 test surface
    // depending on its weekday (e.g. Thu = 4th of 7 stacked cards), so the
    // cell must be scrolled into view before tapping — ensureVisible finds
    // the nearest Scrollable (the week ListView) and brings it on-screen.
    await tester.ensureVisible(find.text('Já Hráč').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Já Hráč').first);
    await tester.pumpAndSettle();
    expect(find.text('Zrušit rezervaci?'), findsOneWidget);
  });

  testWidgets('free bookable cell opens booking dialog', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add).first);
    await tester.pumpAndSettle();
    expect(find.text('Rezervovat termín?'), findsOneWidget);
  });

  testWidgets('admin booking dialog shows a player-picker dropdown', (
    tester,
  ) async {
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
    await tester.pumpWidget(
      app(profile: admin, reservations: [res('r2', 'p2', tomorrow)]),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Petr Novák').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Petr Novák').first);
    await tester.pumpAndSettle();
    expect(find.text('Zrušit rezervaci — poznámka'), findsOneWidget);
  });

  testWidgets('non-admin tap on foreign reservation stays inert', (
    tester,
  ) async {
    await tester.pumpWidget(app(reservations: [res('r2', 'p2', tomorrow)]));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Petr Novák').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Petr Novák').first);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('match renders banner and Zápas cells', (tester) async {
    await tester.pumpWidget(
      app(
        matches: [
          Match(
            id: 'm1',
            date: tomorrow,
            startsAt: const HourMinute(22, 0),
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
    expect(find.textContaining('KK Slavoj'), findsOneWidget);
    expect(find.text('Zápas'), findsNWidgets(2)); // 2 lanes × 1 block
  });

  testWidgets('AppBar toggle switches day/week view and persists the choice', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    // Default at the test surface's 800×600 width (>= 700) is week view:
    // the compact grid (Table) is showing, no day chip strip yet.
    expect(find.byType(Table), findsWidgets);
    expect(find.byType(DayChipStrip), findsNothing);

    await tester.tap(find.byTooltip('Den'));
    await tester.pumpAndSettle();

    expect(find.byType(DayChipStrip), findsOneWidget);
    expect(find.byType(Table), findsNothing);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('schedule_view'), 'day');

    // Toggling back switches the view again and updates the stored value.
    await tester.tap(find.byTooltip('Týden'));
    await tester.pumpAndSettle();

    expect(find.byType(Table), findsWidgets);
    expect(find.byType(DayChipStrip), findsNothing);
    expect(
      (await SharedPreferences.getInstance()).getString('schedule_view'),
      'week',
    );
  });

  testWidgets('booking dialog opens from a large free tile in day view', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'schedule_view': 'day'});
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.byType(DayChipStrip), findsOneWidget);

    await tester.tap(find.byIcon(Icons.add).first);
    await tester.pumpAndSettle();
    expect(find.text('Rezervovat termín?'), findsOneWidget);
  });

  testWidgets(
    'day view: selecting the last day and swiping past the week boundary '
    'shifts the week with no exceptions',
    (tester) async {
      SharedPreferences.setMockInitialValues({'schedule_view': 'day'});
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
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith((ref) => Stream.value(settings)),
          timeBlocksProvider.overrideWith((ref) => Stream.value(const [b1])),
          dayOverridesProvider.overrideWith((ref) => Stream.value(const [])),
          matchesProvider.overrideWith((ref) => Stream.value(const [])),
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
}

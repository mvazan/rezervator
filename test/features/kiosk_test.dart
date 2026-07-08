import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/ui.dart' show today;
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/kiosk/kiosk_shell.dart';
import 'package:rezervator/features/kiosk/kiosk_week_view.dart';
import 'package:rezervator/features/schedule/widgets/day_header.dart';

void main() {
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

  // NamePicker only shows first-letter tiles once candidates exceed its
  // fixed `_capacity` of 24 (see lib/features/kiosk/name_picker.dart and
  // test/domain/name_index_test.dart) — below that it lists full names
  // directly. 26 players with distinct first letters (A–Z) guarantees the
  // root prefix always renders as letter tiles, one per player, regardless
  // of that constant's exact value as long as it stays under 26.
  final players = [
    for (var i = 0; i < 26; i++)
      PlayerName(
        id: 'p$i',
        displayName:
            '${String.fromCharCode(65 + i)}${String.fromCharCode(65 + i)} Hráč',
        club: '',
      ),
  ];
  // The single player this test suite drills into and books for.
  final anna = players[0]; // 'AA Hráč'
  final petr = players[15]; // 'PP Hráč'

  Reservation res(String id, String playerId, Day date) => Reservation(
    id: id,
    playerId: playerId,
    date: date,
    blockId: 'b1',
    lane: 2,
    createdVia: 'app',
    createdAt: DateTime.utc(2026, 1, 1),
  );

  /// Builds a kiosk-profile app harness, wiring the same provider set as
  /// `week_screen_test.dart`'s `app()` helper directly around [KioskShell]
  /// (no AuthGate/role routing — the shell is pumped in isolation).
  Widget kioskApp({
    List<Match> matches = const [],
    List<Reservation> reservations = const [],
    List<PlayerName>? roster,
  }) {
    final effectiveRoster = roster ?? players;
    return ProviderScope(
      overrides: [
        settingsProvider.overrideWith((ref) => Stream.value(settings)),
        timeBlocksProvider.overrideWith((ref) => Stream.value(const [b1])),
        dayOverridesProvider.overrideWith((ref) => Stream.value(const [])),
        matchesProvider.overrideWith((ref) => Stream.value(matches)),
        rentalsProvider.overrideWith((ref) => Stream.value(const [])),
        weekReservationsProvider.overrideWith(
          (ref, monday) => Stream.value(reservations),
        ),
        playersProvider.overrideWith((ref) async => effectiveRoster),
      ],
      child: const MaterialApp(home: KioskShell()),
    );
  }

  // KioskShell starts a 60 s idle timer and a 20 s clock timer in initState.
  // Ending a test with either still pending fails the widget-test harness
  // ("A Timer is still pending"), so every test tears down by pumping a
  // replacement widget tree — that runs KioskShell.dispose(), which cancels
  // both timers — before the test body returns.
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
  }

  testWidgets(
    'a: shell shows status bar with Rezervovat and no logout/admin icons',
    (tester) async {
      await tester.pumpWidget(kioskApp());
      await tester.pumpAndSettle();

      expect(find.text('Rezervovat'), findsOneWidget);
      expect(find.byIcon(Icons.logout), findsNothing);
      expect(find.byIcon(Icons.admin_panel_settings), findsNothing);
      expect(find.byType(AppBar), findsNothing);

      await finish(tester);
    },
  );

  testWidgets('b: tapping Rezervovat opens picker with first-letter tiles', (
    tester,
  ) async {
    await tester.pumpWidget(kioskApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Rezervovat'));
    await tester.pumpAndSettle();

    // 26 candidates > the picker's fixed capacity → root shows one
    // first-letter tile per distinct initial, not full names.
    expect(find.text('A'), findsOneWidget);
    expect(find.text('P'), findsOneWidget);
    // Drilled-down full names aren't shown yet at the root level.
    expect(find.text(anna.displayName), findsNothing);
    expect(find.text(petr.displayName), findsNothing);

    await finish(tester);
  });

  testWidgets(
    'c: drilling to a name and tapping it shows the Rezervuje: banner',
    (tester) async {
      await tester.pumpWidget(kioskApp());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Rezervovat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('A')); // drill into the 'A' prefix tile
      await tester.pumpAndSettle();
      await tester.tap(find.text(anna.displayName)); // 'AA Hráč'
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Rezervuje: ${anna.displayName}'),
        findsOneWidget,
      );
      // The picker button is replaced by the selection banner.
      expect(find.text('Rezervovat'), findsNothing);

      await finish(tester);
    },
  );

  testWidgets('d: with a selected player, tapping a + cell opens the booking '
      'confirm dialog containing the player\'s name', (tester) async {
    await tester.pumpWidget(kioskApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Rezervovat'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(anna.displayName));
    await tester.pumpAndSettle();

    // The grid's ListView only builds day-section Cards near the viewport
    // (a plain, non-lazy ListView still sits under a lazy sliver), so on
    // this narrow 800×600 test surface the first + cell may not exist in
    // the tree yet — ensureVisible both scrolls it in and asserts it landed
    // inside the viewport before tap() hit-tests it (c.f. the analogous
    // scroll-into-view step in week_screen_test.dart).
    final addCell = find.byIcon(Icons.add).first;
    await tester.ensureVisible(addCell);
    await tester.pumpAndSettle();
    await tester.tap(addCell);
    await tester.pumpAndSettle();

    expect(find.text('Rezervovat termín?'), findsOneWidget);
    expect(find.textContaining(anna.displayName), findsWidgets);

    await finish(tester);
  });

  testWidgets('e: reserved cells have no cancel affordance (tap → no dialog)', (
    tester,
  ) async {
    await tester.pumpWidget(
      kioskApp(reservations: [res('r1', petr.id, tomorrow)]),
    );
    await tester.pumpAndSettle();

    // `tomorrow`'s day Card isn't necessarily built yet on this test
    // surface (see comment above) — drag the grid up first so the
    // reserved-slot Text actually exists to be found before ensureVisible
    // fine-tunes its position.
    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(petr.displayName).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(petr.displayName).first);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(Dialog), findsNothing);

    await finish(tester);
  });

  testWidgets('f: kiosk always renders dark and shows the full week', (
    tester,
  ) async {
    await tester.pumpWidget(kioskApp());
    await tester.pumpAndSettle();

    // The kiosk stays dark regardless of the device's system brightness
    // (spec §4) — MaterialApp's default theme in this harness is light, so
    // this only passes because KioskShell wraps itself in
    // Theme(data: buildTheme(Brightness.dark)).
    expect(
      Theme.of(tester.element(find.byType(KioskWeekView))).brightness,
      Brightness.dark,
    );
    // Always the full week — one DayHeader per day, Monday..Sunday. Only a
    // handful of day Cards are built at once near the viewport on this
    // 800×600 test surface (see the drag/ensureVisible comments on the
    // tests above), and no single scroll position builds all 7
    // simultaneously — so accumulate the distinct dates seen while
    // scrolling through the whole list.
    final seenDates = <Day>{};
    void collect() {
      for (final header in tester.widgetList<DayHeader>(
        find.byType(DayHeader),
      )) {
        seenDates.add(header.date);
      }
    }

    collect();
    for (var i = 0; i < 8; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pumpAndSettle();
      collect();
    }
    expect(seenDates, hasLength(7));

    await finish(tester);
  });
}

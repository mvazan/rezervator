import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/theme.dart';
import 'package:rezervator/core/ui.dart' show today;
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/clubhouse/match_detail_screen.dart';
import 'package:rezervator/features/clubhouse/widgets/duel_card.dart';
import 'package:rezervator/features/clubhouse/widgets/legacy_score_sheet.dart';
import 'package:rezervator/features/clubhouse/widgets/match_scoreboard.dart';
import 'package:rezervator/features/kiosk/kiosk_board_view.dart';
import 'package:rezervator/features/kiosk/kiosk_connection.dart';
import 'package:rezervator/features/kiosk/kiosk_info_panel.dart';
import 'package:rezervator/features/kiosk/kiosk_shell.dart';
import 'package:rezervator/features/kiosk/kiosk_headline.dart';
import 'package:rezervator/features/kiosk/name_picker.dart';
import 'package:rezervator/features/schedule/widgets/calendar_board.dart';
import 'package:rezervator/features/schedule/widgets/schedule_day_column.dart';

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

  const uklidType = PrioritySlotType(
    id: 't-uklid',
    name: 'Úklid před zápasem',
    builtin: true,
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
  ///
  /// [theme] defaults to Flutter's own default (unspecified, as every
  /// pre-existing test here relied on) — pass an explicit light theme to
  /// reproduce the real app's actual light/dark split (see main.dart's
  /// `theme: buildTheme(Brightness.light)`) for tests that care whether the
  /// kiosk correctly stays dark regardless of the ambient app theme.
  Widget kioskApp({
    List<PrioritySlot> matches = const [],
    List<Reservation> reservations = const [],
    List<PlayerName>? roster,
    ThemeData? theme,
    bool kioskDark = true,
    bool kioskFitDay = true,
    int? maxActiveReservations,
  }) {
    final effectiveRoster = roster ?? players;
    final effSettings = ScheduleSettings(
      laneCount: settings.laneCount,
      trainingWeekdays: settings.trainingWeekdays,
      bookingHorizonDays: settings.bookingHorizonDays,
      maxActiveReservations:
          maxActiveReservations ?? settings.maxActiveReservations,
      kioskDark: kioskDark,
      kioskFitDay: kioskFitDay,
    );
    return ProviderScope(
      overrides: [
        settingsProvider.overrideWith((ref) => Stream.value(effSettings)),
        timeBlocksProvider.overrideWith((ref) => Stream.value(const [b1])),
        dayOverridesProvider.overrideWith((ref) => Stream.value(const [])),
        prioritySlotsProvider.overrideWithValue(matches),
        rentalsProvider.overrideWith((ref) => Stream.value(const [])),
        // Week-scoped like the real provider (Monday..Sunday), so no
        // reservation reaches two weeks' streams — the board sums them.
        weekReservationsProvider.overrideWith(
          (ref, monday) => Stream.value([
            for (final r in reservations)
              if (!r.date.isBefore(monday) &&
                  r.date.differenceInDays(monday) < 7)
                r,
          ]),
        ),
        playersProvider.overrideWith((ref) async => effectiveRoster),
      ],
      child: MaterialApp(theme: theme, home: const KioskShell()),
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

    // Today is the board's first (always-built) column, so the + cell is
    // already in the tree — the board renders free lanes as a literal '＋'
    // character (spec §1), not the Material add icon.
    final addCell = find.text('＋').first;
    await tester.ensureVisible(addCell);
    await tester.pumpAndSettle();
    await tester.tap(addCell);
    await tester.pumpAndSettle();

    expect(find.text('Rezervovat termín?'), findsOneWidget);
    expect(find.textContaining(anna.displayName), findsWidgets);

    await finish(tester);
  });

  testWidgets(
    'd2: a selected player at the reservation limit gets no ＋; under the '
    'limit free slots offer it',
    (tester) async {
      Future<void> selectAnna() async {
        await tester.tap(find.text('Rezervovat'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('A'));
        await tester.pumpAndSettle();
        // Scoped to the picker: with her reservation on the board, Anna's
        // name is also a reserved cell behind the dialog.
        await tester.tap(
          find.descendant(
            of: find.byType(NamePicker),
            matching: find.text(anna.displayName),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Rezervuje: ${anna.displayName}'),
          findsOneWidget,
        );
      }

      // Anna already holds one live future reservation and the limit is
      // one: the board must not offer ＋ anywhere — create_reservation
      // would only bounce it with limit_reached — and it has to SAY so,
      // or the kiosk just looks broken to whoever is standing there.
      await tester.pumpWidget(
        kioskApp(
          maxActiveReservations: 1,
          reservations: [res('r1', anna.id, tomorrow)],
        ),
      );
      await tester.pumpAndSettle();
      await selectAnna();
      expect(find.text('＋'), findsNothing);
      expect(
        find.textContaining('Máš maximální počet rezervací (1)'),
        findsOneWidget,
        reason: 'the missing ＋ has to be explained, not just missing',
      );
      await finish(tester);

      // Same limit, nothing booked yet: free slots offer ＋ and nobody is
      // told about a cap they have not reached.
      await tester.pumpWidget(kioskApp(maxActiveReservations: 1));
      await tester.pumpAndSettle();
      await selectAnna();
      expect(find.text('＋'), findsWidgets);
      expect(find.textContaining('maximální počet rezervací'), findsNothing);
      await finish(tester);
    },
  );

  testWidgets(
    'd3: a player without an account gets a name tile in the picker and '
    'books through the same confirm dialog as everyone else',
    (tester) async {
      // A hand-made "hráč bez účtu" never signs in — the admin books for
      // them, or they pick themself right here. Appended to the 26-player
      // roster the root keeps its letter tiles and the 'B' prefix lists
      // him next to 'BB Hráč'.
      const ghost = PlayerName(
        id: 'ghost',
        displayName: 'Bohumil Kroupa',
        hasAccount: false,
      );
      await tester.pumpWidget(kioskApp(roster: [...players, ghost]));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Rezervovat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('B'));
      await tester.pumpAndSettle();
      expect(find.text(ghost.displayName), findsOneWidget);
      await tester.tap(find.text(ghost.displayName));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Rezervuje: ${ghost.displayName}'),
        findsOneWidget,
      );

      // Same steps as test d: today's column is always built, free lanes
      // render as a literal '＋'.
      final addCell = find.text('＋').first;
      await tester.ensureVisible(addCell);
      await tester.pumpAndSettle();
      await tester.tap(addCell);
      await tester.pumpAndSettle();

      expect(find.text('Rezervovat termín?'), findsOneWidget);
      expect(find.textContaining(ghost.displayName), findsWidgets);
      // The kiosk never mentions accounts or e-mail — no admin-style hint.
      expect(find.textContaining('bez účtu'), findsNothing);

      await finish(tester);
    },
  );

  testWidgets('e: reserved cells have no cancel affordance (tap → no dialog)', (
    tester,
  ) async {
    await tester.pumpWidget(
      kioskApp(reservations: [res('r1', petr.id, tomorrow)]),
    );
    await tester.pumpAndSettle();

    // `tomorrow` is board column index 1 — the board's horizontal ListView
    // only builds columns near the viewport, so the reserved-slot Text
    // doesn't exist yet until the grid scrolls exactly one column over
    // (measuring a live column's width rather than hardcoding the
    // clamp(160, (w-rail)/7, 220) constant keeps this test independent of
    // that formula's exact numbers).
    final columnWidth = tester
        .getSize(find.byType(BoardColumnHeader).first)
        .width;
    await tester.drag(
      find.byWidgetPredicate(
        (w) => w is ListView && w.physics is ColumnSnapPhysics,
      ),
      Offset(-columnWidth, 0),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(petr.displayName).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(petr.displayName).first);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(Dialog), findsNothing);

    await finish(tester);
  });

  testWidgets(
    'f: kiosk always renders dark and shows 7 board columns from today',
    (tester) async {
      await tester.pumpWidget(kioskApp());
      await tester.pumpAndSettle();

      // The kiosk stays dark regardless of the device's system brightness
      // (spec §4) — MaterialApp's default theme in this harness is light,
      // so this only passes because KioskShell wraps itself in
      // Theme(data: buildTheme(Brightness.dark)).
      expect(
        Theme.of(tester.element(find.byType(KioskBoardView))).brightness,
        Brightness.dark,
      );
      // Board columns run from today forward (spec §1) — the horizontal
      // ListView only builds columns near the viewport, so drag exactly one
      // column width at a time through indices 0..6, collecting each
      // BoardColumnHeader's date (measuring a live column's width rather
      // than hardcoding the clamp(160, (w-rail)/7, 220) constant keeps this
      // test independent of that formula's exact numbers).
      final columnWidth = tester
          .getSize(find.byType(BoardColumnHeader).first)
          .width;
      final seenDates = <Day>{};
      void collect() {
        for (final header in tester.widgetList<BoardColumnHeader>(
          find.byType(BoardColumnHeader),
        )) {
          seenDates.add(header.date);
        }
      }

      collect();
      for (var i = 0; i < 6; i++) {
        await tester.drag(
          find.byWidgetPredicate(
            (w) => w is ListView && w.physics is ColumnSnapPhysics,
          ),
          Offset(-columnWidth, 0),
        );
        await tester.pumpAndSettle();
        collect();
      }
      // Every one of today's next 6 days was visited (the board's 7
      // originally-visible-without-scroll columns, spec §1)…
      expect(
        seenDates.containsAll({for (var i = 0; i < 7; i++) t.addDays(i)}),
        isTrue,
      );
      // …and the ListView's look-ahead cache may have also mounted columns
      // further out, but never one before today — "days from DNES", never
      // the past (unlike the old week view, which always started on
      // Monday regardless of today).
      expect(seenDates.every((d) => !d.isBefore(t)), isTrue);

      await finish(tester);
    },
  );

  testWidgets('g: NamePicker renders dark even when the app theme is light', (
    tester,
  ) async {
    // Unlike every other test in this file (which relies on this
    // harness's implicit default theme), this one must pin the ambient
    // MaterialApp theme to light explicitly — mirroring main.dart's
    // `theme: buildTheme(Brightness.light)` — so a pass here can't be
    // credited to the test harness happening to already be dark; only
    // NamePicker's own Theme(dark) wrap (name_picker.dart) should make it
    // render dark. No darkTheme is supplied, so MaterialApp's ThemeMode
    // .system resolution (see _themeBuilder in the framework's app.dart)
    // always falls through to `theme` regardless of the test platform's
    // own brightness — the ambient theme here is deterministically light.
    await tester.pumpWidget(kioskApp(theme: buildTheme(Brightness.light)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Rezervovat'));
    await tester.pumpAndSettle();

    // showNamePicker(context) in kiosk_shell.dart uses the shell State's
    // own context, which sits *above* KioskShell's Theme(dark) wrap — so
    // without name_picker.dart's own Theme(dark) wrap around the dialog
    // content, this would inherit the ambient light theme instead.
    expect(
      Theme.of(tester.element(find.text('Kdo si rezervuje?'))).brightness,
      Brightness.dark,
    );

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    await finish(tester);
  });

  testWidgets(
    'g2: NamePicker follows the admin light kiosk theme when kioskDark=false',
    (tester) async {
      // Admin set the kiosk to light mode (settings.kioskDark=false); the
      // picker must render light too, even though the ambient app theme is
      // dark here — proving the shell threads the kiosk brightness into
      // showNamePicker rather than the picker hardcoding dark.
      await tester.pumpWidget(
        kioskApp(theme: buildTheme(Brightness.dark), kioskDark: false),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Rezervovat'));
      await tester.pumpAndSettle();

      expect(
        Theme.of(tester.element(find.text('Kdo si rezervuje?'))).brightness,
        Brightness.light,
      );

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      await finish(tester);
    },
  );

  testWidgets(
    'h: a player with a nick shows the nick on the board; one without shows '
    'displayName',
    (tester) async {
      const withNick = PlayerName(
        id: 'nick1',
        displayName: 'Zdeněk Procházka',
        nick: 'Zdenda',
      );
      const withoutNick = PlayerName(
        id: 'nonick1',
        displayName: 'Bořivoj Novotný',
      );
      await tester.pumpWidget(
        kioskApp(
          roster: [withNick, withoutNick],
          reservations: [
            res('r1', withNick.id, t),
            Reservation(
              id: 'r2',
              playerId: withoutNick.id,
              date: t,
              blockId: 'b1',
              lane: 1,
              createdVia: 'app',
              createdAt: DateTime.utc(2026, 1, 1),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // Board shows the nick, never the full displayName, for withNick…
      expect(find.text('Zdenda'), findsOneWidget);
      expect(find.text(withNick.displayName), findsNothing);
      // …and falls back to displayName for a player with no nick set.
      expect(find.text(withoutNick.displayName), findsOneWidget);

      await finish(tester);
    },
  );

  testWidgets(
    'i: a whole-alley match and its úklid child cancel the blocks they '
    'touch and render as true-time bands',
    (tester) async {
      // Two adjacent blocks: bPrep (20:00-21:00) and bMatch (21:00-22:00).
      // Match 21:00-22:00 + linked úklid 20:00-21:00: BOTH blocks are
      // cancelled for the day; the board shows the úklid band over
      // 20:00-21:00 and the match band over 21:00-22:00 instead.
      const bPrep = TimeBlock(
        id: 'bPrep',
        startsAt: HourMinute(20, 0),
        endsAt: HourMinute(21, 0),
        position: 0,
        active: true,
      );
      const bMatch = TimeBlock(
        id: 'bMatch',
        startsAt: HourMinute(21, 0),
        endsAt: HourMinute(22, 0),
        position: 1,
        active: true,
      );
      final match = PrioritySlot(
        type: PrioritySlot.fallbackMatchType,
        id: 'm1',
        date: t,
        startsAt: const HourMinute(21, 0),
        endsAt: const HourMinute(22, 0),
        homeTeam: '',
        awayTeam: 'KK Slavoj',
        description: '',
      );
      final uklid = PrioritySlot(
        type: uklidType,
        id: 'u1',
        date: t,
        startsAt: const HourMinute(20, 0),
        endsAt: const HourMinute(21, 0),
        parentId: 'm1',
        description: '',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith((ref) => Stream.value(settings)),
            timeBlocksProvider.overrideWith(
              (ref) => Stream.value(const [bPrep, bMatch]),
            ),
            dayOverridesProvider.overrideWith((ref) => Stream.value(const [])),
            prioritySlotsProvider.overrideWithValue([match, uklid]),
            rentalsProvider.overrideWith((ref) => Stream.value(const [])),
            weekReservationsProvider.overrideWith(
              (ref, monday) => Stream.value(const []),
            ),
            playersProvider.overrideWith((ref) async => players),
          ],
          child: const MaterialApp(home: KioskShell()),
        ),
      );
      await tester.pumpAndSettle();

      // Both bands render at their real windows, once (slots are today only).
      expect(find.text('⛔ Úklid před zápasem\n20:00–21:00'), findsOneWidget);
      expect(
        find.text(
          '🏆 ${match.title}\n'
          '${match.startsAt.display()}–${match.endsAt.display()}',
        ),
        findsOneWidget,
      );

      // Today's cancelled blocks render no cards — tomorrow's still do, so
      // exactly one fewer card than visible columns exists per block id.
      final visibleDays = tester
          .widgetList(find.byType(BoardColumnHeader))
          .length;
      expect(
        find.byKey(const ValueKey('cal-block-bPrep')),
        findsNWidgets(visibleDays - 1),
      );
      expect(
        find.byKey(const ValueKey('cal-block-bMatch')),
        findsNWidgets(visibleDays - 1),
      );

      await finish(tester);
    },
  );

  testWidgets(
    'j: a fully closed day hosting a match shows the match band and no '
    '✕ zavřeno label — the band speaks for the day',
    (tester) async {
      final match = PrioritySlot(
        type: PrioritySlot.fallbackMatchType,
        id: 'm2',
        date: t,
        startsAt: const HourMinute(23, 0),
        endsAt: const HourMinute(23, 30),
        homeTeam: '',
        awayTeam: 'TJ Sokol',
        prepMinutes: 0,
        description: '',
      );
      // A second rail block the match never touches keeps the rest of the
      // column plainly closed; the label still stays away — a single band
      // is enough to explain the whole day.
      const bOther = TimeBlock(
        id: 'bOther',
        startsAt: HourMinute(8, 0),
        endsAt: HourMinute(9, 0),
        position: 1,
        active: true,
      );
      // Close only today via a day override (reason left empty — the exact
      // '✕ zavřeno' text with no trailing reason). Every weekday stays a
      // training day so the rest of the week remains open and still
      // contributes b1/bOther to the rail — otherwise, with every day
      // closed, the rail (union of OPEN days' blocks) would be empty and no
      // row-group (hence no closed cell at all) would render.
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith((ref) => Stream.value(settings)),
            timeBlocksProvider.overrideWith(
              (ref) => Stream.value(const [b1, bOther]),
            ),
            dayOverridesProvider.overrideWith(
              (ref) => Stream.value([
                DayOverride(date: t, closed: true, reason: ''),
              ]),
            ),
            prioritySlotsProvider.overrideWithValue([match]),
            rentalsProvider.overrideWith((ref) => Stream.value(const [])),
            weekReservationsProvider.overrideWith(
              (ref, monday) => Stream.value(const []),
            ),
            playersProvider.overrideWith((ref) async => players),
          ],
          child: const MaterialApp(home: KioskShell()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('✕ zavřeno'), findsNothing);
      // Same disambiguation as test i: the closed-column match band renders
      // '🏆 {title}\n{start}–{end}', distinct from the header banner's
      // plain '🏆 {title}'.
      expect(
        find.text(
          '🏆 ${match.title}\n'
          '${match.startsAt.display()}–${match.endsAt.display()}',
        ),
        findsOneWidget,
      );

      await finish(tester);
    },
  );

  testWidgets(
    'k: idle reset scrolls to today and now without throwing, and the board '
    'renders faint hour gridlines plus the hour ruler labels',
    (tester) async {
      // Two blocks so the window spans several hours and at least one
      // interior hour line exists.
      const bMorning = TimeBlock(
        id: 'bMorning',
        startsAt: HourMinute(8, 0),
        endsAt: HourMinute(9, 0),
        position: 0,
        active: true,
      );
      const bEvening = TimeBlock(
        id: 'bEvening',
        startsAt: HourMinute(11, 0),
        endsAt: HourMinute(12, 0),
        position: 1,
        active: true,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith((ref) => Stream.value(settings)),
            timeBlocksProvider.overrideWith(
              (ref) => Stream.value(const [bMorning, bEvening]),
            ),
            dayOverridesProvider.overrideWith((ref) => Stream.value(const [])),
            prioritySlotsProvider.overrideWithValue(const []),
            rentalsProvider.overrideWith((ref) => Stream.value(const [])),
            weekReservationsProvider.overrideWith(
              (ref, monday) => Stream.value(const []),
            ),
            playersProvider.overrideWith((ref) async => players),
          ],
          child: const MaterialApp(home: KioskShell()),
        ),
      );
      await tester.pumpAndSettle();

      // Hour gridlines are Dividers positioned by the shared window; the
      // ruler labels whole hours of the 8:00–12:00 window. findsWidgets:
      // the status-bar clock can legitimately show the same text when the
      // suite runs at exactly that wall-clock minute.
      expect(find.byType(Divider), findsWidgets);
      expect(find.text('08:00'), findsWidgets);
      expect(find.text('12:00'), findsWidgets);

      // resetToToday (imperative idle-reset entry point the shell calls)
      // must not throw even mid-animation, and settles cleanly.
      final boardState = tester.state<KioskBoardViewState>(
        find.byType(KioskBoardView),
      );
      expect(() => boardState.resetToToday(), returnsNormally);
      await tester.pumpAndSettle();

      await finish(tester);
    },
  );

  testWidgets(
    'l: block cards are duration-proportional, positioned at their true '
    'time, and vertically aligned across day columns',
    (tester) async {
      // A 30-min block, a 30-min hole, then a 60-min block: the calendar
      // maps y = time, so the long card is exactly twice the short card's
      // height and starts exactly one short-card-plus-hole below it.
      const bShort = TimeBlock(
        id: 'bShort',
        startsAt: HourMinute(8, 0),
        endsAt: HourMinute(8, 30),
        position: 0,
        active: true,
      );
      const bLong = TimeBlock(
        id: 'bLong',
        startsAt: HourMinute(9, 0),
        endsAt: HourMinute(10, 0),
        position: 1,
        active: true,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith((ref) => Stream.value(settings)),
            timeBlocksProvider.overrideWith(
              (ref) => Stream.value(const [bShort, bLong]),
            ),
            dayOverridesProvider.overrideWith((ref) => Stream.value(const [])),
            prioritySlotsProvider.overrideWithValue(const []),
            rentalsProvider.overrideWith((ref) => Stream.value(const [])),
            weekReservationsProvider.overrideWith(
              (ref, monday) => Stream.value(const []),
            ),
            playersProvider.overrideWith((ref) async => players),
          ],
          child: const MaterialApp(home: KioskShell()),
        ),
      );
      await tester.pumpAndSettle();

      final shortCards = find.byKey(const ValueKey('cal-block-bShort'));
      final longCards = find.byKey(const ValueKey('cal-block-bLong'));
      expect(shortCards, findsWidgets);

      final shortSize = tester.getSize(shortCards.first);
      final longSize = tester.getSize(longCards.first);
      // Duration-proportional: 60 min renders exactly twice 30 min.
      expect(longSize.height, closeTo(shortSize.height * 2, 0.5));

      // True-time placement: the 8:30–9:00 hole between the cards is as
      // tall as the 30-min block itself (same px/min scale).
      final shortTop = tester.getTopLeft(shortCards.first).dy;
      final longTop = tester.getTopLeft(longCards.first).dy;
      expect(longTop - shortTop, closeTo(shortSize.height * 2, 0.5));

      // Cross-column alignment (the PR #12–14 invariant): every visible
      // day's card for the same block sits at the same y.
      final shortTops = [
        for (var i = 0; i < shortCards.evaluate().length; i++)
          tester.getTopLeft(shortCards.at(i)).dy,
      ];
      expect(shortTops.toSet().length, 1);

      await finish(tester);
    },
  );

  testWidgets(
    'm: an off-block rental renders as a band in an occupied gap with its '
    'real times, and the rail labels the gap range',
    (tester) async {
      const bShort = TimeBlock(
        id: 'bShort',
        startsAt: HourMinute(8, 0),
        endsAt: HourMinute(8, 30),
        position: 0,
        active: true,
      );
      const bLong = TimeBlock(
        id: 'bLong',
        startsAt: HourMinute(10, 0),
        endsAt: HourMinute(11, 0),
        position: 1,
        active: true,
      );
      // Rental 8:45–9:30 today: overlaps no block → occupied gap band.
      final rental = Rental(
        id: 'n1',
        renterName: 'Firma X',
        lanes: const [1],
        date: today(),
        weekday: null,
        startsAt: const HourMinute(8, 45),
        endsAt: const HourMinute(9, 30),
        validFrom: null,
        validUntil: null,
        note: '',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith((ref) => Stream.value(settings)),
            timeBlocksProvider.overrideWith(
              (ref) => Stream.value(const [bShort, bLong]),
            ),
            dayOverridesProvider.overrideWith((ref) => Stream.value(const [])),
            prioritySlotsProvider.overrideWithValue(const []),
            rentalsProvider.overrideWith((ref) => Stream.value([rental])),
            weekReservationsProvider.overrideWith(
              (ref, monday) => Stream.value(const []),
            ),
            playersProvider.overrideWith((ref) async => players),
          ],
          child: const MaterialApp(home: KioskShell()),
        ),
      );
      await tester.pumpAndSettle();

      // The band shows the renter with its real times, exactly once (the
      // rental is one-time, so only today's column has it).
      expect(find.text('🔒 Firma X\n8:45–9:30'), findsOneWidget);

      // And it sits at its true time: band top-to-block top distance equals
      // 45 minutes at the shared px/min scale (block card = 30 min).
      final shortCard = find.byKey(const ValueKey('cal-block-bShort')).first;
      final band = find.text('🔒 Firma X\n8:45–9:30');
      final pxPerMinute = tester.getSize(shortCard).height / 30;
      final bandTop = tester
          .getTopLeft(
            find.ancestor(of: band, matching: find.byType(Container)).first,
          )
          .dy;
      expect(
        bandTop - tester.getTopLeft(shortCard).dy,
        closeTo(45 * pxPerMinute, 4), // band carries a small margin
      );

      // The blocks themselves stay in place around the event.
      expect(find.byKey(const ValueKey('cal-block-bLong')), findsWidgets);

      await finish(tester);
    },
  );

  testWidgets(
    'n: the úklid child widens the shared calendar window (ruler labels '
    'its hour, the band renders at its true time)',
    (tester) async {
      const b = TimeBlock(
        id: 'b',
        startsAt: HourMinute(20, 0),
        endsAt: HourMinute(22, 0),
        position: 0,
        active: true,
      );
      final match = PrioritySlot(
        type: PrioritySlot.fallbackMatchType,
        id: 'm1',
        date: t,
        startsAt: const HourMinute(20, 0),
        endsAt: const HourMinute(21, 0),
        homeTeam: '',
        awayTeam: 'KK Slavoj',
        description: '',
      );
      final uklid = PrioritySlot(
        type: uklidType,
        id: 'u1',
        date: t,
        startsAt: const HourMinute(19, 0), // earliest content anywhere
        endsAt: const HourMinute(20, 0),
        parentId: 'm1',
        description: '',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith((ref) => Stream.value(settings)),
            timeBlocksProvider.overrideWith((ref) => Stream.value(const [b])),
            dayOverridesProvider.overrideWith((ref) => Stream.value(const [])),
            prioritySlotsProvider.overrideWithValue([match, uklid]),
            rentalsProvider.overrideWith((ref) => Stream.value(const [])),
            weekReservationsProvider.overrideWith(
              (ref, monday) => Stream.value(const []),
            ),
            playersProvider.overrideWith((ref) async => players),
          ],
          child: const MaterialApp(home: KioskShell()),
        ),
      );
      await tester.pumpAndSettle();

      // The window must reach 19:00 or the band would render above it.
      expect(find.text('19:00'), findsWidgets);
      expect(find.text('⛔ Úklid před zápasem\n19:00–20:00'), findsOneWidget);

      await finish(tester);
    },
  );

  testWidgets(
    'o: a LANE-scoped slot with prep does NOT widen the window — only its '
    'real window paints, so only that reserves space',
    (tester) async {
      const laneType = PrioritySlotType(
        id: 't-lane',
        name: 'Údržba',
        colorIndex: 3,
        lanes: [1],
      );
      const b = TimeBlock(
        id: 'b',
        startsAt: HourMinute(20, 0),
        endsAt: HourMinute(22, 0),
        position: 0,
        active: true,
      );
      final laneSlot = PrioritySlot(
        type: laneType,
        id: 's1',
        date: t,
        startsAt: const HourMinute(8, 0),
        endsAt: const HourMinute(9, 0),
        prepMinutes: 60, // blockingStart 7:00 — must NOT reserve 7:00-8:00
        description: '',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith((ref) => Stream.value(settings)),
            timeBlocksProvider.overrideWith((ref) => Stream.value(const [b])),
            dayOverridesProvider.overrideWith((ref) => Stream.value(const [])),
            prioritySlotsProvider.overrideWithValue([laneSlot]),
            rentalsProvider.overrideWith((ref) => Stream.value(const [])),
            weekReservationsProvider.overrideWith(
              (ref, monday) => Stream.value(const []),
            ),
            playersProvider.overrideWith((ref) async => players),
          ],
          child: const MaterialApp(home: KioskShell()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('08:00'), findsOneWidget);
      expect(find.text('07:00'), findsNothing);
      // And no prep band renders for a lane-scoped slot (its prep resolves
      // per lane inside surviving blocks).
      expect(find.textContaining('🛠'), findsNothing);

      await finish(tester);
    },
  );

  testWidgets(
    'p: a rental inside a whole-alley match window never paints over the '
    'match band; only its outside piece renders',
    (tester) async {
      const b = TimeBlock(
        id: 'b',
        startsAt: HourMinute(20, 0),
        endsAt: HourMinute(22, 0),
        position: 0,
        active: true,
      );
      final match = PrioritySlot(
        type: PrioritySlot.fallbackMatchType,
        id: 'm1',
        date: t,
        startsAt: const HourMinute(20, 0),
        endsAt: const HourMinute(22, 0),
        homeTeam: '',
        awayTeam: 'KK Slavoj',
        prepMinutes: 0,
        description: '',
      );
      final insideRental = Rental(
        id: 'n1',
        renterName: 'Firma X',
        lanes: const [1],
        date: t,
        weekday: null,
        startsAt: const HourMinute(20, 30),
        endsAt: const HourMinute(21, 0),
        validFrom: null,
        validUntil: null,
        note: '',
      );
      final spillRental = Rental(
        id: 'n2',
        renterName: 'Firma Y',
        lanes: const [1],
        date: t,
        weekday: null,
        startsAt: const HourMinute(21, 30),
        endsAt: const HourMinute(22, 30),
        validFrom: null,
        validUntil: null,
        note: '',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith((ref) => Stream.value(settings)),
            timeBlocksProvider.overrideWith((ref) => Stream.value(const [b])),
            dayOverridesProvider.overrideWith((ref) => Stream.value(const [])),
            prioritySlotsProvider.overrideWithValue([match]),
            rentalsProvider.overrideWith(
              (ref) => Stream.value([insideRental, spillRental]),
            ),
            weekReservationsProvider.overrideWith(
              (ref, monday) => Stream.value(const []),
            ),
            playersProvider.overrideWith((ref) async => players),
          ],
          child: const MaterialApp(home: KioskShell()),
        ),
      );
      await tester.pumpAndSettle();

      // The match band renders; the fully-covered rental does not (priority
      // wins, first-emitted band keeps the space)…
      expect(find.text('🏆 ${match.title}\n20:00–22:00'), findsOneWidget);
      expect(find.textContaining('Firma X'), findsNothing);
      // …and the spilling rental shows only via its outside piece.
      expect(find.textContaining('Firma Y'), findsOneWidget);

      await finish(tester);
    },
  );

  testWidgets('q: kiosk_fit_day=false switches to the comfortable fixed scale '
      '(60 min = laneCount × 40 px) instead of fit-to-screen', (tester) async {
    await tester.pumpWidget(kioskApp(kioskFitDay: false));
    await tester.pumpAndSettle();

    // b1 is 61 minutes; at laneCount(2) × 40 / 60 px per minute the card
    // is 61 × 1.333… ≈ 81.3px tall — independent of the viewport height.
    final card = find.byKey(const ValueKey('cal-block-b1')).first;
    expect(
      tester.getSize(card).height,
      closeTo(61 * settings.laneCount * 40.0 / 60, 0.7),
    );

    await finish(tester);
  });

  testWidgets(
    'r: half-hour block boundaries get half-hour ruler labels and the '
    'window starts on the half hour',
    (tester) async {
      const bHalf = TimeBlock(
        id: 'bHalf',
        startsAt: HourMinute(15, 30),
        endsAt: HourMinute(16, 30),
        position: 0,
        active: true,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith((ref) => Stream.value(settings)),
            timeBlocksProvider.overrideWith(
              (ref) => Stream.value(const [bHalf]),
            ),
            dayOverridesProvider.overrideWith((ref) => Stream.value(const [])),
            prioritySlotsProvider.overrideWithValue(const []),
            rentalsProvider.overrideWith((ref) => Stream.value(const [])),
            weekReservationsProvider.overrideWith(
              (ref, monday) => Stream.value(const []),
            ),
            playersProvider.overrideWith((ref) async => players),
          ],
          child: const MaterialApp(home: KioskShell()),
        ),
      );
      await tester.pumpAndSettle();

      // Window starts AT 15:30 (no padded 15:00 label) and the half hours
      // are labeled because the alley actually uses them.
      expect(find.text('15:30'), findsOneWidget);
      expect(find.text('16:30'), findsOneWidget);
      expect(find.text('15:00'), findsNothing);

      await finish(tester);
    },
  );

  testWidgets(
    's: the day dialog opens non-interactively from the kiosk header — '
    'score shows, but no video button and no tap-through (PR B fix round 1: '
    'the 60 s idle-reset Listener never sees touches on a pushed route, and '
    'an external video browser on a kiosk tablet is undesirable)',
    (tester) async {
      final match = PrioritySlot(
        type: PrioritySlot.fallbackMatchType,
        id: 'mFed',
        date: t,
        startsAt: const HourMinute(20, 0),
        endsAt: const HourMinute(21, 0),
        homeTeam: 'Naši',
        awayTeam: 'Soupeř',
        importKey: 'cka:mFed',
        videoUrl: 'https://vysledky.kuzelky.cz/video/mFed',
      );
      final result = MatchResult.fromJson(const {
        'match_id': 'mFed',
        'status': 'finished',
        'home_points': 5,
        'away_points': 3,
        'fetched_at': '2026-09-17T21:00:00+00:00',
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith((ref) => Stream.value(settings)),
            timeBlocksProvider.overrideWith((ref) => Stream.value(const [b1])),
            dayOverridesProvider.overrideWith((ref) => Stream.value(const [])),
            prioritySlotsProvider.overrideWithValue([match]),
            rentalsProvider.overrideWith((ref) => Stream.value(const [])),
            weekReservationsProvider.overrideWith(
              (ref, monday) => Stream.value(const []),
            ),
            playersProvider.overrideWith((ref) async => players),
            matchResultsProvider.overrideWith(
              (ref) => Stream.value({'mFed': result}),
            ),
          ],
          child: const MaterialApp(home: KioskShell()),
        ),
      );
      await tester.pumpAndSettle();

      // KioskShell's own status bar also summarises today's matches with
      // headerEventLabel — scope to the board's header so the tap lands on
      // the actual (tappable) BoardColumnHeader strip, not that status line.
      await tester.tap(
        find
            .descendant(
              of: find.byType(BoardColumnHeader),
              matching: find.textContaining('Naši'),
            )
            .first,
      );
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      // The score still renders non-interactively.
      final dialog = find.byType(AlertDialog);
      expect(
        find.descendant(of: dialog, matching: find.text('5 : 3')),
        findsOneWidget,
      );
      // No video control at all — the fallback trophy/block icon instead.
      expect(find.byIcon(Icons.play_circle_fill), findsNothing);
      expect(find.byIcon(Icons.videocam), findsNothing);

      // Tapping the match row never leaves the kiosk for the app's match
      // detail: it opens the kiosk's own Zápis modal (no players here, so
      // the note that there is no sheet yet).
      await tester.tap(
        find.descendant(of: dialog, matching: find.text('Naši – Soupeř')),
      );
      await tester.pumpAndSettle();

      expect(find.byType(MatchDetailScreen), findsNothing);
      expect(find.text('Zápis zápasu zatím není k dispozici.'), findsOneWidget);

      await finish(tester);
    },
  );

  group('side drawer (notices, matches, live match)', () {
    // Thursday 8 October 2026 (season 2026/27); its week is 5.–11. 10.
    final day = Day(2026, 10, 8);
    final nowAt = DateTime(2026, 10, 8, 12);

    Message notice(
      String id,
      String title, {
      bool show = true,
      String body = 'Sejdeme se v devět.',
    }) => Message(
      id: id,
      kind: MessageKind.notice,
      audience: MessageAudience.all,
      authorId: 'a',
      authorRole: MessageAuthorRole.admin,
      onDate: null,
      blockId: null,
      title: title,
      body: body,
      expiresAt: null,
      notify: true,
      showOnKiosk: show,
      createdAt: DateTime(2026, 9, int.tryParse(id) ?? 1),
      updatedAt: DateTime(2026, 9, 1),
    );
    PrioritySlot fed(String id, Day date, String home, {int hour = 14}) =>
        PrioritySlot(
          type: PrioritySlot.fallbackMatchType,
          id: id,
          date: date,
          startsAt: HourMinute(hour, 0),
          endsAt: HourMinute(hour + 3, 0),
          homeTeam: home,
          awayTeam: 'Soupeř',
          importKey: 'cka:$id',
        );
    MatchResult res(String id, String status, num home, num away) =>
        MatchResult.fromJson({
          'match_id': id,
          'status': status,
          'home_points': home,
          'away_points': away,
          'fetched_at': '2026-09-17T21:00:00+00:00',
        });
    MatchPlayerResult player(String matchId, String side, int pos) =>
        MatchPlayerResult(
          id: '$matchId-$side-$pos',
          matchId: matchId,
          side: side,
          position: pos,
          playerName: '${side == 'home' ? 'Dom' : 'Hos'} $pos',
          total: 400 + pos,
        );
    final lineup = [
      for (final side in ['home', 'away']) player('m', side, 1),
    ];

    Widget app({
      List<Message> notices = const [],
      List<PrioritySlot> slots = const [],
      Map<String, MatchResult> results = const {},
      bool drawerOpen = false,
      bool showNotices = true,
      bool headerNotices = true,
      bool showMatches = true,
      bool showUpcoming = true,
      bool liveMode = true,
      int weeksBack = 2,
      int weeksAhead = 1,
      int width = 440,
      int share = 40,
      int zapisPercent = 80,
      int noticeRotation = 12,
      int liveRotation = 12,
      bool panelEnabled = true,
      int pastDays = 0,
      int idleSeconds = 60,
      bool followBoard = true,
      bool Function()? socketOpen,
      KioskLiveLayout liveLayout = KioskLiveLayout.full,
      Stream<Map<String, MatchResult>>? resultsStream,
      Map<String, List<MatchPlayerResult>> lineups = const {},
    }) => ProviderScope(
      overrides: [
        settingsProvider.overrideWith(
          (ref) => Stream.value(
            ScheduleSettings(
              laneCount: settings.laneCount,
              trainingWeekdays: settings.trainingWeekdays,
              bookingHorizonDays: settings.bookingHorizonDays,
              maxActiveReservations: settings.maxActiveReservations,
              kioskDrawerOpen: drawerOpen,
              kioskNoticesMode: switch ((showNotices, headerNotices)) {
                (true, true) => KioskNoticesMode.both,
                (true, false) => KioskNoticesMode.drawer,
                (false, true) => KioskNoticesMode.header,
                (false, false) => KioskNoticesMode.off,
              },
              kioskShowMatches: showMatches,
              kioskShowUpcoming: showUpcoming,
              kioskLiveMode: liveMode,
              kioskWeeksBack: weeksBack,
              kioskWeeksAhead: weeksAhead,
              kioskDrawerWidth: width,
              kioskNoticesShare: share,
              kioskZapisPercent: zapisPercent,
              kioskNoticesRotationSeconds: noticeRotation,
              kioskLiveRotationSeconds: liveRotation,
              kioskPanelEnabled: panelEnabled,
              kioskPastDays: pastDays,
              kioskIdleSeconds: idleSeconds,
              kioskFollowBoard: followBoard,
              kioskLiveLayout: liveLayout,
            ),
          ),
        ),
        nowProvider.overrideWith((ref) => Stream.value(nowAt)),
        timeBlocksProvider.overrideWith((ref) => Stream.value(const [b1])),
        dayOverridesProvider.overrideWith((ref) => Stream.value(const [])),
        prioritySlotsProvider.overrideWithValue(slots),
        rentalsProvider.overrideWith((ref) => Stream.value(const [])),
        weekReservationsProvider.overrideWith(
          (ref, monday) => Stream.value(const []),
        ),
        playersProvider.overrideWith((ref) async => players),
        messagesProvider.overrideWith((ref) => Stream.value(notices)),
        kioskSocketOpenProvider.overrideWithValue(socketOpen ?? () => true),
        matchResultsProvider.overrideWith(
          (ref) => resultsStream ?? Stream.value(results),
        ),
        matchPlayerResultsProvider.overrideWith(
          (ref, id) => Stream.value(lineups[id] ?? const []),
        ),
      ],
      child: const MaterialApp(home: KioskShell()),
    );

    void fullHd(WidgetTester tester) {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    final openButton = find.byIcon(Icons.keyboard_double_arrow_left);
    final closeButton = find.byIcon(Icons.keyboard_double_arrow_right);
    // A notice title is in the status bar too; these tests are the drawer's.
    Finder drawerText(String t) =>
        find.descendant(of: find.byType(KioskDrawer), matching: find.text(t));

    testWidgets('closed by default: only the button shows, tap opens it, tap '
        'closes it', (tester) async {
      fullHd(tester);
      await tester.pumpWidget(app(notices: [notice('1', 'Brigáda')]));
      await tester.pumpAndSettle();

      expect(drawerText('Brigáda'), findsNothing);
      expect(openButton, findsOneWidget);
      expect(tester.getSize(find.byType(KioskDrawer)).width, 0);

      await tester.tap(openButton);
      await tester.pumpAndSettle();
      expect(drawerText('Brigáda'), findsOneWidget);
      expect(tester.getSize(find.byType(KioskDrawer)).width, 440);

      await tester.tap(closeButton);
      await tester.pumpAndSettle();
      expect(drawerText('Brigáda'), findsNothing);

      await finish(tester);
    });

    testWidgets('the day columns keep their width while the drawer slides', (
      tester,
    ) async {
      fullHd(tester);
      await tester.pumpWidget(app(notices: [notice('1', 'Brigáda')]));
      await tester.pumpAndSettle();
      double column() =>
          tester.getSize(find.byType(BoardColumnHeader).first).width;
      final closed = column();

      await tester.tap(openButton);
      // Mid-slide and settled: the same width throughout.
      await tester.pump(const Duration(milliseconds: 100));
      expect(column(), closed);
      await tester.pumpAndSettle();
      expect(column(), closed);

      await finish(tester);
    });

    testWidgets('after a minute without a touch it returns to its default', (
      tester,
    ) async {
      fullHd(tester);
      await tester.pumpWidget(app(notices: [notice('1', 'Brigáda')]));
      await tester.pumpAndSettle();
      await tester.tap(openButton);
      await tester.pumpAndSettle();
      expect(drawerText('Brigáda'), findsOneWidget);

      await tester.pump(const Duration(seconds: 61));
      await tester.pumpAndSettle();
      expect(drawerText('Brigáda'), findsNothing);

      await finish(tester);
    });

    testWidgets('the admin sets how long the kiosk idles before starting over',
        (tester) async {
      fullHd(tester);
      await tester.pumpWidget(
        app(notices: [notice('1', 'Brigáda')], idleSeconds: 120),
      );
      await tester.pumpAndSettle();
      await tester.tap(openButton);
      await tester.pumpAndSettle();
      expect(drawerText('Brigáda'), findsOneWidget);

      // A minute is not enough any more…
      await tester.pump(const Duration(seconds: 61));
      await tester.pumpAndSettle();
      expect(drawerText('Brigáda'), findsOneWidget);
      // …two are.
      await tester.pump(const Duration(seconds: 61));
      await tester.pumpAndSettle();
      expect(drawerText('Brigáda'), findsNothing);

      await finish(tester);
    });

    testWidgets('open by default when the admin says so; idle reopens it', (
      tester,
    ) async {
      fullHd(tester);
      await tester.pumpWidget(
        app(notices: [notice('1', 'Brigáda')], drawerOpen: true),
      );
      await tester.pumpAndSettle();
      expect(drawerText('Brigáda'), findsOneWidget);

      await tester.tap(closeButton);
      await tester.pumpAndSettle();
      expect(drawerText('Brigáda'), findsNothing);

      await tester.pump(const Duration(seconds: 61));
      await tester.pumpAndSettle();
      expect(drawerText('Brigáda'), findsOneWidget);

      await finish(tester);
    });

    testWidgets('the admin picks the drawer width', (tester) async {
      fullHd(tester);
      await tester.pumpWidget(
        app(notices: [notice('1', 'Brigáda')], drawerOpen: true, width: 600),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(KioskDrawer)).width, 600);

      await finish(tester);
    });

    testWidgets('a notice hidden from the kiosk is not shown', (tester) async {
      fullHd(tester);
      await tester.pumpWidget(
        app(
          notices: [notice('1', 'Vidět'), notice('2', 'Skryté', show: false)],
          drawerOpen: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(drawerText('Vidět'), findsOneWidget);
      expect(drawerText('Skryté'), findsNothing);

      await finish(tester);
    });

    testWidgets('the admin switches the notices and the matches off', (
      tester,
    ) async {
      fullHd(tester);
      final slots = [fed('next', day.addDays(1), 'Příští')];
      await tester.pumpWidget(
        app(
          notices: [notice('1', 'Brigáda')],
          slots: slots,
          drawerOpen: true,
          showNotices: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(drawerText('Brigáda'), findsNothing);
      expect(find.text('ZÁPASY'), findsOneWidget);
      await finish(tester);

      await tester.pumpWidget(
        app(
          notices: [notice('1', 'Brigáda')],
          slots: slots,
          drawerOpen: true,
          showMatches: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(drawerText('Brigáda'), findsOneWidget);
      expect(find.text('ZÁPASY'), findsNothing);

      await finish(tester);
    });

    testWidgets('the matches list covers the weeks the admin chose', (
      tester,
    ) async {
      fullHd(tester);
      final slots = [
        fed('b2', Day(2026, 9, 24), 'DvaZpět'),
        fed('b1', Day(2026, 10, 1), 'JedenZpět'),
        fed('cur', Day(2026, 10, 9), 'Tento'),
        fed('a1', Day(2026, 10, 15), 'JedenVpřed'),
        fed('a2', Day(2026, 10, 22), 'DvaVpřed'),
      ];
      Future<void> pumpWith({
        required int back,
        required int ahead,
        bool upcoming = true,
      }) async {
        await tester.pumpWidget(
          app(
            slots: slots,
            drawerOpen: true,
            weeksBack: back,
            weeksAhead: ahead,
            showUpcoming: upcoming,
          ),
        );
        await tester.pumpAndSettle();
        // The list opens on the current match; look at what lies above it.
        await tester.drag(
          find.descendant(
            of: find.byType(KioskDrawer),
            matching: find.byType(CustomScrollView),
          ),
          const Offset(0, 400),
        );
        await tester.pumpAndSettle();
      }

      bool shown(String team) =>
          find.textContaining(team).evaluate().any((e) {
            final w = e.widget;
            return w is Text || w is RichText;
          }) &&
          find
              .descendant(
                of: find.byType(KioskDrawer),
                matching: find.textContaining(team),
              )
              .evaluate()
              .isNotEmpty;

      await pumpWith(back: 2, ahead: 1);
      expect(shown('DvaZpět'), isTrue);
      expect(shown('Tento'), isTrue);
      expect(shown('JedenVpřed'), isTrue);
      expect(shown('DvaVpřed'), isFalse);
      await finish(tester);

      await pumpWith(back: 0, ahead: 0);
      expect(shown('Tento'), isTrue);
      expect(shown('JedenZpět'), isFalse);
      expect(shown('JedenVpřed'), isFalse);
      await finish(tester);

      await pumpWith(back: 2, ahead: 2, upcoming: false);
      expect(shown('JedenZpět'), isTrue);
      // Upcoming off: nothing after today, not even this week's match.
      expect(shown('Tento'), isFalse);
      expect(shown('JedenVpřed'), isFalse);

      await finish(tester);
    });

    testWidgets('„Zobrazit předchozí“ brings one more older week, '
        'without moving what is on screen', (tester) async {
      fullHd(tester);
      final slots = [
        fed('b2', Day(2026, 9, 24), 'DvaZpět'),
        fed('b1', Day(2026, 10, 1), 'JedenZpět'),
        fed('cur', Day(2026, 10, 9), 'Tento'),
      ];
      await tester.pumpWidget(
        app(slots: slots, drawerOpen: true, weeksBack: 0, weeksAhead: 0),
      );
      await tester.pumpAndSettle();
      // The list opens on the current match; the older ones lie above it.
      expect(find.text('Zobrazit další'), findsNothing);
      expect(find.textContaining('JedenZpět'), findsNothing);
      final list = find.descendant(
        of: find.byType(KioskDrawer),
        matching: find.byType(CustomScrollView),
      );
      await tester.drag(list, const Offset(0, 200));
      await tester.pumpAndSettle();
      Finder inDrawer(String t) => find.descendant(
        of: find.byType(KioskDrawer),
        matching: find.textContaining(t),
      );
      final before = tester.getTopLeft(inDrawer('Tento').first);

      await tester.tap(find.text('Zobrazit předchozí'));
      await tester.pumpAndSettle();
      expect(inDrawer('JedenZpět'), findsWidgets);
      expect(inDrawer('DvaZpět'), findsNothing);
      // What was on screen has not moved: no jump, no flicker.
      expect(tester.getTopLeft(inDrawer('Tento').first), before);

      await tester.drag(list, const Offset(0, 300));
      await tester.pumpAndSettle();
      final beforeSecond = tester.getTopLeft(inDrawer('Tento').first);
      await tester.tap(find.text('Zobrazit předchozí'));
      await tester.pumpAndSettle();
      expect(inDrawer('DvaZpět'), findsWidgets);
      expect(tester.getTopLeft(inDrawer('Tento').first), beforeSecond);
      // The season has nothing older: no button any more.
      expect(find.text('Zobrazit předchozí'), findsNothing);

      await finish(tester);
    });

    testWidgets('„Zobrazit předchozí“ skips weeks with no match', (
      tester,
    ) async {
      fullHd(tester);
      // Nothing for five weeks (a break), then two matches in one week.
      final slots = [
        fed('far1', Day(2026, 8, 25), 'PřesPrázdniny'),
        fed('far2', Day(2026, 8, 27), 'PřesPrázdniny2'),
        fed('cur', Day(2026, 10, 9), 'Tento'),
      ];
      await tester.pumpWidget(
        app(slots: slots, drawerOpen: true, weeksBack: 0, weeksAhead: 0),
      );
      await tester.pumpAndSettle();
      final list = find.descendant(
        of: find.byType(KioskDrawer),
        matching: find.byType(CustomScrollView),
      );
      await tester.drag(list, const Offset(0, 200));
      await tester.pumpAndSettle();
      expect(find.textContaining('PřesPrázdniny'), findsNothing);

      // One tap crosses the empty weeks and brings the whole next week.
      await tester.tap(find.text('Zobrazit předchozí'));
      await tester.pumpAndSettle();
      await tester.drag(list, const Offset(0, 400));
      await tester.pumpAndSettle();
      // Both matches of that week (the first name is a prefix of the second).
      expect(find.textContaining('PřesPrázdniny'), findsNWidgets(2));
      expect(find.textContaining('PřesPrázdniny2'), findsOneWidget);

      await finish(tester);
    });

    testWidgets('the list opens like Výsledky: the first coming match just '
        'below the bottom, played ones above; idle scrolls it back', (tester) async {
      fullHd(tester);
      final slots = [
        for (var i = 25; i >= 1; i--) fed('p$i', day.addDays(-i), 'Hráno$i'),
        fed('n1', day.addDays(1), 'Příští1'),
        fed('n2', day.addDays(2), 'Příští2'),
        fed('n3', day.addDays(3), 'Příští3'),
      ];
      final results = {
        for (var i = 1; i <= 25; i++) 'p$i': res('p$i', 'finished', 5, 3),
      };
      await tester.pumpWidget(
        app(
          slots: slots,
          results: results,
          drawerOpen: true,
          showNotices: false,
          weeksBack: 4,
          weeksAhead: 1,
        ),
      );
      await tester.pumpAndSettle();
      final list = find.descendant(
        of: find.byType(KioskDrawer),
        matching: find.byType(CustomScrollView),
      );
      final listBox = tester.getRect(list);
      Rect? rowOf(String t) {
        final f = find.descendant(
          of: find.byType(KioskDrawer),
          matching: find.textContaining(t),
        );
        return f.evaluate().isEmpty ? null : tester.getRect(f.first);
      }

      bool visible(String t) {
        final r = rowOf(t);
        return r != null && r.top >= listBox.top && r.bottom <= listBox.bottom;
      }

      // The first coming match is the first row below the edge…
      expect(visible('Příští1'), isFalse);
      // Exactly one viewport above the start of the coming ones.
      ScrollPosition position() => tester
          .state<ScrollableState>(
            find.descendant(of: list, matching: find.byType(Scrollable)),
          )
          .position;
      expect(position().pixels, -position().viewportDimension);
      // …with the played ones filling the list above it.
      expect(visible('Hráno1 '), isTrue);
      expect(visible('Hráno3 '), isTrue);

      // A visitor scrolls away; the idle reset brings the list back.
      await tester.drag(list, const Offset(0, 500));
      await tester.pumpAndSettle();
      expect(visible('Hráno1 '), isFalse);
      await tester.pump(const Duration(seconds: 61));
      await tester.pumpAndSettle();
      expect(visible('Hráno1 '), isTrue);
      expect(position().pixels, -position().viewportDimension);

      await finish(tester);
    });

    for (final follow in [true, false]) {
      testWidgets('the match list ${follow ? 'follows' : 'ignores'} the '
          'board scrolled to past days', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            slots: [
              fed('old', day.addDays(-13), 'DávnýZápas'),
              fed('cur', day.addDays(1), 'Tento'),
            ],
            results: {'old': res('old', 'finished', 5, 3)},
            drawerOpen: true,
            showNotices: false,
            weeksBack: 0,
            weeksAhead: 0,
            pastDays: 14,
            followBoard: follow,
          ),
        );
        await tester.pumpAndSettle();
        Finder inList(String t) => find.descendant(
          of: find.byType(KioskDrawer),
          matching: find.textContaining(t),
        );
        expect(inList('DávnýZápas'), findsNothing);

        // Drag the board two weeks back, to the match's day.
        for (var i = 0; i < 4 && find.textContaining('25.9.').evaluate().isEmpty; i++) {
          await tester.drag(
            find.byType(ScheduleDayColumn).first,
            const Offset(900, 0),
          );
          await tester.pumpAndSettle();
        }
        expect(find.textContaining('25.9.'), findsWidgets);

        if (follow) {
          final list = tester.getRect(
            find.descendant(
              of: find.byType(KioskDrawer),
              matching: find.byType(CustomScrollView),
            ),
          );
          final row = tester.getRect(inList('DávnýZápas').first);
          expect(row.top, greaterThanOrEqualTo(list.top - 1));
          expect(row.bottom, lessThanOrEqualTo(list.bottom + 1));
        } else {
          expect(inList('DávnýZápas'), findsNothing);
        }

        await finish(tester);
      });
    }

    testWidgets('a match being played takes the whole drawer, even closed by '
        'default, and reopens it after a minute', (tester) async {
      fullHd(tester);
      await tester.pumpWidget(
        app(
          notices: [notice('1', 'Brigáda')],
          slots: [fed('m', day, 'Hrají')],
          results: {'m': res('m', 'in_progress', 2, 1)},
          lineups: {'m': lineup},
        ),
      );
      await tester.pumpAndSettle();
      // Open although the default is closed; nothing but the live match.
      expect(find.text('PRÁVĚ SE HRAJE'), findsOneWidget);
      expect(drawerText('Brigáda'), findsNothing);
      expect(find.text('ZÁPASY'), findsNothing);

      // A visitor may close it; a minute later it is back.
      await tester.tap(closeButton);
      await tester.pumpAndSettle();
      expect(find.text('PRÁVĚ SE HRAJE'), findsNothing);
      await tester.pump(const Duration(seconds: 61));
      await tester.pumpAndSettle();
      expect(find.text('PRÁVĚ SE HRAJE'), findsOneWidget);

      await finish(tester);
    });

    testWidgets('no data, no live view: a status alone is not enough', (
      tester,
    ) async {
      fullHd(tester);
      await tester.pumpWidget(
        app(
          notices: [notice('1', 'Brigáda')],
          slots: [fed('m', day, 'Hrají')],
          results: {'m': res('m', 'in_progress', 2, 1)},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('PRÁVĚ SE HRAJE'), findsNothing);
      // The drawer rests closed, as the admin set it.
      expect(drawerText('Brigáda'), findsNothing);

      await finish(tester);
    });

    testWidgets('live mode off keeps the notices and the matches', (
      tester,
    ) async {
      fullHd(tester);
      await tester.pumpWidget(
        app(
          notices: [notice('1', 'Brigáda')],
          slots: [fed('m', day, 'Hrají')],
          results: {'m': res('m', 'in_progress', 2, 1)},
          lineups: {'m': lineup},
          liveMode: false,
          drawerOpen: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('PRÁVĚ SE HRAJE'), findsNothing);
      expect(drawerText('Brigáda'), findsOneWidget);

      await finish(tester);
    });

    testWidgets('several live matches take turns at the admin\'s speed', (
      tester,
    ) async {
      fullHd(tester);
      final second = [
        for (final side in ['home', 'away']) player('n', side, 1),
      ];
      await tester.pumpWidget(
        app(
          slots: [fed('m', day, 'Prvníci'), fed('n', day, 'Druzí', hour: 17)],
          results: {
            'm': res('m', 'in_progress', 2, 1),
            'n': res('n', 'in_progress', 1, 2),
          },
          lineups: {'m': lineup, 'n': second},
          liveRotation: 6,
        ),
      );
      await tester.pumpAndSettle();
      bool inDrawer(String t) => find
          .descendant(
            of: find.byType(KioskDrawer),
            matching: find.textContaining(t),
          )
          .evaluate()
          .isNotEmpty;
      expect(inDrawer('Prvníci'), isTrue);
      expect(inDrawer('Druzí'), isFalse);

      // Settling already ran the clock a few seconds; turn is 6 s.
      await tester.pump(const Duration(seconds: 2));
      expect(inDrawer('Druzí'), isFalse);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(inDrawer('Druzí'), isTrue);

      await finish(tester);
    });

    testWidgets('a notice that fits has no „Více“; a cut one has, and opens '
        'in a modal', (tester) async {
      fullHd(tester);
      await tester.pumpWidget(
        app(
          notices: [notice('1', 'Krátký', body: 'Ahoj.')],
          slots: [fed('next', day.addDays(1), 'Příští')],
          drawerOpen: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Více'), findsNothing);
      await finish(tester);

      await tester.pumpWidget(
        app(
          notices: [notice('1', 'Dlouhý', body: 'Dlouhý text oznamu. ' * 80)],
          slots: [fed('next', day.addDays(1), 'Příští')],
          drawerOpen: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Více'), findsOneWidget);
      await tester.tap(find.text('Více'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);

      await finish(tester);
    });

    testWidgets('notices taking turns never move the matches below', (
      tester,
    ) async {
      fullHd(tester);
      await tester.pumpWidget(
        app(
          notices: [
            notice('1', 'Krátký', body: 'Ahoj.'),
            notice('2', 'Dlouhý', body: 'Dlouhý text oznamu. ' * 80),
          ],
          slots: [fed('next', day.addDays(1), 'Příští')],
          drawerOpen: true,
        ),
      );
      await tester.pumpAndSettle();
      final before = tester.getTopLeft(find.text('ZÁPASY'));

      await tester.pump(const Duration(seconds: 13));
      await tester.pumpAndSettle();
      expect(drawerText('Krátký'), findsNothing);
      expect(tester.getTopLeft(find.text('ZÁPASY')), before);

      await finish(tester);
    });

    testWidgets('the admin sets the share of the notices', (tester) async {
      fullHd(tester);
      Future<double> matchesTop(int share) async {
        await tester.pumpWidget(
          app(
            notices: [notice('1', 'Brigáda')],
            slots: [fed('next', day.addDays(1), 'Příští')],
            drawerOpen: true,
            share: share,
          ),
        );
        await tester.pumpAndSettle();
        final top = tester.getTopLeft(find.text('ZÁPASY')).dy;
        await finish(tester);
        return top;
      }

      final small = await matchesTop(20);
      final big = await matchesTop(60);
      expect(big, greaterThan(small));
    });

    testWidgets('a finished match opens its Zápis in a modal of the chosen '
        'size, no ×, a tap outside closes it', (tester) async {
      fullHd(tester);
      await tester.pumpWidget(
        app(
          slots: [fed('m', day.addDays(-3), 'Domácí')],
          results: {'m': res('m', 'finished', 6, 2)},
          lineups: {'m': lineup},
          drawerOpen: true,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('6 : 2'));
      await tester.pumpAndSettle();
      expect(find.byType(LegacyScoreSheetPage), findsOneWidget);
      final sheet = tester.getSize(find.byType(LegacyScoreSheetPage));
      expect(sheet.width, closeTo(1920 * 0.8, 1));
      expect(sheet.height, closeTo(1080 * 0.8, 1));
      expect(find.byIcon(Icons.close), findsNothing);

      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(find.byType(LegacyScoreSheetPage), findsNothing);

      await finish(tester);
    });

    testWidgets('at 100 % the Zápis fills the screen and has a ×', (
      tester,
    ) async {
      fullHd(tester);
      await tester.pumpWidget(
        app(
          slots: [fed('m', day.addDays(-3), 'Domácí')],
          results: {'m': res('m', 'finished', 6, 2)},
          lineups: {'m': lineup},
          drawerOpen: true,
          zapisPercent: 100,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('6 : 2'));
      await tester.pumpAndSettle();
      final sheet = tester.getSize(find.byType(LegacyScoreSheetPage));
      expect(sheet, const Size(1920, 1080));
      expect(find.byIcon(Icons.close), findsOneWidget);
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(find.byType(LegacyScoreSheetPage), findsNothing);

      await finish(tester);
    });

    testWidgets('the idle reset closes the Zápis', (tester) async {
      fullHd(tester);
      await tester.pumpWidget(
        app(
          slots: [fed('m', day.addDays(-3), 'Domácí')],
          results: {'m': res('m', 'finished', 6, 2)},
          lineups: {'m': lineup},
          drawerOpen: true,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('6 : 2'));
      await tester.pumpAndSettle();
      expect(find.byType(LegacyScoreSheetPage), findsOneWidget);

      await tester.pump(const Duration(seconds: 61));
      await tester.pumpAndSettle();
      expect(find.byType(LegacyScoreSheetPage), findsNothing);

      await finish(tester);
    });

    testWidgets('a match without players says so instead of drawing a sheet', (
      tester,
    ) async {
      fullHd(tester);
      await tester.pumpWidget(
        app(
          slots: [fed('m', day.addDays(-3), 'Domácí')],
          results: {'m': res('m', 'finished', 6, 2)},
          drawerOpen: true,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('6 : 2'));
      await tester.pumpAndSettle();
      expect(find.byType(LegacyScoreSheetPage), findsNothing);
      expect(find.text('Zápis zápasu zatím není k dispozici.'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsNothing);

      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(find.text('Zápis zápasu zatím není k dispozici.'), findsNothing);

      await finish(tester);
    });

    testWidgets('a match without a score has no Zápis to open', (tester) async {
      fullHd(tester);
      await tester.pumpWidget(
        app(slots: [fed('next', day.addDays(1), 'Příští')], drawerOpen: true),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(KioskDrawer),
          matching: find.textContaining('Příští'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(LegacyScoreSheetPage), findsNothing);
      expect(find.text('Zápis zápasu zatím není k dispozici.'), findsNothing);

      await finish(tester);
    });

    testWidgets('with the panel switched off there is no drawer and no live '
        'view', (tester) async {
      fullHd(tester);
      await tester.pumpWidget(
        app(
          notices: [notice('1', 'Brigáda')],
          slots: [fed('m', day, 'Hrají')],
          results: {'m': res('m', 'in_progress', 2, 1)},
          lineups: {'m': lineup},
          panelEnabled: false,
          drawerOpen: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(openButton, findsNothing);
      expect(closeButton, findsNothing);
      expect(drawerText('Brigáda'), findsNothing);
      expect(find.text('PRÁVĚ SE HRAJE'), findsNothing);

      await finish(tester);
    });

    testWidgets('a swipe turns the notices, in both directions', (
      tester,
    ) async {
      fullHd(tester);
      await tester.pumpWidget(
        app(
          notices: [notice('1', 'První'), notice('2', 'Druhý')],
          drawerOpen: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(drawerText('První'), findsOneWidget);

      await tester.fling(drawerText('První'), const Offset(-300, 0), 1000);
      await tester.pumpAndSettle();
      expect(drawerText('Druhý'), findsOneWidget);
      expect(drawerText('První'), findsNothing);

      await tester.fling(drawerText('Druhý'), const Offset(300, 0), 1000);
      await tester.pumpAndSettle();
      expect(drawerText('První'), findsOneWidget);

      await finish(tester);
    });

    testWidgets('a whole notice is no link; only a cut one opens', (
      tester,
    ) async {
      fullHd(tester);
      await tester.pumpWidget(
        app(
          notices: [notice('1', 'Krátký', body: 'Ahoj.')],
          slots: [fed('next', day.addDays(1), 'Příští')],
          drawerOpen: true,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(drawerText('Krátký'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);

      await finish(tester);
    });

    testWidgets('a touch in the live view restarts the wait for the next '
        'match', (tester) async {
      fullHd(tester);
      final second = [
        for (final side in ['home', 'away']) player('n', side, 1),
      ];
      await tester.pumpWidget(
        app(
          slots: [fed('m', day, 'Prvníci'), fed('n', day, 'Druzí', hour: 17)],
          results: {
            'm': res('m', 'in_progress', 2, 1),
            'n': res('n', 'in_progress', 1, 2),
          },
          lineups: {'m': lineup, 'n': second},
          liveRotation: 10,
        ),
      );
      await tester.pumpAndSettle();
      bool inDrawer(String t) => find
          .descendant(
            of: find.byType(KioskDrawer),
            matching: find.textContaining(t),
          )
          .evaluate()
          .isNotEmpty;
      expect(inDrawer('Prvníci'), isTrue);
      // Touch every 6 s: the 10 s turn never comes.
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(seconds: 6));
        await tester.tap(find.text('PRÁVĚ SE HRAJE'));
      }
      await tester.pumpAndSettle();
      expect(inDrawer('Prvníci'), isTrue);
      expect(inDrawer('Druzí'), isFalse);

      await finish(tester);
    });

    testWidgets('the live scoreboard stays put while the duels scroll', (
      tester,
    ) async {
      fullHd(tester);
      tester.view.physicalSize = const Size(1920, 700);
      final many = [
        for (var pos = 1; pos <= 6; pos++)
          for (final side in ['home', 'away']) player('m', side, pos),
      ];
      await tester.pumpWidget(
        app(
          slots: [fed('m', day, 'Hrají')],
          results: {'m': res('m', 'in_progress', 2, 1)},
          lineups: {'m': many},
        ),
      );
      await tester.pumpAndSettle();
      final board = find.byType(MatchScoreboard);
      final top = tester.getTopLeft(board);
      await tester.drag(find.byType(DuelCard).first, const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(board), top);

      await finish(tester);
    });

    for (final layout in [KioskLiveLayout.compact, KioskLiveLayout.table]) {
      testWidgets('the ${layout.name} live view fits six duels without '
          'scrolling and opens one duel at a time', (tester) async {
        fullHd(tester);
        MatchPlayerResult played(String side, int pos) => MatchPlayerResult(
          id: 'm-$side-$pos',
          matchId: 'm',
          side: side,
          position: pos,
          playerName: '${side == 'home' ? 'Domácí' : 'Host'} Hráč$pos',
          total: 200 + pos,
          lanes: [
            for (var l = 1; l <= 4; l++)
              PlayerLane(lane: l, total: side == 'home' ? 50 + l : 48 + l),
          ],
        );
        await tester.pumpWidget(
          app(
            slots: [fed('m', day, 'Hrají')],
            results: {'m': res('m', 'in_progress', 3, 1)},
            lineups: {
              'm': [
                for (var pos = 1; pos <= 6; pos++)
                  for (final side in ['home', 'away']) played(side, pos),
              ],
            },
            liveLayout: layout,
          ),
        );
        await tester.pumpAndSettle();
        // No title, no duel card shown: the compact drawing.
        expect(find.text('PRÁVĚ SE HRAJE'), findsNothing);
        expect(find.byType(DuelCard).hitTestable(), findsNothing);
        // All six duels in view, without scrolling.
        final drawer = tester.getRect(find.byType(KioskDrawer));
        final last = find.textContaining('Hráč6').first;
        expect(tester.getRect(last).bottom, lessThan(drawer.bottom));

        // The folded duel's card stays in the tree (cross-fade), hidden:
        // only the visible ones count.
        final openCards = find.byType(DuelCard).hitTestable();
        // A tap opens a duel as the full card with its lane table. More
        // may be open while they fit; past that the first opened folds.
        expect(openCards, findsNothing);
        await tester.tap(find.textContaining('Hráč1').first);
        await tester.pumpAndSettle();
        expect(openCards, findsOneWidget);
        expect(find.text('Plné'), findsWidgets);
        await tester.tap(find.textContaining('Hráč2').first);
        await tester.pumpAndSettle();
        expect(openCards, findsNWidgets(2));
        // Each opening animates; the fit is measured once it has.
        Future<void> settle() async {
          for (var i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 320));
            await tester.pumpAndSettle();
          }
        }

        for (var pos = 3; pos <= 6; pos++) {
          await tester.tap(find.textContaining('Hráč$pos').first);
          await settle();
        }
        final scroll = tester
            .state<ScrollableState>(
              find.descendant(
                of: find.byType(KioskDrawer),
                matching: find.byType(Scrollable),
              ).last,
            )
            .position;
        // Never a scrollbar: the oldest opened ones folded back…
        expect(scroll.maxScrollExtent, 0);
        expect(openCards.evaluate().length, lessThan(6));
        // …and the last one tapped is open.
        expect(
          find.descendant(
            of: openCards,
            matching: find.textContaining('Hráč6'),
          ),
          findsWidgets,
        );
        // Hráč1, opened first, was the first to fold.
        expect(
          find.descendant(
            of: openCards,
            matching: find.textContaining('Hráč1'),
          ),
          findsNothing,
        );

        await finish(tester);
      });
    }

    for (final layout in KioskLiveLayout.values) {
      testWidgets('${layout.name}: a tap on the live score opens the Zápis', (
        tester,
      ) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            slots: [fed('m', day, 'Hrají')],
            results: {'m': res('m', 'in_progress', 2, 1)},
            lineups: {'m': lineup},
            liveLayout: layout,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find
              .descendant(
                of: find.byType(KioskDrawer),
                // The full scoreboard sets the points as separate digits.
                matching: layout == KioskLiveLayout.full
                    ? find.text('průběžně')
                    : find.text('2 : 1'),
              )
              .first,
        );
        await tester.pumpAndSettle();
        expect(find.byType(LegacyScoreSheetPage), findsOneWidget);

        await finish(tester);
      });
    }

    testWidgets('a tap on the dots locks the match until it ends', (
      tester,
    ) async {
      fullHd(tester);
      final second = [
        for (final side in ['home', 'away']) player('n', side, 1),
      ];
      final results = StreamController<Map<String, MatchResult>>();
      addTearDown(results.close);
      await tester.pumpWidget(
        app(
          slots: [fed('m', day, 'Prvníci'), fed('n', day, 'Druzí', hour: 17)],
          resultsStream: results.stream,
          lineups: {'m': lineup, 'n': second},
          liveRotation: 6,
        ),
      );
      results.add({
        'm': res('m', 'in_progress', 2, 1),
        'n': res('n', 'in_progress', 1, 2),
      });
      await tester.pumpAndSettle();
      bool inDrawer(String t) => find
          .descendant(
            of: find.byType(KioskDrawer),
            matching: find.textContaining(t),
          )
          .evaluate()
          .isNotEmpty;
      expect(inDrawer('Prvníci'), isTrue);

      await tester.tap(find.byIcon(Icons.lock_open));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.lock), findsOneWidget);
      // Turns go by; the locked match stays.
      await tester.pump(const Duration(seconds: 20));
      await tester.pumpAndSettle();
      expect(inDrawer('Prvníci'), isTrue);
      expect(inDrawer('Druzí'), isFalse);

      // It ends: the lock goes with it, the other match is shown.
      results.add({
        'm': res('m', 'finished', 5, 3),
        'n': res('n', 'in_progress', 1, 2),
      });
      await tester.pumpAndSettle();
      expect(inDrawer('Druzí'), isTrue);

      await finish(tester);
    });

    testWidgets('a swipe turns the live matches', (tester) async {
      fullHd(tester);
      final second = [
        for (final side in ['home', 'away']) player('n', side, 1),
      ];
      await tester.pumpWidget(
        app(
          slots: [fed('m', day, 'Prvníci'), fed('n', day, 'Druzí', hour: 17)],
          results: {
            'm': res('m', 'in_progress', 2, 1),
            'n': res('n', 'in_progress', 1, 2),
          },
          lineups: {'m': lineup, 'n': second},
        ),
      );
      await tester.pumpAndSettle();
      bool inDrawer(String t) => find
          .descendant(
            of: find.byType(KioskDrawer),
            matching: find.textContaining(t),
          )
          .evaluate()
          .isNotEmpty;
      expect(inDrawer('Prvníci'), isTrue);

      await tester.fling(
        find.text('PRÁVĚ SE HRAJE'),
        const Offset(-300, 0),
        1000,
      );
      await tester.pumpAndSettle();
      expect(inDrawer('Druzí'), isTrue);
      expect(inDrawer('Prvníci'), isFalse);

      await finish(tester);
    });

    testWidgets('the board looks back as far as the admin allows', (
      tester,
    ) async {
      fullHd(tester);
      Future<bool> canReach(int pastDays) async {
        await tester.pumpWidget(app(pastDays: pastDays));
        await tester.pumpAndSettle();
        // The board opens on today, whatever lies before it.
        expect(find.text('DNES · čt 8.10.'), findsOneWidget);
        // Two days back is Tuesday 6 October; drag the board that way.
        await tester.drag(find.byType(ListView).last, const Offset(900, 0));
        await tester.pumpAndSettle();
        final found = find.text('út 6.10.').evaluate().isNotEmpty;
        await finish(tester);
        return found;
      }

      expect(await canReach(0), isFalse);
      expect(await canReach(3), isTrue);
    });

    testWidgets('a finished match of the board opens its Zápis, from its band '
        'and from the day header', (tester) async {
      fullHd(tester);
      final slots = [fed('m', day, 'Domácí')];
      final results = {'m': res('m', 'finished', 6, 2)};
      await tester.pumpWidget(
        app(slots: slots, results: results, lineups: {'m': lineup}),
      );
      await tester.pumpAndSettle();

      // The band in the grid.
      await tester.tap(
        find.descendant(
          of: find.byType(CalendarEventBand),
          matching: find.textContaining('Domácí'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(LegacyScoreSheetPage), findsOneWidget);
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(find.byType(LegacyScoreSheetPage), findsNothing);

      // The day header: its list first, then the match in it.
      await tester.tap(
        find
            .descendant(
              of: find.byType(BoardColumnHeader),
              matching: find.textContaining('Domácí'),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('6 : 2'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(LegacyScoreSheetPage), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);

      await finish(tester);
    });

    testWidgets('a match without a score does nothing when tapped on the '
        'board', (tester) async {
      fullHd(tester);
      await tester.pumpWidget(app(slots: [fed('m', day, 'Domácí')]));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(CalendarEventBand),
          matching: find.textContaining('Domácí'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(LegacyScoreSheetPage), findsNothing);
      expect(find.text('Zápis zápasu zatím není k dispozici.'), findsNothing);

      await finish(tester);
    });

    testWidgets('a home match has the house image, an away match none', (
      tester,
    ) async {
      fullHd(tester);
      final away = PrioritySlot(
        type: PrioritySlot.fallbackMatchType,
        id: 'a',
        date: day.addDays(2),
        startsAt: const HourMinute(14, 0),
        endsAt: const HourMinute(17, 0),
        homeTeam: 'Hosté',
        awayTeam: 'Soupeř',
        isAway: true,
        importKey: 'cka:a',
      );
      await tester.pumpWidget(
        app(
          slots: [fed('m', day.addDays(1), 'Domácí'), away],
          drawerOpen: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(KioskDrawer),
          matching: find.byType(Image),
        ),
        findsOneWidget,
      );

      await finish(tester);
    });

    testWidgets('the status bar shows one notice title at a time, in turn',
        (tester) async {
      fullHd(tester);
      await tester.pumpWidget(
        app(
          notices: [
            notice('1', 'Brigáda'),
            notice('2', 'Skryté', show: false),
            notice('3', 'Zámek'),
          ],
          noticeRotation: 6,
        ),
      );
      await tester.pumpAndSettle();
      final bar = find.byType(KioskHeadline);
      Finder inBar(String t) => find.descendant(of: bar, matching: find.text(t));
      expect(inBar('Brigáda'), findsOneWidget);
      expect(inBar('1/2'), findsOneWidget);
      expect(find.textContaining('Skryté'), findsNothing);
      // Left of „Rezervovat“.
      expect(
        tester.getCenter(bar).dx,
        lessThan(tester.getCenter(find.text('Rezervovat')).dx),
      );

      // Within one turn (settling already ran part of the clock) it fades
      // to the next.
      for (var i = 0; i < 7 && inBar('Zámek').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(milliseconds: 700));
      }
      expect(inBar('Zámek'), findsOneWidget);
      expect(inBar('Brigáda'), findsNothing);

      // A tap reads the notice in full.
      await tester.tap(inBar('Zámek'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);

      await finish(tester);
    });

    testWidgets('notices only in the drawer: no headline in the status bar', (
      tester,
    ) async {
      fullHd(tester);
      await tester.pumpWidget(
        app(notices: [notice('1', 'Brigáda')], headerNotices: false),
      );
      await tester.pumpAndSettle();
      expect(find.byType(KioskHeadline), findsNothing);

      await finish(tester);
    });

    testWidgets('a match of today in the status bar opens its Zápis once it '
        'is being played or done', (tester) async {
      fullHd(tester);
      await tester.pumpWidget(
        app(
          slots: [
            fed('m', day, 'Hrají', hour: 9),
            fed('n', day, 'Později', hour: 18),
          ],
          results: {'m': res('m', 'in_progress', 2, 1)},
          lineups: {'m': lineup},
          liveMode: false,
        ),
      );
      await tester.pumpAndSettle();
      Finder inBar(String t) => find.descendant(
        of: find.byType(Wrap),
        matching: find.textContaining(t),
      );
      // Not started yet: nothing to open.
      await tester.tap(inBar('Později'));
      await tester.pumpAndSettle();
      expect(find.byType(LegacyScoreSheetPage), findsNothing);
      // Being played: its Zápis.
      await tester.tap(inBar('Hrají'));
      await tester.pumpAndSettle();
      expect(find.byType(LegacyScoreSheetPage), findsOneWidget);

      await finish(tester);
    });

    testWidgets('no notice, no headline', (tester) async {
      fullHd(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.byType(KioskHeadline), findsNothing);

      await finish(tester);
    });

    testWidgets('a thin bar runs out in the last ten seconds before the idle '
        'reset — only after a touch', (tester) async {
      fullHd(tester);
      await tester.pumpWidget(app(notices: [notice('1', 'Brigáda')]));
      await tester.pumpAndSettle();
      Finder bar() => find.byWidgetPredicate(
        (w) => w is FractionallySizedBox && w.child is ColoredBox,
      );
      // Untouched: nothing to reset, no bar ever.
      await tester.pump(const Duration(seconds: 55));
      await tester.pump(const Duration(milliseconds: 100));
      expect(bar(), findsNothing);

      await tester.tap(openButton);
      await tester.pumpAndSettle();
      // (Settling ran the clock a little: the drawer's slide, the button's
      // breath.)
      await tester.pump(const Duration(seconds: 44));
      await tester.pump(const Duration(milliseconds: 100));
      expect(bar(), findsNothing);
      await tester.pump(const Duration(seconds: 6));
      await tester.pump(const Duration(milliseconds: 100));
      expect(bar(), findsOneWidget);
      expect(
        tester.widget<FractionallySizedBox>(bar()).widthFactor,
        lessThan(1),
      );
      // A touch puts it away.
      await tester.tap(find.text('Brigáda').last);
      await tester.pump(const Duration(milliseconds: 100));
      expect(bar(), findsNothing);

      await finish(tester);
    });

    testWidgets('a connection lost for a while is said; a blip is not', (
      tester,
    ) async {
      fullHd(tester);
      var open = true;
      await tester.pumpWidget(app(socketOpen: () => open));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.cloud_off), findsNothing);

      open = false;
      // A reconnect's moment: still quiet.
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.cloud_off), findsNothing);
      // Down for good: the strip.
      await tester.pump(const Duration(seconds: 20));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.cloud_off), findsOneWidget);
      expect(find.textContaining('bez spojení'), findsOneWidget);

      open = true;
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.cloud_off), findsNothing);

      await finish(tester);
    });

    testWidgets('an alley with nothing to show gets no drawer', (tester) async {
      fullHd(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(openButton, findsNothing);
      expect(closeButton, findsNothing);

      await finish(tester);
    });
  });
}

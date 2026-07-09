import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/theme.dart';
import 'package:rezervator/core/ui.dart' show today;
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/kiosk/kiosk_board_view.dart';
import 'package:rezervator/features/kiosk/kiosk_shell.dart';

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
  ///
  /// [theme] defaults to Flutter's own default (unspecified, as every
  /// pre-existing test here relied on) — pass an explicit light theme to
  /// reproduce the real app's actual light/dark split (see main.dart's
  /// `theme: buildTheme(Brightness.light)`) for tests that care whether the
  /// kiosk correctly stays dark regardless of the ambient app theme.
  Widget kioskApp({
    List<Match> matches = const [],
    List<Reservation> reservations = const [],
    List<PlayerName>? roster,
    ThemeData? theme,
    bool kioskDark = true,
  }) {
    final effectiveRoster = roster ?? players;
    final effSettings = ScheduleSettings(
      laneCount: settings.laneCount,
      trainingWeekdays: settings.trainingWeekdays,
      bookingHorizonDays: settings.bookingHorizonDays,
      maxActiveReservations: settings.maxActiveReservations,
      kioskDark: kioskDark,
    );
    return ProviderScope(
      overrides: [
        settingsProvider.overrideWith((ref) => Stream.value(effSettings)),
        timeBlocksProvider.overrideWith((ref) => Stream.value(const [b1])),
        dayOverridesProvider.overrideWith((ref) => Stream.value(const [])),
        matchesProvider.overrideWith((ref) => Stream.value(matches)),
        rentalsProvider.overrideWith((ref) => Stream.value(const [])),
        weekReservationsProvider.overrideWith(
          (ref, monday) => Stream.value(reservations),
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
    final columnWidth = tester.getSize(find.byType(BoardColumnHeader).first).width;
    await tester.drag(find.byType(ListView), Offset(-columnWidth, 0));
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
      final columnWidth = tester.getSize(find.byType(BoardColumnHeader).first).width;
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
        await tester.drag(find.byType(ListView), Offset(-columnWidth, 0));
        await tester.pumpAndSettle();
        collect();
      }
      // Every one of today's next 6 days was visited (the board's 7
      // originally-visible-without-scroll columns, spec §1)…
      expect(seenDates.containsAll({for (var i = 0; i < 7; i++) t.addDays(i)}), isTrue);
      // …and the ListView's look-ahead cache may have also mounted columns
      // further out, but never one before today — "days from DNES", never
      // the past (unlike the old week view, which always started on
      // Monday regardless of today).
      expect(seenDates.every((d) => !d.isBefore(t)), isTrue);

      await finish(tester);
    },
  );

  testWidgets(
    'g: NamePicker renders dark even when the app theme is light',
    (tester) async {
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
    },
  );

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
        club: '',
        nick: 'Zdenda',
      );
      const withoutNick = PlayerName(
        id: 'nonick1',
        displayName: 'Bořivoj Novotný',
        club: '',
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
    'i: a block overlapping only the prep window shows the 🛠 cell; the '
    'block overlapping the real match window shows the 🏆 cell with the '
    'match title',
    (tester) async {
      // Two adjacent blocks: bPrep (20:00-21:00) and bMatch (21:00-22:00).
      // A match starting at 21:00 with 60 min prep blocks [20:00,22:00):
      // bPrep overlaps only the prep window (isPrep=true → 🛠), bMatch
      // overlaps the real [21:00,22:00) match window (isPrep=false → 🏆).
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
      final match = Match(
        id: 'm1',
        date: t,
        startsAt: const HourMinute(21, 0),
        endsAt: const HourMinute(22, 0),
        homeTeam: '',
        awayTeam: 'KK Slavoj',
        prepMinutes: 60,
        description: '',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith((ref) => Stream.value(settings)),
            timeBlocksProvider
                .overrideWith((ref) => Stream.value(const [bPrep, bMatch])),
            dayOverridesProvider.overrideWith((ref) => Stream.value(const [])),
            matchesProvider.overrideWith((ref) => Stream.value([match])),
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

      expect(find.text('🛠 Příprava drah'), findsOneWidget);
      // The match-cell body text is specifically
      // '🏆 {title}\n{start}–{end}' (_matchCell) — distinct from the header
      // banner's '🏆 {title}' (BoardColumnHeader, joined with ' · ' and no
      // times), so matching on the newline-joined form isolates the block
      // cell instead of also catching the header.
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
    'j: a fully closed day renders the dimmed ✕ zavřeno column and still '
    'shows that day\'s match cell',
    (tester) async {
      final match = Match(
        id: 'm2',
        date: t,
        startsAt: const HourMinute(23, 0),
        endsAt: const HourMinute(23, 30),
        homeTeam: '',
        awayTeam: 'TJ Sokol',
        prepMinutes: 0,
        description: '',
      );
      // A second rail block the match never touches — b1 (22:58-23:59) fully
      // covers the match window, so its row-group renders the 🏆 cell;
      // bOther (08:00-09:00) has no overlap at all, so its row-group falls
      // through to the plain dimmed "✕ zavřeno" filler. A closed day with
      // only one rail block that happens to be entirely covered by a match
      // would never show the filler text at all (see _closedCell), so this
      // asserts both cells actually coexist on the one closed column.
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
            timeBlocksProvider
                .overrideWith((ref) => Stream.value(const [b1, bOther])),
            dayOverridesProvider.overrideWith(
              (ref) => Stream.value(
                [DayOverride(date: t, closed: true, reason: '')],
              ),
            ),
            matchesProvider.overrideWith((ref) => Stream.value([match])),
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

      expect(find.textContaining('✕ zavřeno'), findsOneWidget);
      // Same disambiguation as test i: the closed-column match cell renders
      // '🏆 {title}\n{start}–{end}' (_matchCell via _closedCell), distinct
      // from the header banner's plain '🏆 {title}'.
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
    'renders faint time-slot gridlines between row-groups',
    (tester) async {
      // Two rail blocks (unlike kioskApp()'s single b1) so at least one
      // non-last row-group boundary exists for a gridline to sit on.
      const bMorning = TimeBlock(
        id: 'bMorning',
        startsAt: HourMinute(8, 0),
        endsAt: HourMinute(9, 0),
        position: 0,
        active: true,
      );
      const bEvening = TimeBlock(
        id: 'bEvening',
        startsAt: HourMinute(20, 0),
        endsAt: HourMinute(21, 0),
        position: 1,
        active: true,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith((ref) => Stream.value(settings)),
            timeBlocksProvider
                .overrideWith((ref) => Stream.value(const [bMorning, bEvening])),
            dayOverridesProvider.overrideWith((ref) => Stream.value(const [])),
            matchesProvider.overrideWith((ref) => Stream.value(const [])),
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

      final scheme =
          Theme.of(tester.element(find.byType(KioskBoardView))).colorScheme;
      final gridlineContainers = tester
          .widgetList<Container>(find.byType(Container))
          .where((c) {
            final decoration = c.decoration;
            if (decoration is! BoxDecoration) return false;
            final border = decoration.border;
            if (border is! Border) return false;
            return border.bottom.color ==
                scheme.outlineVariant.withValues(alpha: 0.25);
          });
      expect(gridlineContainers, isNotEmpty);

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
    'l: uneven-duration blocks render proportional row heights, and rail '
    'labels stay aligned with column cells',
    (tester) async {
      // A 30-min block followed by a 60-min block. Task 2: each row-group's
      // height scales with the block's duration (via blockGroupHeight), so
      // the 30-min block's row-group is strictly shorter than the 60-min
      // one, yet the rail label and the column cell for a given block still
      // share the exact same vertical offset (one grid across rail + columns).
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
            timeBlocksProvider
                .overrideWith((ref) => Stream.value(const [bShort, bLong])),
            dayOverridesProvider.overrideWith((ref) => Stream.value(const [])),
            matchesProvider.overrideWith((ref) => Stream.value(const [])),
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

      // The rail renders one label Container per block, each sized to that
      // block's row-group height; the innermost Container ancestor of each
      // label Text is exactly that height-sized cell.
      Size railCellFor(String label) {
        final container = find
            .ancestor(
              of: find.text(label),
              matching: find.byType(Container),
            )
            .first;
        return tester.getSize(container);
      }

      final shortSize = railCellFor(bShort.label);
      final longSize = railCellFor(bLong.label);

      // Proportional: the 30-min block's row-group is strictly shorter than
      // the 60-min block's (half the per-lane height, same lane count).
      expect(shortSize.height, lessThan(longSize.height));

      // Rail vs column alignment: the today column (index 0) is on screen —
      // its first block cell must start at the same y as the rail's first
      // label cell, and both blocks' cell tops must line up rail-to-column.
      final railShortTop = tester
          .getTopLeft(
            find
                .ancestor(
                  of: find.text(bShort.label),
                  matching: find.byType(Container),
                )
                .first,
          )
          .dy;
      final railLongTop = tester
          .getTopLeft(
            find
                .ancestor(
                  of: find.text(bLong.label),
                  matching: find.byType(Container),
                )
                .first,
          )
          .dy;
      // The gap between the two rail labels equals the first (short) block's
      // row-group height — so the second block sits proportionally lower than
      // it would under equal-height rows.
      expect(railLongTop - railShortTop, closeTo(shortSize.height, 0.5));

      await finish(tester);
    },
  );

  // ── Hybrid board (Task 3): swimline for standard days, own-times column
  // for shifted days (spec §2/§3). The default active swimline is bDef
  // (16:00–17:00); a shifted day carries an override whose block set differs
  // (bShift 17:30–18:30), so it must render its own strip with per-cell times.
  const bDef = TimeBlock(
    id: 'bDef',
    startsAt: HourMinute(16, 0),
    endsAt: HourMinute(17, 0),
    position: 0,
    active: true,
  );
  // Inactive so it's NOT part of the default swimline set, but still resolvable
  // by id for a day override — exactly how a slot-shift override references its
  // own special blocks.
  const bShift = TimeBlock(
    id: 'bShift',
    startsAt: HourMinute(17, 30),
    endsAt: HourMinute(18, 30),
    position: 1,
    active: false,
  );
  // A second shift block so a shifted day can carry TWO short blocks whose raw
  // blockGroupHeight sum differs from the single-60min-block swimline — this
  // makes the normalization scale (strip fills swimlineTotal exactly) actually
  // load-bearing in the alignment test, not a coincidence of equal heights.
  const bShift2 = TimeBlock(
    id: 'bShift2',
    startsAt: HourMinute(18, 30),
    endsAt: HourMinute(19, 0),
    position: 2,
    active: false,
  );

  Widget hybridApp({required List<DayOverride> overrides}) => ProviderScope(
        overrides: [
          settingsProvider.overrideWith((ref) => Stream.value(settings)),
          timeBlocksProvider.overrideWith(
              (ref) => Stream.value(const [bDef, bShift, bShift2])),
          dayOverridesProvider.overrideWith((ref) => Stream.value(overrides)),
          matchesProvider.overrideWith((ref) => Stream.value(const [])),
          rentalsProvider.overrideWith((ref) => Stream.value(const [])),
          weekReservationsProvider
              .overrideWith((ref, monday) => Stream.value(const [])),
          playersProvider.overrideWith((ref) async => players),
        ],
        child: const MaterialApp(home: KioskShell()),
      );

  testWidgets(
    'm: a standard day renders swimline cells with NO per-cell time label',
    (tester) async {
      // No overrides → every day is standard (block set == default {bDef}).
      await tester.pumpWidget(hybridApp(overrides: const []));
      await tester.pumpAndSettle();

      // The rail shows the block's time as its label (bDef.label = 16:00–17:00);
      // a standard column's cells must NOT repeat that time inside the cell —
      // the only 16:00–17:00 text on screen is the single rail label. If any
      // standard column wrongly rendered per-cell times, this would find more.
      expect(find.text('${bDef.startsAt.display()}–${bDef.endsAt.display()}'),
          findsOneWidget);

      await finish(tester);
    },
  );

  testWidgets(
    'n: a shifted day renders an own-times column whose free ＋ cells DO show '
    'a per-cell time label',
    (tester) async {
      // Shift only `tomorrow`: an override whose block_ids = [bShift] differs
      // from the default active set {bDef} → shifted day → own-times strip.
      await tester.pumpWidget(hybridApp(
        overrides: [
          DayOverride(
            date: tomorrow,
            closed: false,
            reason: '',
            blockIds: const ['bShift'],
          ),
        ],
      ));
      await tester.pumpAndSettle();

      // Select a player so free lanes render the tappable ＋ (only bookable
      // free slots draw ＋; a display-only board leaves them blank).
      await tester.tap(find.text('Rezervovat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(anna.displayName));
      await tester.pumpAndSettle();

      // Scroll one column over to bring `tomorrow` (index 1) into view — the
      // horizontal ListView only builds columns near the viewport.
      final columnWidth =
          tester.getSize(find.byType(BoardColumnHeader).first).width;
      await tester.drag(find.byType(ListView), Offset(-columnWidth, 0));
      await tester.pumpAndSettle();

      // The shifted column labels every cell with its OWN time — including the
      // free ＋ cell — so the bShift time (17:30–18:30), which is NOT a rail
      // label (the rail only carries the default bDef 16:00–17:00), appears in
      // the cell. Its presence proves the own-times path rendered per-cell.
      expect(
        find.text('${bShift.startsAt.display()}–${bShift.endsAt.display()}'),
        findsWidgets,
      );
      // …and the free cell it labels really is a bookable ＋ (own-times free
      // cell = time + ＋, spec §3).
      expect(find.text('＋'), findsWidgets);
      // The shifted header carries the ⚡ custom marker before the date.
      expect(find.textContaining('⚡'), findsOneWidget);

      await finish(tester);
    },
  );

  testWidgets(
    'o: a shifted column\'s total height equals the swimline total (alignment)',
    (tester) async {
      // A shifted day's own strip must exactly fill the same vertical extent as
      // a standard swimline column so columns stay top-and-bottom aligned. With
      // `tomorrow` shifted and the rest standard, the today column (standard,
      // index 0) and the tomorrow column (shifted, index 1) must be the same
      // pixel height below the header. The shifted day carries TWO blocks
      // (bShift 60min + bShift2 30min) whose raw height sum ≠ the single-block
      // swimline, so equal totals here can only come from the normalization.
      await tester.pumpWidget(hybridApp(
        overrides: [
          DayOverride(
            date: tomorrow,
            closed: false,
            reason: '',
            blockIds: const ['bShift', 'bShift2'],
          ),
        ],
      ));
      await tester.pumpAndSettle();

      double columnBodyHeight(int index) {
        // The BoardColumnHeader's parent Column holds header + cells; the whole
        // _DayColumn's rendered height is the header height plus the cell
        // strip. Measure the day column via its header's sibling extent by
        // taking the enclosing SizedBox width-constrained column.
        final headers = tester
            .widgetList<BoardColumnHeader>(find.byType(BoardColumnHeader))
            .toList();
        final header = headers[index];
        final headerElem = find.byWidget(header);
        // The nearest ancestor Column is the _DayColumn body; its height is the
        // full column height (header + strip).
        final colFinder =
            find.ancestor(of: headerElem, matching: find.byType(Column)).first;
        return tester.getSize(colFinder).height;
      }

      final columnWidth =
          tester.getSize(find.byType(BoardColumnHeader).first).width;
      // Both today (0, standard) and tomorrow (1, shifted) must be mounted; a
      // small drag keeps index 0 in the cache while bringing 1 on-screen.
      await tester.drag(find.byType(ListView), Offset(-columnWidth * 0.5, 0));
      await tester.pumpAndSettle();

      final standardHeight = columnBodyHeight(0);
      final shiftedHeight = columnBodyHeight(1);
      expect(shiftedHeight, closeTo(standardHeight, 0.5));

      await finish(tester);
    },
  );
}

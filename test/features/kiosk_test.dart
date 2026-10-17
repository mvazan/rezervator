import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/theme.dart';
import 'package:rezervator/core/ui.dart'
    show dayFull, dayLabel, initialsOf, today;
import 'package:rezervator/core/widgets/emoji_text.dart';
import 'package:rezervator/core/widgets/gradient_button.dart';
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/duties.dart'
    show KioskDutyEntry, dutyRangeLabel;
import 'package:rezervator/domain/kiosk_header.dart';
import 'package:rezervator/domain/kiosk_layout.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/weather.dart';
import 'package:rezervator/features/clubhouse/match_detail_screen.dart';
import 'package:rezervator/features/clubhouse/widgets/duel_card.dart';
import 'package:rezervator/features/clubhouse/widgets/legacy_score_sheet.dart';
import 'package:rezervator/features/clubhouse/widgets/match_scoreboard.dart';
import 'package:rezervator/features/clubhouse/widgets/match_video_icon.dart';
import 'package:rezervator/features/kiosk/kiosk_board_view.dart';
import 'package:rezervator/features/schedule/widgets/slot_tile.dart';
import 'package:rezervator/features/kiosk/kiosk_connection.dart';
import 'package:rezervator/features/kiosk/kiosk_day_info.dart';
import 'package:rezervator/features/kiosk/kiosk_display.dart';
import 'package:rezervator/features/kiosk/kiosk_duty.dart';
import 'package:rezervator/features/kiosk/kiosk_header_module.dart';
import 'package:rezervator/features/kiosk/kiosk_info_panel.dart';
import 'package:rezervator/features/kiosk/kiosk_shell.dart';
import 'package:rezervator/features/kiosk/kiosk_stream_window.dart';
import 'package:rezervator/features/kiosk/kiosk_headline.dart';
import 'package:rezervator/features/kiosk/kiosk_new_chip.dart';
import 'package:rezervator/features/kiosk/kiosk_warning.dart';
import 'package:rezervator/features/kiosk/name_picker.dart';
import 'package:rezervator/features/schedule/widgets/calendar_board.dart';
import 'package:rezervator/features/schedule/widgets/schedule_day_column.dart';
import '../support/band_label_finders.dart';
import '../support/emoji_finders.dart';

/// Stands in for the display: records the shell's holds and releases, in
/// order.
class _DisplayRecorder extends KioskDisplay {
  final log = <String>[];

  @override
  Future<void> hold() async => log.add('hold');

  @override
  Future<void> release() async => log.add('release');

  @override
  void lowRes(bool on) => log.add('lowRes:$on');

  @override
  void forgetLowRes() => log.add('forgetLowRes');
}

void main() {
  // The panel buttons breathe on the wall clock's beat
  // (KioskDrawerButton.untilBreath): on the real clock a test's breath
  // would start at another moment every run, and a pumpAndSettle that
  // catches one runs seconds longer — a turn or a timer measured across it
  // passed or failed by the time of day. A clock that stands still gives
  // every test the same beat; the breathing tests hand in a moving one.
  setUp(
    () => KioskDrawerButton.clock = () =>
        DateTime.fromMillisecondsSinceEpoch(4200 * 400000000 + 100,
            isUtc: true),
  );
  tearDown(() => KioskDrawerButton.clock = DateTime.now);

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
    KioskDisplay? display,
    bool kioskLowRes = false,
    String? kioskPickerNote,
    int kioskIdleSeconds = 60,
    int kioskWarningFontSize = 22,
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
      kioskLowRes: kioskLowRes,
      kioskPickerNote: kioskPickerNote,
      kioskIdleSeconds: kioskIdleSeconds,
      kioskWarningFontSize: kioskWarningFontSize,
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
        if (display != null) kioskDisplayProvider.overrideWithValue(display),
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
    'a: shell shows status bar with „Rezervace tréninku“ and no '
    'logout/admin icons',
    (tester) async {
      await tester.pumpWidget(kioskApp());
      await tester.pumpAndSettle();

      expect(find.text(kioskReserveLabel), findsOneWidget);
      expect(find.byIcon(Icons.logout), findsNothing);
      expect(find.byIcon(Icons.admin_panel_settings), findsNothing);
      expect(find.byType(AppBar), findsNothing);

      await finish(tester);
    },
  );

  testWidgets('the shell holds the display while it is up — screen on and '
      'bars hidden on the way in, given back on the way out', (tester) async {
    final display = _DisplayRecorder();
    await tester.pumpWidget(kioskApp(display: display));
    await tester.pumpAndSettle();
    // The settings arrive after the first frame: the admin's „Nižší
    // rozlišení“ (off here) reaches the display as they do.
    expect(display.log, ['hold', 'lowRes:false']);

    // On the way out the stored low-res choice goes too: the browser is
    // no longer the kiosk's.
    await finish(tester);
    expect(display.log, [
      'hold',
      'lowRes:false',
      'release',
      'forgetLowRes',
    ]);
  });

  testWidgets('the admin\'s „Nižší rozlišení“ reaches the display as soon as '
      'the settings do', (tester) async {
    final display = _DisplayRecorder();
    await tester.pumpWidget(kioskApp(display: display, kioskLowRes: true));
    await tester.pumpAndSettle();
    expect(display.log, ['hold', 'lowRes:true']);

    await finish(tester);
  });

  testWidgets('b: tapping „Rezervace tréninku“ opens picker with '
      'first-letter tiles', (
    tester,
  ) async {
    await tester.pumpWidget(kioskApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text(kioskReserveLabel));
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

  // A letter of the picker as the tile it paints: SizedBox → Ink (the
  // decoration) → InkWell, as in name_picker_test.dart.
  Finder letterTile(String letter) =>
      find.ancestor(of: find.text(letter), matching: find.byType(Ink));

  testWidgets('b2: above the first letters the picker says which letter to '
      'pick — not once a letter is picked, nor when it lists names at once', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(kioskApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text(kioskReserveLabel));
    await tester.pumpAndSettle();

    final hint = find.text(firstLetterHint);
    expect(hint, findsOneWidget);
    // Above the letters.
    expect(
      tester.getBottomLeft(hint).dy,
      lessThan(tester.getTopLeft(find.text('A')).dy),
    );

    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    expect(hint, findsNothing);
    await finish(tester);

    // Few players: their names straight away, no letters to explain.
    await tester.pumpWidget(kioskApp(roster: [anna, petr]));
    await tester.pumpAndSettle();
    await tester.tap(find.text(kioskReserveLabel));
    await tester.pumpAndSettle();
    expect(find.text(anna.displayName), findsOneWidget);
    expect(hint, findsNothing);
    await finish(tester);
  });

  testWidgets('b3: the admin\'s note (0070) stands under the first letters, '
      'the hint above them — the default text or the admin\'s own; none, '
      'nothing; gone once a letter is picked', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      kioskApp(kioskPickerNote: ScheduleSettings.defaultPickerNote),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(kioskReserveLabel));
    await tester.pumpAndSettle();

    final note = find.byType(KioskWarning);
    final hint = find.text(firstLetterHint);
    expect(note, findsOneWidget);
    expect(find.text(ScheduleSettings.defaultPickerNote), findsOneWidget);
    expect(
      tester.getBottomLeft(hint).dy,
      lessThan(tester.getTopLeft(letterTile('A')).dy),
    );
    // Under the letters — the last row too — and still on the kiosk's
    // screen, no scrolling to it.
    expect(
      tester.getTopLeft(note).dy,
      greaterThan(tester.getBottomLeft(letterTile('Z')).dy),
    );
    expect(tester.getBottomLeft(note).dy, lessThanOrEqualTo(1080));
    // Wide, so it takes few lines, yet not across the whole wall display:
    // centred, at most 1600 px.
    expect(tester.getSize(note).width, lessThanOrEqualTo(1600));
    expect(tester.getCenter(note).dx, closeTo(960, 1));
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    expect(note, findsNothing);
    await finish(tester);

    // The fixture has one player per letter, so 'A' above goes straight to
    // the names; the later pages of letters must go without the note too.
    // More than `_capacity` (24) players under 'A' keep the picker on
    // letters for the second one.
    final aPlayers = [
      for (var i = 0; i < 25; i++)
        PlayerName(
          id: 'a$i',
          displayName: 'A${String.fromCharCode(66 + i)} Hráč',
        ),
    ];
    await tester.pumpWidget(
      kioskApp(
        roster: [...aPlayers, players[10], petr],
        kioskPickerNote: ScheduleSettings.defaultPickerNote,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(kioskReserveLabel));
    await tester.pumpAndSettle();
    expect(note, findsOneWidget);
    expect(hint, findsOneWidget);
    expect(find.text('B'), findsNothing);

    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    // Still letters — the second ones, AB…AZ — but no note, no hint.
    expect(find.text('A…'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
    expect(find.text('Z'), findsOneWidget);
    expect(note, findsNothing);
    expect(hint, findsNothing);
    await finish(tester);

    await tester.pumpWidget(
      kioskApp(kioskPickerNote: 'Zrušit jde jen v aplikaci.'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(kioskReserveLabel));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: note,
        matching: find.text('Zrušit jde jen v aplikaci.'),
      ),
      findsOneWidget,
    );
    await finish(tester);

    await tester.pumpWidget(kioskApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text(kioskReserveLabel));
    await tester.pumpAndSettle();
    expect(hint, findsOneWidget);
    expect(note, findsNothing);
    await finish(tester);
  });

  testWidgets('b3: a small alley\'s picker lists the names at once — the '
      'note stands under them, the hint stays the letters\'; not once a '
      'letter led to the names', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final note = find.byType(KioskWarning);
    final hint = find.text(firstLetterHint);
    // Up to `_capacity` (24) players: no letters, the names straight away.
    for (final roster in [
      [anna, petr],
      players.take(24).toList(),
    ]) {
      await tester.pumpWidget(
        kioskApp(
          roster: roster,
          kioskPickerNote: ScheduleSettings.defaultPickerNote,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(kioskReserveLabel));
      await tester.pumpAndSettle();

      expect(find.text(anna.displayName), findsOneWidget);
      expect(hint, findsNothing);
      expect(note, findsOneWidget);
      expect(find.text(ScheduleSettings.defaultPickerNote), findsOneWidget);
      // Under the names — the last one too — on the screen, centred and
      // not stretched across it.
      expect(
        tester.getTopLeft(note).dy,
        greaterThan(tester.getBottomLeft(find.text(roster.last.displayName)).dy),
      );
      expect(tester.getBottomLeft(note).dy, lessThanOrEqualTo(1080));
      expect(tester.getSize(note).width, lessThanOrEqualTo(1600));
      expect(tester.getCenter(note).dx, closeTo(960, 1));
      expect(tester.takeException(), isNull);
      await finish(tester);
    }

    // Names reached through a letter are a later page: no note there.
    await tester.pumpWidget(
      kioskApp(kioskPickerNote: ScheduleSettings.defaultPickerNote),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(kioskReserveLabel));
    await tester.pumpAndSettle();
    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    expect(find.text(anna.displayName), findsOneWidget);
    expect(note, findsNothing);
    await finish(tester);

    // No note set: the names alone.
    await tester.pumpWidget(kioskApp(roster: [anna, petr]));
    await tester.pumpAndSettle();
    await tester.tap(find.text(kioskReserveLabel));
    await tester.pumpAndSettle();
    expect(find.text(anna.displayName), findsOneWidget);
    expect(note, findsNothing);
    await finish(tester);
  });

  testWidgets('b3: on a phone the note under the letters scrolls into view '
      'and keeps to the screen', (tester) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // The picker alone: the shell's status bar is not made for a phone.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(
            (ref) => Stream.value(
              ScheduleSettings(
                laneCount: settings.laneCount,
                trainingWeekdays: settings.trainingWeekdays,
                bookingHorizonDays: settings.bookingHorizonDays,
                maxActiveReservations: settings.maxActiveReservations,
                kioskPickerNote: ScheduleSettings.defaultPickerNote,
              ),
            ),
          ),
          playersProvider.overrideWith((ref) async => players),
        ],
        child: const MaterialApp(home: NamePicker()),
      ),
    );
    await tester.pumpAndSettle();

    final note = find.byType(KioskWarning);
    expect(note, findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(
      tester.getBottomLeft(find.text(firstLetterHint)).dy,
      lessThan(tester.getTopLeft(letterTile('A')).dy),
    );
    // Two letters a row: the note is far below the fold, and the page
    // scrolls down to it.
    expect(
      tester.getTopLeft(note).dy,
      greaterThan(tester.getBottomLeft(letterTile('Z')).dy),
    );
    await tester.scrollUntilVisible(note, 300);
    await tester.pumpAndSettle();
    expect(note.hitTestable(), findsOneWidget);
    expect(tester.getTopLeft(note).dx, greaterThanOrEqualTo(0));
    expect(tester.getTopRight(note).dx, lessThanOrEqualTo(375));
    expect(tester.getBottomLeft(note).dy, lessThanOrEqualTo(812));
    expect(tester.takeException(), isNull);
    await finish(tester);
  });

  testWidgets(
    'c: drilling to a name and tapping it shows the Rezervuje: banner',
    (tester) async {
      await tester.pumpWidget(kioskApp());
      await tester.pumpAndSettle();

      await tester.tap(find.text(kioskReserveLabel));
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
      expect(find.text(kioskReserveLabel), findsNothing);

      await finish(tester);
    },
  );

  testWidgets('the main action: „Rezervace tréninku“ in 26 px extra bold, '
      'on its gradient in a button 72 px tall', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(kioskApp());
    await tester.pumpAndSettle();
    final style = DefaultTextStyle.of(
      tester.element(find.text(kioskReserveLabel)),
    ).style;
    expect(style.fontSize, 26);
    expect(style.fontWeight, FontWeight.w800);
    // As drawn — after the scaling that fits it to a narrow bar.
    expect(tester.getRect(find.byType(GradientButton)).height,
        greaterThanOrEqualTo(72));
    await finish(tester);
  });

  testWidgets('the banner names who books by their nick — the name the '
      'board shows — plain on the bar, without a box', (tester) async {
    const bobo = PlayerName(id: 'bobo', displayName: 'Jan Novák', nick: 'Bobo');
    await tester.pumpWidget(kioskApp(roster: [...players, bobo]));
    await tester.pumpAndSettle();

    await tester.tap(find.text(kioskReserveLabel));
    await tester.pumpAndSettle();
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bobo'));
    await tester.pumpAndSettle();

    final banner = find.text('Rezervuje: Bobo');
    expect(banner, findsOneWidget);
    expect(find.textContaining('Jan Novák'), findsNothing);
    // No avatar, no initials: the players have no pictures yet.
    expect(find.byType(CircleAvatar), findsNothing);
    expect(find.text(initialsOf('Bobo')), findsNothing);
    // No box: nothing between the banner and the bar's own background
    // paints one.
    final bar = Theme.of(tester.element(banner)).colorScheme
        .surfaceContainerHighest;
    expect(
      find.ancestor(
        of: banner,
        matching: find.byWidgetPredicate(
          (w) =>
              w is DecoratedBox ||
              w is Card ||
              w is Chip ||
              (w is ColoredBox && w.color.a > 0 && w.color != bar) ||
              (w is Material &&
                  w.type != MaterialType.canvas &&
                  w.type != MaterialType.transparency),
        ),
      ),
      findsNothing,
      reason: 'no box around the banner',
    );
    await tester.tap(find.byTooltip('Zrušit výběr'));
    await tester.pumpAndSettle();
    expect(find.text(kioskReserveLabel), findsOneWidget);
    await finish(tester);
  });

  testWidgets('d: with a selected player, tapping a + cell opens the booking '
      'confirm dialog containing the player\'s name', (tester) async {
    await tester.pumpWidget(kioskApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text(kioskReserveLabel));
    await tester.pumpAndSettle();
    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(anna.displayName));
    await tester.pumpAndSettle();

    // Today is the board's first (always-built) column, so the + cell is
    // already in the tree — the board marks a free lane with the Material
    // add icon (a bundled font: the same in every row on the web).
    final addCell = find.byIcon(Icons.add).first;
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
        await tester.tap(find.text(kioskReserveLabel));
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
      expect(find.byIcon(Icons.add), findsNothing);
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
      expect(find.byIcon(Icons.add), findsWidgets);
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

      await tester.tap(find.text(kioskReserveLabel));
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
      // show the add icon.
      final addCell = find.byIcon(Icons.add).first;
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

  testWidgets('d4: a long name in the status bar chip ellipsizes, the bar '
      'does not overflow', (tester) async {
    const ghost = PlayerName(
      id: 'ghost',
      displayName: 'Bohumil Kroupa-Novotný z Horní Dolní Lhoty',
      hasAccount: false,
    );
    await tester.pumpWidget(kioskApp(roster: [...players, ghost]));
    await tester.pumpAndSettle();
    await tester.tap(find.text(kioskReserveLabel));
    await tester.pumpAndSettle();
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(ghost.displayName));
    await tester.pumpAndSettle();
    expect(find.textContaining('Rezervuje: Bohumil'), findsOneWidget);
    expect(tester.takeException(), isNull);
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

  testWidgets('a touch in the name picker counts as activity: a visitor '
      'searching for their name is not sent back to the board', (tester) async {
    await tester.pumpWidget(kioskApp(kioskIdleSeconds: 30));
    await tester.pumpAndSettle();
    await tester.tap(find.text(kioskReserveLabel));
    await tester.pumpAndSettle();
    expect(find.text('Kdo si rezervuje?'), findsOneWidget);

    // Drilling in and back again, 20 s apart: each tap restarts the 30 s.
    await tester.pump(const Duration(seconds: 20));
    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 20));
    await tester.tap(find.text('Zpět'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 20));
    expect(find.text('Kdo si rezervuje?'), findsOneWidget);

    // Left alone, it still closes.
    await tester.pump(const Duration(seconds: 11));
    await tester.pumpAndSettle();
    expect(find.text('Kdo si rezervuje?'), findsNothing);
    await finish(tester);
  });

  testWidgets('the first letters stand in even rows, the bottom ones '
      'taking the odd letter', (tester) async {
    // 27 first letters: the 26 of the roster plus „Ch“.
    await tester.pumpWidget(kioskApp(
      roster: [...players, const PlayerName(id: 'ch', displayName: 'Chalupa')],
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text(kioskReserveLabel));
    await tester.pumpAndSettle();

    final tiles = find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_LetterTile',
    );
    expect(tiles, findsNWidgets(27));
    expect(find.text('Ch'), findsOneWidget);
    final perRow = <double, int>{};
    for (final e in tiles.evaluate()) {
      final y = tester.getTopLeft(find.byWidget(e.widget)).dy;
      perRow[y] = (perRow[y] ?? 0) + 1;
    }
    final counts = (perRow.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key)))
        .map((e) => e.value)
        .toList();
    expect(counts.length, greaterThan(1));
    expect(counts.reduce((a, b) => a > b ? a : b) -
        counts.reduce((a, b) => a < b ? a : b), lessThanOrEqualTo(1));
    // Top to bottom, never fewer than the row above.
    for (var i = 1; i < counts.length; i++) {
      expect(counts[i], greaterThanOrEqualTo(counts[i - 1]));
    }

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    await finish(tester);
  });

  testWidgets('the picker note is as big as the hint above the letters, or '
      'as big as the admin sets it (0075)', (tester) async {
    double size(String text) => tester
        .widget<Text>(find.text(text))
        .style!
        .fontSize!;
    const note = 'Odhlásit se tu nedá.';
    await tester.pumpWidget(kioskApp(kioskPickerNote: note));
    await tester.pumpAndSettle();
    await tester.tap(find.text(kioskReserveLabel));
    await tester.pumpAndSettle();
    final hint = tester
        .widget<Text>(find.text(firstLetterHint))
        .style!
        .fontSize!;
    expect(size(note), greaterThanOrEqualTo(hint));
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    await finish(tester);

    await tester.pumpWidget(
      kioskApp(kioskPickerNote: note, kioskWarningFontSize: 30),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(kioskReserveLabel));
    await tester.pumpAndSettle();
    expect(size(note), 30);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    await finish(tester);
  });

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

    await tester.tap(find.text(kioskReserveLabel));
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

      await tester.tap(find.text(kioskReserveLabel));
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
      expect(findEmojiText('⛔ Úklid před zápasem\n20:00–21:00'), findsOneWidget);
      expect(
        findEmojiText(
          '🏆 ${match.title}\n'
          '${match.startsAt.display()}–${match.endsAt.display()}'
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
        findEmojiText(
          '🏆 ${match.title}\n'
          '${match.startsAt.display()}–${match.endsAt.display()}'
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
      // rental is one-time, so only today's column has it) — on two lines
      // of their own, or as one two-line text in a short band.
      final band = find.ancestor(
        of: findEmojiTextContaining('Firma X'),
        matching: find.byType(CalendarEventBand),
      );
      expect(band, findsOneWidget);
      expect(
        find.descendant(of: band, matching: findEmojiTextContaining('8:45–9:30')),
        findsOneWidget,
      );

      // And it sits at its true time: band top-to-block top distance equals
      // 45 minutes at the shared px/min scale (block card = 30 min).
      final shortCard = find.byKey(const ValueKey('cal-block-bShort')).first;
      final pxPerMinute = tester.getSize(shortCard).height / 30;
      final bandTop = tester.getTopLeft(band).dy;
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
      expect(findEmojiText('⛔ Úklid před zápasem\n19:00–20:00'), findsOneWidget);

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
      expect(findEmojiText('🏆 ${match.title}\n20:00–22:00'), findsOneWidget);
      expect(find.textContaining('Firma X'), findsNothing);
      // …and the spilling rental shows only via its outside piece.
      expect(find.textContaining('Firma Y'), findsOneWidget);

      await finish(tester);
    },
  );

  testWidgets('q: kiosk_fit_day=false switches to the comfortable fixed scale '
      '(60 min = laneCount rows for the font) instead of fit-to-screen', (
    tester,
  ) async {
    await tester.pumpWidget(kioskApp(kioskFitDay: false));
    await tester.pumpAndSettle();

    // b1 is 61 minutes; at laneCount(2) rows of 11 px text (31.7 px) an
    // hour the card is 61 × 1.058 ≈ 64.5 px tall — independent of the
    // viewport height.
    final card = find.byKey(const ValueKey('cal-block-b1')).first;
    expect(
      tester.getSize(card).height,
      closeTo(61 * settings.laneCount * kioskRowHeightFor(11) / 60, 0.7),
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
    'score shows, a video not on YouTube has no button and no tap-through '
    'to the app\'s detail (PR B fix round 1: the 60 s idle-reset Listener '
    'never sees touches on a pushed route, and an external video browser on '
    'a kiosk tablet is undesirable)',
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
      // The kiosk's width for the list (0075): 560 unless the admin says.
      expect(
        find.descendant(
          of: dialog,
          matching: find.byWidgetPredicate(
            (w) => w is SizedBox && w.width == 560,
          ),
        ),
        findsOneWidget,
      );
      // The score, side by side around its colon.
      for (final part in ['5', '3']) {
        expect(
          find.descendant(of: dialog, matching: find.text(part)),
          findsOneWidget,
        );
      }
      // A video the kiosk cannot play (not YouTube): no video control at
      // all — the fallback trophy instead.
      expect(find.byIcon(Icons.play_circle_fill), findsNothing);
      expect(find.byIcon(Icons.videocam), findsNothing);
      expect(
        find.descendant(
          of: dialog,
          matching: find.byIcon(Icons.emoji_events_outlined),
        ),
        findsOneWidget,
      );

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
      // When it went up; null = the [id]th of September.
      DateTime? posted,
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
      createdAt: posted ?? DateTime(2026, 9, int.tryParse(id) ?? 1),
      updatedAt: posted ?? DateTime(2026, 9, 1),
    );
    // Each stand-in player's „the video has ended“, by video id.
    final streamEnded = <String, VoidCallback?>{};
    PrioritySlot fed(
      String id,
      Day date,
      String home, {
      int hour = 14,
      String? video,
    }) => PrioritySlot(
      type: PrioritySlot.fallbackMatchType,
      id: id,
      date: date,
      startsAt: HourMinute(hour, 0),
      endsAt: HourMinute(hour + 3, 0),
      homeTeam: home,
      awayTeam: 'Soupeř',
      importKey: 'cka:$id',
      videoUrl: video,
    );
    MatchResult res(
      String id,
      String status,
      num home,
      num away, {
      String fetched = '2026-09-17T21:00:00+00:00',
    }) => MatchResult.fromJson({
      'match_id': id,
      'status': status,
      'home_points': home,
      'away_points': away,
      'fetched_at': fetched,
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
      // The header's modules as the old switches had them (0082 converts
      // them so); [header] lays them out freely.
      bool headerNotices = true,
      bool showMatches = true,
      bool showUpcoming = true,
      bool liveMode = true,
      int weeksBack = 2,
      int weeksAhead = 1,
      int drawerColumns = 2,
      int share = 40,
      int zapisPercent = 80,
      int noticeRotation = 12,
      // What a fresh notice gets (0081), and for how many days it is one.
      KioskNoticesFresh noticesFresh = KioskNoticesFresh.highlight,
      int noticesFreshDays = 3,
      // The notices as they change while the kiosk runs; null = [notices].
      Stream<List<Message>>? noticesStream,
      int liveRotation = 12,
      bool panelEnabled = true,
      int pastDays = 0,
      int idleSeconds = 60,
      bool followBoard = true,
      bool Function()? socketOpen,
      void Function(String id)? onRefresh,
      // refresh_match's answer; a Completer's future holds it back.
      Future<String?> Function(String id)? refreshAnswer,
      int liveRefresh = 60,
      MatchLayout liveLayout = MatchLayout.full,
      int visibleDays = 7,
      int fontSize = 11,
      int bandFontSize = 10,
      bool fitDay = true,
      bool animations = true,
      bool stream = false,
      bool nameday = false,
      bool weather = false,
      // The weather module's forecast, the admin's title for it and what
      // it shows beside the temperature (0082; null = the default).
      KioskWeather? forecast,
      String? weatherTitle,
      Set<KioskWeatherItem>? weatherItems,
      String? warning,
      bool todaysMatches = true,
      KioskZapisNav zapisNav = KioskZapisNav.bar,
      Set<int>? trainingWeekdays,
      int streamMax = 1,
      bool streamEnabled = true,
      // The admin flipping the streams' master switch while the kiosk runs.
      Stream<bool>? streamSwitch,
      Stream<Map<String, MatchResult>>? resultsStream,
      Map<String, List<MatchPlayerResult>> lineups = const {},
      bool dutyHeader = false,
      bool dutyBoard = false,
      bool dutyDrawer = false,
      int dutyShare = 30,
      KioskDutyBandPosition dutyBandPosition = KioskDutyBandPosition.middle,
      List<DutyPeriod> dutyPeriods = const [],
      List<DutyAssignment> dutyAssignments = const [],
      List<Reservation> reservations = const [],
      int? maxActiveReservations,
      // Both panels as the admin lays them out (0077); null = the layout
      // the drawer settings above convert to, as 0077 converts them.
      KioskPanels? panels,
      // The header's modules (0082); null = what the switches above
      // convert to.
      KioskHeader? header,
      // Clubs' nicknames (0080); null = every name in full.
      NameDisplay? names,
    }) => ProviderScope(
      overrides: [
        settingsProvider.overrideWith((ref) {
          ScheduleSettings shown(bool streamOn) => ScheduleSettings(
            laneCount: settings.laneCount,
            trainingWeekdays: trainingWeekdays ?? settings.trainingWeekdays,
            bookingHorizonDays: settings.bookingHorizonDays,
            maxActiveReservations:
                maxActiveReservations ?? settings.maxActiveReservations,
            kioskPanels:
                panels ??
                kioskPanelsFromLegacy(
                  panelEnabled: panelEnabled,
                  drawerOpen: drawerOpen,
                  drawerColumns: drawerColumns,
                  noticesMode: showNotices ? 'drawer' : 'off',
                  noticesShare: share,
                  showMatches: showMatches,
                  liveMode: liveMode,
                  dutyDrawer: dutyDrawer,
                  dutyShare: dutyShare,
                ),
            kioskHeader:
                header ??
                kioskHeaderFromLegacy(
                  weather: weather,
                  nameday: nameday,
                  dutyHeader: dutyHeader,
                  noticesHeader: headerNotices,
                ),
            kioskWeatherTitle: weatherTitle,
            kioskWeatherItems: weatherItems ?? kioskWeatherItemsDefault,
            kioskShowUpcoming: showUpcoming,
            kioskLiveMode: liveMode,
            kioskWeeksBack: weeksBack,
            kioskWeeksAhead: weeksAhead,
            kioskZapisPercent: zapisPercent,
            kioskNoticesRotationSeconds: noticeRotation,
            kioskNoticesFresh: noticesFresh,
            kioskNoticesFreshDays: noticesFreshDays,
            kioskLiveRotationSeconds: liveRotation,
            kioskPastDays: pastDays,
            kioskIdleSeconds: idleSeconds,
            kioskFollowBoard: followBoard,
            kioskLiveRefreshSeconds: liveRefresh,
            kioskLiveLayout: liveLayout,
            kioskVisibleDays: visibleDays,
            kioskFontSize: fontSize,
            kioskBandFontSize: bandFontSize,
            kioskFitDay: fitDay,
            kioskAnimations: animations,
            kioskStream: stream,
            kioskWarning: warning,
            kioskTodaysMatches: todaysMatches,
            kioskZapisNav: zapisNav,
            kioskStreamMax: streamMax,
            kioskStreamEnabled: streamOn,
            kioskDutyBoard: dutyBoard,
            kioskDutyBandPosition: dutyBandPosition,
          );
          return streamSwitch?.map(shown) ?? Stream.value(shown(streamEnabled));
        }),
        // The stream's player stands in as text: a platform view does not
        // run under flutter_test.
        kioskStreamContentProvider.overrideWithValue(
          (videoId, {required interactive, onEnded}) {
            streamEnded[videoId] = onEnded;
            return Text(
              'player $videoId ${interactive ? 'on' : 'off'}',
              key: const ValueKey('player'),
            );
          },
        ),
        nowProvider.overrideWith((ref) => Stream.value(nowAt)),
        timeBlocksProvider.overrideWith((ref) => Stream.value(const [b1])),
        dayOverridesProvider.overrideWith((ref) => Stream.value(const [])),
        prioritySlotsProvider.overrideWithValue(slots),
        rentalsProvider.overrideWith((ref) => Stream.value(const [])),
        weekReservationsProvider.overrideWith(
          (ref, monday) => Stream.value([
            for (final r in reservations)
              if (!r.date.isBefore(monday) &&
                  r.date.differenceInDays(monday) < 7)
                r,
          ]),
        ),
        playersProvider.overrideWith((ref) async => players),
        messagesProvider.overrideWith(
          (ref) => noticesStream ?? Stream.value(notices),
        ),
        kioskSocketOpenProvider.overrideWithValue(socketOpen ?? () => true),
        kioskRefreshMatchProvider.overrideWithValue((id) async {
          onRefresh?.call(id);
          return refreshAnswer == null ? 'fresh' : await refreshAnswer(id);
        }),
        matchResultsProvider.overrideWith(
          (ref) => resultsStream ?? Stream.value(results),
        ),
        matchPlayerResultsProvider.overrideWith(
          (ref, id) => Stream.value(lineups[id] ?? const []),
        ),
        dutyPeriodsProvider.overrideWith((ref) => Stream.value(dutyPeriods)),
        dutyAssignmentsProvider.overrideWith(
          (ref) => Stream.value(dutyAssignments),
        ),
        kioskWeatherProvider.overrideWith((ref) => Stream.value(forecast)),
        if (names != null) nameDisplayProvider.overrideWith((ref) => names),
      ],
      child: const MaterialApp(home: KioskShell()),
    );

    void fullHd(WidgetTester tester) {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
    }

    testWidgets('a visitor who picked their name gets the board alone: the '
        'drawer and its button step aside, and are back as they were once '
        'the pick is cleared', (tester) async {
      fullHd(tester);
      await tester.pumpWidget(
        app(notices: [notice('1', 'Brigáda')], drawerOpen: true),
      );
      await tester.pumpAndSettle();
      // Open = as wide as its columns; shut = nothing of it on screen.
      bool open() => tester.getSize(find.byType(KioskPanelView)).width > 0;
      expect(open(), isTrue);
      expect(find.byType(KioskDrawerButton), findsOneWidget);

      await tester.tap(find.text(kioskReserveLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.text('A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(players.first.displayName));
      await tester.pumpAndSettle();
      expect(open(), isFalse);
      expect(find.byType(KioskDrawerButton), findsNothing);

      await tester.tap(find.byTooltip('Zrušit výběr'));
      await tester.pumpAndSettle();
      expect(open(), isTrue);
      expect(find.byType(KioskDrawerButton), findsOneWidget);
      await finish(tester);
    });

    final openButton = find.byIcon(Icons.keyboard_double_arrow_left);
    final closeButton = find.byIcon(Icons.keyboard_double_arrow_right);
    // The match being played across the drawer: its scoreboard there (the
    // full view's; the compact ones draw their own score).
    final liveView = find.descendant(
      of: find.byType(KioskPanelView),
      matching: find.byType(MatchScoreboard),
    );
    // A notice title is in the status bar too; these tests are the drawer's.
    Finder drawerText(String t) =>
        find.descendant(of: find.byType(KioskPanelView), matching: find.text(t));

    testWidgets('hidden for a pick, the drawer keeps the match being played: '
        'it still asks for the score, and is back as it was — not opened '
        'anew — once the pick is cleared', (tester) async {
      fullHd(tester);
      final asked = <String>[];
      await tester.pumpWidget(
        app(
          slots: [fed('m', day, 'Hrají')],
          results: {'m': res('m', 'in_progress', 2, 1)},
          lineups: {'m': lineup},
          liveRefresh: 30,
          onRefresh: asked.add,
        ),
      );
      await tester.pumpAndSettle();
      expect(liveView, findsOneWidget);
      expect(asked, ['m']);

      await tester.tap(find.text(kioskReserveLabel));
      await tester.pumpAndSettle();
      await tester.tap(find.text('A'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(players.first.displayName));
      await tester.pumpAndSettle();
      expect(liveView, findsNothing, reason: 'out of sight');
      await tester.pump(const Duration(seconds: 31));
      expect(asked, ['m', 'm'], reason: 'still asking while hidden');

      await tester.tap(find.byTooltip('Zrušit výběr'));
      await tester.pumpAndSettle();
      expect(liveView, findsOneWidget);
      // A live view opened anew would ask at once.
      expect(asked, ['m', 'm']);
      await finish(tester);
    });

    group('stream window', () {
      const video = 'https://www.youtube.com/watch?v=wOq9EODb8w8';
      final player = find.byKey(const ValueKey('player'));
      // 11:00–14:00, being played at the kiosk's noon.
      final onAir = [fed('m', day, 'Domácí', hour: 11, video: video)];
      final playing = {'m': res('m', 'in_progress', 2, 1)};
      // A day's list with the match on air: its live badge pulses for as
      // long as the list is open, and pumpAndSettle would run on to the idle
      // reset — which closes every route by itself.
      Future<void> pumpDialog(WidgetTester tester) async {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
      }

      testWidgets('with the switch on, the match on air with a video plays '
          'in the window; off, or without a video, nothing', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(stream: true, slots: onAir, results: playing),
        );
        await tester.pumpAndSettle();
        expect(find.text('player wOq9EODb8w8 on'), findsOneWidget);
        expect(find.text('Domácí – Soupeř'), findsWidgets);
        await finish(tester);

        await tester.pumpWidget(app(slots: onAir, results: playing));
        await tester.pumpAndSettle();
        expect(player, findsNothing);
        await finish(tester);

        await tester.pumpWidget(
          app(
            stream: true,
            slots: [fed('m', day, 'Domácí', hour: 11)],
            results: playing,
          ),
        );
        await tester.pumpAndSettle();
        expect(player, findsNothing);
        await finish(tester);
      });

      testWidgets('a dragged window keeps its place across the idle reset',
          (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(stream: true, slots: onAir, results: playing, idleSeconds: 30),
        );
        await tester.pumpAndSettle();
        final titleBar = find.descendant(
          of: find.byType(KioskStreamWindow),
          matching: find.text('Domácí – Soupeř'),
        );
        await tester.drag(titleBar, const Offset(300, -200));
        await tester.pumpAndSettle();
        final moved = tester.getRect(player);

        await tester.pump(const Duration(seconds: 31));
        await tester.pumpAndSettle();
        expect(tester.getRect(player), moved);
        await finish(tester);
      });

      testWidgets('the player takes no touches while a notice is open',
          (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            stream: true,
            slots: onAir,
            results: playing,
            // A long notice: its „Více“ opens the dialog.
            notices: [notice('1', 'Brigáda', body: 'Sejdeme se. ' * 120)],
            drawerOpen: true,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('player wOq9EODb8w8 on'), findsOneWidget);

        await tester.tap(find.text('Více'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.text('player wOq9EODb8w8 off'), findsOneWidget);

        await tester.tap(find.text('Zavřít'));
        await tester.pumpAndSettle();
        expect(find.text('player wOq9EODb8w8 on'), findsOneWidget);
        await finish(tester);
      });

      testWidgets('a stream starting leaves the drawer as it was: the same '
          'element, nothing of its state lost', (tester) async {
        fullHd(tester);
        final results = StreamController<Map<String, MatchResult>>();
        addTearDown(results.close);
        // 15:00: three hours ahead at the kiosk's noon — on air only once
        // the site says it is being played.
        await tester.pumpWidget(
          app(
            stream: true,
            slots: [fed('m', day, 'Domácí', hour: 15, video: video)],
            resultsStream: results.stream,
            notices: [notice('1', 'Brigáda')],
            drawerOpen: true,
          ),
        );
        results.add(const {});
        await tester.pumpAndSettle();
        expect(player, findsNothing);
        final drawer = tester.element(find.byType(KioskPanelView));

        results.add({'m': res('m', 'in_progress', 0, 0)});
        await tester.pumpAndSettle();
        expect(player, findsOneWidget);
        expect(identical(tester.element(find.byType(KioskPanelView)), drawer), isTrue);
        await finish(tester);
      });

      testWidgets('the player takes no touches while the name picker is open',
          (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(stream: true, slots: onAir, results: playing),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(kioskReserveLabel));
        await tester.pumpAndSettle();
        expect(find.byType(NamePicker), findsOneWidget);
        expect(find.text('player wOq9EODb8w8 off'), findsOneWidget);

        await tester.tap(find.byTooltip('Zavřít'));
        await tester.pumpAndSettle();
        expect(find.text('player wOq9EODb8w8 on'), findsOneWidget);
        await finish(tester);
      });

      testWidgets('the player takes no touches while the booking confirm is '
          'open', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(stream: true, slots: onAir, results: playing),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(kioskReserveLabel));
        await tester.pumpAndSettle();
        await tester.tap(find.text('A'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(NamePicker),
            matching: find.text(anna.displayName),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('player wOq9EODb8w8 on'), findsOneWidget);

        // A free lane far from the window (the last ＋ is in the last day).
        final addCell = find.byIcon(Icons.add).last;
        await tester.ensureVisible(addCell);
        await tester.tap(addCell);
        await tester.pumpAndSettle();
        expect(find.text('Rezervovat termín?'), findsOneWidget);
        expect(find.text('player wOq9EODb8w8 off'), findsOneWidget);

        await tester.tap(find.text('Zrušit'));
        await tester.pumpAndSettle();
        expect(find.text('player wOq9EODb8w8 on'), findsOneWidget);
        await finish(tester);
      });

      testWidgets('the player takes no touches while the Zápis is open',
          (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            stream: true,
            slots: [...onAir, fed('f', day.addDays(-3), 'Hotovo')],
            results: {...playing, 'f': res('f', 'finished', 6, 2)},
            lineups: {'f': lineup},
            drawerOpen: true,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('6 : 2'));
        await tester.pumpAndSettle();
        expect(find.byType(LegacyScoreSheetPage), findsOneWidget);
        expect(find.text('player wOq9EODb8w8 off'), findsOneWidget);

        await tester.tapAt(const Offset(20, 20));
        await tester.pumpAndSettle();
        expect(find.byType(LegacyScoreSheetPage), findsNothing);
        expect(find.text('player wOq9EODb8w8 on'), findsOneWidget);
        await finish(tester);
      });

      testWidgets('the player takes no touches while a day\'s matches are '
          'open from the board\'s header', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(stream: true, slots: onAir, results: playing),
        );
        await tester.pumpAndSettle();
        expect(find.text('player wOq9EODb8w8 on'), findsOneWidget);

        // The status bar names today's match too: the board's header it is.
        await tester.tap(
          find
              .descendant(
                of: find.byType(BoardColumnHeader),
                matching: find.textContaining('Domácí'),
              )
              .first,
        );
        await pumpDialog(tester);
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(find.text('player wOq9EODb8w8 off'), findsOneWidget);

        await tester.tap(find.text('Zavřít'));
        await pumpDialog(tester);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.text('player wOq9EODb8w8 on'), findsOneWidget);
        await finish(tester);
      });

      testWidgets('the window goes with the match: decided, and its result '
          'read more than half an hour ago', (tester) async {
        fullHd(tester);
        // Noon at the kiosk is 10:00 UTC; the result was read at 09:20.
        await tester.pumpWidget(
          app(
            stream: true,
            slots: onAir,
            results: {
              'm': res('m', 'finished', 6, 2,
                  fetched: '2026-10-08T09:20:00+00:00'),
            },
          ),
        );
        await tester.pumpAndSettle();
        expect(player, findsNothing);
        await finish(tester);
      });

      const video2 = 'https://youtu.be/abcdefghijk';
      const video3 = 'https://youtu.be/ABCDEFGHIJK';
      // Finished three and two days back, each with its recording.
      final recorded = [
        fed('f1', day.addDays(-3), 'Hotovo', video: video2),
        fed('f2', day.addDays(-2), 'Včera', video: video3),
      ];
      final decided = {
        'f1': res('f1', 'finished', 6, 2),
        'f2': res('f2', 'finished', 3, 5),
      };

      testWidgets('anyone plays a recording: ▶ at a finished match in the '
          'drawer, the switch off; the × closes it', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(slots: [recorded.first], results: decided, drawerOpen: true),
        );
        await tester.pumpAndSettle();
        expect(player, findsNothing);

        await tester.tap(find.byTooltip('Přehrát záznam'));
        await tester.pumpAndSettle();
        expect(find.text('player abcdefghijk on'), findsOneWidget);

        await tester.tap(find.byTooltip('Zavřít stream'));
        await tester.pumpAndSettle();
        expect(player, findsNothing);
        await finish(tester);
      });

      testWidgets('the Zápis of a match with a video has its button: the '
          'Zápis closes, the stream opens', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            slots: [recorded.first],
            results: decided,
            lineups: {'f1': lineup},
            drawerOpen: true,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('6 : 2'));
        await tester.pumpAndSettle();
        expect(find.byType(LegacyScoreSheetPage), findsOneWidget);
        // Above the sheet, not over its corner (the away team's totals).
        expect(
          tester.getRect(find.text('Přehrát záznam')).bottom,
          lessThanOrEqualTo(
            tester.getRect(find.byType(LegacyScoreSheetPage)).top,
          ),
        );

        await tester.tap(find.text('Přehrát záznam'));
        await tester.pumpAndSettle();
        expect(find.byType(LegacyScoreSheetPage), findsNothing);
        expect(find.text('player abcdefghijk on'), findsOneWidget);
        await finish(tester);
      });

      testWidgets('a tap on today\'s match without a score yet, but with a '
          'video, opens its stream — in the header and on the board',
          (tester) async {
        fullHd(tester);
        // 15:00, three hours ahead at the kiosk's noon: no score, not live.
        final later = [fed('l', day, 'Odpoledne', hour: 15, video: video2)];
        await tester.pumpWidget(app(slots: later));
        await tester.pumpAndSettle();
        expect(player, findsNothing);

        // The header's line (the board's day header says it too, after).
        await tester.tap(
          find.textContaining('Odpoledne – Soupeř · 15:00').first,
        );
        await tester.pumpAndSettle();
        expect(find.text('player abcdefghijk on'), findsOneWidget);
        await tester.tap(find.byTooltip('Zavřít stream'));
        await tester.pumpAndSettle();
        expect(player, findsNothing);

        await tester.tap(
          find
              .descendant(
                of: find.byType(CalendarEventBand),
                matching: find.textContaining('Odpoledne'),
              )
              .first,
        );
        await tester.pumpAndSettle();
        expect(find.text('player abcdefghijk on'), findsOneWidget);
        await finish(tester);
      });

      testWidgets('a day\'s matches from the board\'s header have the app\'s '
          'video control: a tap closes the list and plays the match on the '
          'kiosk', (tester) async {
        fullHd(tester);
        // The match on air (the switch off: no window by itself) and one
        // finished this morning, each with its video.
        await tester.pumpWidget(
          app(
            slots: [...onAir, fed('r', day, 'Ráno', hour: 8, video: video2)],
            results: {...playing, 'r': res('r', 'finished', 6, 2)},
          ),
        );
        await tester.pumpAndSettle();
        expect(player, findsNothing);

        final header = find
            .descendant(
              of: find.byType(BoardColumnHeader),
              matching: find.textContaining('Domácí'),
            )
            .first;
        final dialog = find.byType(AlertDialog);
        Finder inDialog(IconData icon) =>
            find.descendant(of: dialog, matching: find.byIcon(icon));
        await tester.tap(header);
        await pumpDialog(tester);
        // Live: the red camera; the recording: the play button — no trophy.
        expect(inDialog(Icons.videocam), findsOneWidget);
        expect(inDialog(Icons.play_circle_fill), findsOneWidget);
        expect(inDialog(Icons.emoji_events_outlined), findsNothing);

        await tester.tap(inDialog(Icons.videocam));
        await pumpDialog(tester);
        expect(dialog, findsNothing);
        await tester.pumpAndSettle();
        expect(find.text('player wOq9EODb8w8 on'), findsOneWidget);

        // The recording turns the window to it; its Zápis stays shut (the
        // button's tap is not the row's).
        await tester.tap(header);
        await pumpDialog(tester);
        await tester.tap(inDialog(Icons.play_circle_fill));
        await pumpDialog(tester);
        expect(dialog, findsNothing);
        await tester.pumpAndSettle();
        expect(find.text('Zápis zápasu zatím není k dispozici.'), findsNothing);
        expect(find.text('player abcdefghijk on'), findsOneWidget);
        await finish(tester);
      });

      testWidgets('with the animations off the live badge in the day\'s list '
          'stays still', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(slots: onAir, results: playing, animations: false),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find
              .descendant(
                of: find.byType(BoardColumnHeader),
                matching: find.textContaining('Domácí'),
              )
              .first,
        );
        // Settles: nothing repeats.
        await tester.pumpAndSettle();
        final badge = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(MatchLeading),
        );
        expect(
          find.descendant(of: badge, matching: find.byIcon(Icons.videocam)),
          findsOneWidget,
        );
        expect(
          (tester.state(badge) as dynamic).debugHasPulseController,
          isFalse,
        );
        await finish(tester);
      });

      testWidgets('a live stream closed by the × does not open by itself '
          'again; its ▶ does', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(stream: true, slots: onAir, results: playing, drawerOpen: true),
        );
        await tester.pumpAndSettle();
        expect(find.text('player wOq9EODb8w8 on'), findsOneWidget);

        await tester.tap(find.byTooltip('Zavřít stream'));
        await tester.pumpAndSettle();
        expect(player, findsNothing);

        await tester.tap(find.byTooltip('Sledovat živě'));
        await tester.pumpAndSettle();
        expect(find.text('player wOq9EODb8w8 on'), findsOneWidget);
        await finish(tester);
      });

      testWidgets('the match being played in the drawer has the live badge '
          'of everywhere else — pulsing, still with the animations off; a '
          'tap opens its stream', (tester) async {
        fullHd(tester);
        // Played, with players: the drawer shows it across.
        Widget kiosk({required bool animations}) => app(
          slots: onAir,
          results: playing,
          lineups: {'m': lineup},
          animations: animations,
        );
        final badge = find.descendant(
          of: find.byType(KioskPanelView),
          matching: find.byType(MatchLeading),
        );
        bool pulsing(WidgetTester tester) =>
            (tester.state(badge) as dynamic).debugHasPulseController as bool;

        await tester.pumpWidget(kiosk(animations: true));
        // The ring repeats: frames by hand, pumpAndSettle would wait forever.
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(liveView, findsOneWidget);
        expect(badge, findsOneWidget);
        expect(
          find.descendant(of: badge, matching: find.byIcon(Icons.videocam)),
          findsOneWidget,
        );
        expect(pulsing(tester), isTrue);
        expect(player, findsNothing);

        await tester.tap(badge);
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.text('player wOq9EODb8w8 on'), findsOneWidget);
        await finish(tester);

        await tester.pumpWidget(kiosk(animations: false));
        await tester.pumpAndSettle();
        expect(badge, findsOneWidget);
        expect(pulsing(tester), isFalse);
        await finish(tester);
      });

      testWidgets('the live view\'s header: how old the score is sits at the '
          'right edge — against the live badge, or alone — and gives way '
          'only when nothing is left', (tester) async {
        fullHd(tester);
        final inDrawer = find.byType(KioskPanelView);
        // „⟳ před … dny“: its icon and text, in a row of their own.
        final age = find
            .ancestor(
              of: find.descendant(
                of: inDrawer,
                matching: find.byIcon(Icons.refresh),
              ),
              matching: find.byType(Row),
            )
            .first;
        final ageText = find.descendant(
          of: age,
          matching: find.textContaining('před'),
        );
        final badge = find.descendant(
          of: inDrawer,
          matching: find.byType(MatchLeading),
        );
        // The header row ends where the drawer does, less its padding.
        double rowEnd() => tester.getTopRight(inDrawer).dx - 12;
        bool cut() => tester
            .renderObject<RenderParagraph>(
              find.descendant(of: ageText, matching: find.byType(RichText)),
            )
            .didExceedMaxLines;

        // With the live badge: the age right beside it, the badge at the end.
        await tester.pumpWidget(
          app(
            slots: onAir,
            results: playing,
            lineups: {'m': lineup},
            animations: false,
          ),
        );
        await tester.pumpAndSettle();
        expect(liveView, findsOneWidget);
        expect(tester.getTopRight(badge).dx, closeTo(rowEnd(), 0.5));
        expect(
          tester.getTopRight(age).dx,
          closeTo(tester.getTopLeft(badge).dx - 4, 0.5),
        );
        expect(cut(), isFalse);
        await finish(tester);

        // No video: the age at the end itself.
        await tester.pumpWidget(
          app(
            slots: [fed('m', day, 'Domácí', hour: 11)],
            results: playing,
            lineups: {'m': lineup},
            animations: false,
          ),
        );
        await tester.pumpAndSettle();
        expect(liveView, findsOneWidget);
        expect(badge, findsNothing);
        expect(tester.getTopRight(age).dx, closeTo(rowEnd(), 0.5));
        expect(cut(), isFalse);
        await finish(tester);

        // A one-column drawer, two matches taking turns: back, the dots,
        // the age and the badge do not all fit. The age gives way — but
        // only by what is missing: no gap left on either side of it, and
        // the badge whole at the end.
        await tester.pumpWidget(
          app(
            slots: [
              ...onAir,
              fed('n', day, 'Druzí', hour: 11, video: video2),
            ],
            results: {...playing, 'n': res('n', 'in_progress', 1, 2)},
            lineups: {
              'm': lineup,
              'n': [
                for (final side in ['home', 'away'])
                  MatchPlayerResult(
                    id: 'n-$side',
                    matchId: 'n',
                    side: side,
                    position: 1,
                    playerName: side,
                    total: 400,
                  ),
              ],
            },
            drawerColumns: 1,
            animations: false,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final dots = find.descendant(
          of: inDrawer,
          matching: find.byIcon(Icons.lock_open),
        );
        expect(dots, findsOneWidget);
        expect(cut(), isTrue);
        expect(tester.getTopRight(badge).dx, closeTo(rowEnd(), 0.5));
        expect(
          tester.getTopRight(age).dx,
          closeTo(tester.getTopLeft(badge).dx - 4, 0.5),
        );
        // The dots' tap target (the lock and the dots, padded) ends where
        // the age's own (the refresh button, padded on its left) begins.
        final dotsTarget = find
            .ancestor(of: dots, matching: find.byType(GestureDetector))
            .first;
        final ageTarget = find
            .ancestor(of: age, matching: find.byType(InkWell))
            .first;
        expect(
          tester.getTopLeft(ageTarget).dx,
          closeTo(tester.getTopRight(dotsTarget).dx, 0.5),
        );
        await finish(tester);
      });

      testWidgets('the end of the video closes its window', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(stream: true, slots: onAir, results: playing),
        );
        await tester.pumpAndSettle();
        expect(player, findsOneWidget);

        streamEnded['wOq9EODb8w8']!();
        await tester.pumpAndSettle();
        expect(player, findsNothing);
        await finish(tester);
      });

      testWidgets('streams off: no window by itself, no ▶ at the drawer\'s '
          'matches, no button in the Zápis', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            streamEnabled: false,
            stream: true,
            slots: [...onAir, recorded.first],
            results: {...playing, ...decided},
            lineups: {'f1': lineup},
            drawerOpen: true,
          ),
        );
        await tester.pumpAndSettle();
        expect(drawerText('6 : 2'), findsOneWidget);
        expect(player, findsNothing);
        expect(find.byTooltip('Sledovat živě'), findsNothing);
        expect(find.byTooltip('Přehrát záznam'), findsNothing);
        expect(
          find.descendant(
            of: find.byType(KioskPanelView),
            matching: find.byIcon(Icons.play_circle_outline),
          ),
          findsNothing,
        );

        await tester.tap(find.text('6 : 2'));
        await tester.pumpAndSettle();
        expect(find.byType(LegacyScoreSheetPage), findsOneWidget);
        expect(find.text('Přehrát záznam'), findsNothing);
        expect(find.byIcon(Icons.play_circle_outline), findsNothing);
        await finish(tester);
      });

      testWidgets('streams off: the match being played in the drawer has no '
          'live badge', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            streamEnabled: false,
            slots: onAir,
            results: playing,
            lineups: {'m': lineup},
          ),
        );
        await tester.pumpAndSettle();
        expect(liveView, findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(KioskPanelView),
            matching: find.byType(MatchLeading),
          ),
          findsNothing,
        );
        expect(player, findsNothing);
        await finish(tester);
      });

      testWidgets('streams off: a day\'s matches from the board\'s header '
          'show the trophy, no video control', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            streamEnabled: false,
            slots: [...onAir, fed('r', day, 'Ráno', hour: 8, video: video2)],
            results: {...playing, 'r': res('r', 'finished', 6, 2)},
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find
              .descendant(
                of: find.byType(BoardColumnHeader),
                matching: find.textContaining('Domácí'),
              )
              .first,
        );
        await tester.pumpAndSettle();
        final dialog = find.byType(AlertDialog);
        Finder inDialog(IconData icon) =>
            find.descendant(of: dialog, matching: find.byIcon(icon));
        expect(inDialog(Icons.emoji_events_outlined), findsNWidgets(2));
        expect(inDialog(Icons.videocam), findsNothing);
        expect(inDialog(Icons.play_circle_fill), findsNothing);

        await tester.tap(find.text('Zavřít'));
        await tester.pumpAndSettle();
        expect(player, findsNothing);
        await finish(tester);
      });

      testWidgets('streams off: a tap on today\'s match without a score, but '
          'with a video, does nothing — in the header and on the board',
          (tester) async {
        fullHd(tester);
        final later = [fed('l', day, 'Odpoledne', hour: 15, video: video2)];
        await tester.pumpWidget(app(streamEnabled: false, slots: later));
        await tester.pumpAndSettle();

        await tester.tap(
          find.textContaining('Odpoledne – Soupeř · 15:00').first,
        );
        await tester.pumpAndSettle();
        expect(player, findsNothing);
        expect(find.byType(AlertDialog), findsNothing);

        await tester.tap(
          find
              .descendant(
                of: find.byType(CalendarEventBand),
                matching: find.textContaining('Odpoledne'),
              )
              .first,
        );
        await tester.pumpAndSettle();
        expect(player, findsNothing);
        expect(find.byType(AlertDialog), findsNothing);
        await finish(tester);
      });

      testWidgets('the admin switching the streams off closes every window — '
          'the match on air and a visitor\'s; on again, only the one on air '
          'comes back', (tester) async {
        fullHd(tester);
        final on = StreamController<bool>();
        addTearDown(on.close);
        await tester.pumpWidget(
          app(
            stream: true,
            streamMax: 2,
            slots: [...onAir, recorded.first],
            results: {...playing, ...decided},
            drawerOpen: true,
            streamSwitch: on.stream,
          ),
        );
        on.add(true);
        await tester.pumpAndSettle();
        expect(find.textContaining('player wOq9EODb8w8'), findsOneWidget);
        await tester.tap(find.byTooltip('Přehrát záznam'));
        await tester.pumpAndSettle();
        expect(find.textContaining('player abcdefghijk'), findsOneWidget);

        on.add(false);
        await tester.pumpAndSettle();
        expect(player, findsNothing);
        expect(find.byTooltip('Přehrát záznam'), findsNothing);

        // What the visitor opened is forgotten with the switch.
        on.add(true);
        await tester.pumpAndSettle();
        expect(find.textContaining('player wOq9EODb8w8'), findsOneWidget);
        expect(find.textContaining('player abcdefghijk'), findsNothing);
        await finish(tester);
      });

      testWidgets('one window at once: a ▶ turns it to the new stream',
          (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            stream: true,
            slots: [...onAir, recorded.first],
            results: {...playing, ...decided},
            drawerOpen: true,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('player wOq9EODb8w8 on'), findsOneWidget);

        await tester.tap(find.byTooltip('Přehrát záznam'));
        await tester.pumpAndSettle();
        expect(player, findsOneWidget);
        expect(find.text('player abcdefghijk on'), findsOneWidget);
        expect(find.text('2/2'), findsOneWidget);
        await finish(tester);
      });

      testWidgets('two windows at once: each stream its own, one above the '
          'other; what a visitor opens comes before the live one',
          (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            stream: true,
            streamMax: 2,
            slots: [...onAir, ...recorded],
            results: {...playing, ...decided},
            drawerOpen: true,
          ),
        );
        await tester.pumpAndSettle();
        final live = find.text('player wOq9EODb8w8 on');
        // The list has the later match higher up: first ▶ = f2.
        final first = find.text('player ABCDEFGHIJK on');
        final second = find.text('player abcdefghijk on');
        expect(live, findsOneWidget);

        await tester.tap(find.byTooltip('Přehrát záznam').first);
        await tester.pumpAndSettle();
        expect(player, findsNWidgets(2));
        expect(live, findsOneWidget);
        expect(first, findsOneWidget);
        // The admin's corner (bottom left), then the one above it — the
        // drawer's side last.
        expect(tester.getRect(first).left, tester.getRect(live).left);
        expect(tester.getRect(first).bottom,
            lessThan(tester.getRect(live).top));

        // A second recording: the live one gives way, not the first.
        await tester.tap(find.byTooltip('Přehrát záznam').last);
        await tester.pumpAndSettle();
        expect(player, findsNWidgets(2));
        expect(live, findsNothing);
        expect(first, findsOneWidget);
        expect(second, findsOneWidget);

        // Closed, it makes room: the live one is back.
        await tester.tap(find.byTooltip('Zavřít stream').last);
        await tester.pumpAndSettle();
        expect(player, findsNWidgets(2));
        expect(live, findsOneWidget);
        await finish(tester);
      });

      KioskStreamsNotifier streams(WidgetTester tester) =>
          ProviderScope.containerOf(tester.element(find.byType(KioskShell)))
              .read(kioskStreamsProvider.notifier);
      // Two windows: the live match by itself, a recording by hand.
      Widget twoWindows({bool stream = true}) => app(
        stream: stream,
        streamMax: 2,
        slots: [...onAir, ...recorded],
        results: {...playing, ...decided},
        drawerOpen: true,
      );

      testWidgets('a maximized window collapsed gives the area back: the '
          'other window comes out', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(twoWindows());
        await tester.pumpAndSettle();
        streams(tester).open('f1');
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Na celou obrazovku').first);
        await tester.pumpAndSettle();
        expect(find.byTooltip('Zavřít stream'), findsOneWidget);

        await tester.tap(find.byTooltip('Sbalit'));
        await tester.pumpAndSettle();
        // The pill's × and the other window's.
        expect(find.byTooltip('Zavřít stream'), findsNWidgets(2));
        final other = find.text('player abcdefghijk on');
        expect(other, findsOneWidget);
        expect(tester.getRect(other).width, greaterThan(1));
        await finish(tester);
      });

      testWidgets('a ▶ at a stream hidden under a maximized window brings it '
          'out', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(twoWindows());
        await tester.pumpAndSettle();
        streams(tester).open('f1');
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Na celou obrazovku').first);
        await tester.pumpAndSettle();
        expect(find.byTooltip('Zavřít stream'), findsOneWidget);

        streams(tester).open('f1');
        await tester.pumpAndSettle();
        expect(find.byTooltip('Zavřít stream'), findsNWidgets(2));
        expect(find.byTooltip('Zmenšit'), findsNothing);
        expect(find.text('player abcdefghijk on'), findsOneWidget);
        await finish(tester);
      });

      testWidgets('past the windows, the oldest opened closes for good: '
          'closing a newer one does not bring it back', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(twoWindows(stream: false));
        await tester.pumpAndSettle();
        streams(tester)
          ..open('m')
          ..open('f1')
          ..open('f2');
        await tester.pumpAndSettle();
        expect(player, findsNWidgets(2));
        expect(find.text('player wOq9EODb8w8 on'), findsNothing);

        // The newest (f2, the later window) closes: only f1 stays.
        await tester.tap(find.byTooltip('Zavřít stream').last);
        await tester.pumpAndSettle();
        expect(player, findsOneWidget);
        expect(find.text('player abcdefghijk on'), findsOneWidget);
        await finish(tester);
      });

      testWidgets('a new window takes the corner a closed one gave up',
          (tester) async {
        fullHd(tester);
        await tester.pumpWidget(twoWindows(stream: false));
        await tester.pumpAndSettle();
        streams(tester).open('f1');
        await tester.pumpAndSettle();
        final corner = tester.getRect(find.text('player abcdefghijk on'));
        streams(tester).open('f2');
        await tester.pumpAndSettle();
        final above = tester.getRect(find.text('player ABCDEFGHIJK on'));
        expect(above.bottom, lessThan(corner.top));

        await tester.tap(find.byTooltip('Zavřít stream').first);
        await tester.pumpAndSettle();
        streams(tester).open('m');
        await tester.pumpAndSettle();
        expect(tester.getRect(find.text('player wOq9EODb8w8 on')), corner);
        expect(tester.getRect(find.text('player ABCDEFGHIJK on')), above);
        await finish(tester);
      });

      testWidgets('a player under another window takes no touches, nor any '
          'while a window is dragged', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(twoWindows(stream: false));
        await tester.pumpAndSettle();
        streams(tester)
          ..open('f1')
          ..open('f2');
        await tester.pumpAndSettle();
        expect(find.text('player abcdefghijk on'), findsOneWidget);
        expect(find.text('player ABCDEFGHIJK on'), findsOneWidget);
        final upper = find.descendant(
          of: find.byType(KioskStreamWindow),
          matching: find.text('Včera – Soupeř'),
        );

        final drag = await tester.startGesture(tester.getCenter(upper));
        await drag.moveBy(const Offset(0, 100));
        await tester.pump();
        await drag.moveBy(const Offset(0, 100));
        await tester.pump();
        expect(find.text('player abcdefghijk off'), findsOneWidget);
        expect(find.text('player ABCDEFGHIJK off'), findsOneWidget);
        await drag.up();
        await tester.pumpAndSettle();
        // f2's window now lies over f1's: f1 waits, f2 plays on.
        expect(find.text('player abcdefghijk off'), findsOneWidget);
        expect(find.text('player ABCDEFGHIJK on'), findsOneWidget);

        await tester.drag(upper, const Offset(0, -200));
        await tester.pumpAndSettle();
        expect(find.text('player abcdefghijk on'), findsOneWidget);
        await finish(tester);
      });

      testWidgets('one of two windows maximized: the other hides, its player '
          'running on in a pixel', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            stream: true,
            streamMax: 2,
            slots: [...onAir, recorded.first],
            results: {...playing, ...decided},
            drawerOpen: true,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Přehrát záznam'));
        await tester.pumpAndSettle();
        final before = tester.getRect(find.text('player abcdefghijk on'));

        await tester.tap(find.byTooltip('Na celou obrazovku').first);
        await tester.pumpAndSettle();
        expect(find.byTooltip('Zavřít stream'), findsOneWidget);
        expect(
          tester.getRect(find.text('player abcdefghijk off')).size,
          const Size(1, 1),
        );

        await tester.tap(find.byTooltip('Zmenšit'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Zavřít stream'), findsNWidgets(2));
        expect(tester.getRect(find.text('player abcdefghijk on')), before);
        await finish(tester);
      });
    });

    testWidgets('the name day is a module of the status bar between the '
        'clock and „Rezervovat“, its title over the name — only when the '
        'admin wants it', (tester) async {
      fullHd(tester);
      await tester.pumpWidget(app(nameday: true));
      await tester.pumpAndSettle();
      // Thursday 8 October: Věra.
      final title = find.text('Svátek slaví:');
      final nameday = find.text('Věra');
      expect(title, findsOneWidget);
      expect(nameday, findsOneWidget);
      expect(
        tester.getRect(title).bottom,
        lessThanOrEqualTo(tester.getRect(nameday).top),
      );
      expect(tester.getRect(title).left, tester.getRect(nameday).left);
      final clock = tester.getRect(
        find.ancestor(
          of: find.text('12:00'),
          matching: find.byType(KioskHeaderModuleFrame),
        ),
      );
      final module = tester.getRect(find.byType(KioskNameDayModule));
      expect(module.left, greaterThanOrEqualTo(clock.right));
      expect(
        module.right,
        lessThan(tester.getTopLeft(find.text(kioskReserveLabel)).dx),
      );
      await finish(tester);

      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.byType(KioskNameDayModule), findsNothing);
      expect(find.text('Svátek slaví:'), findsNothing);
      await finish(tester);
    });

    testWidgets('the admin\'s warning sits in the status bar between the '
        'clock and „Rezervovat“, with its icon; none, nothing', (tester) async {
      fullHd(tester);
      await tester.pumpWidget(app(warning: 'Dráha 3 je mimo provoz.'));
      await tester.pumpAndSettle();
      final text = find.text('Dráha 3 je mimo provoz.');
      final icon = find.byIcon(Icons.warning_amber_rounded);
      expect(text, findsOneWidget);
      expect(icon, findsOneWidget);
      expect(
        tester.getTopLeft(icon).dx,
        greaterThan(tester.getTopRight(find.text('12:00')).dx),
      );
      expect(
        tester.getTopRight(text).dx,
        lessThan(tester.getTopLeft(find.text(kioskReserveLabel)).dx),
      );
      await finish(tester);

      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(icon, findsNothing);
      await finish(tester);
    });

    testWidgets('while a warning hangs, the rest of the status bar steps '
        'aside: no notice headline, no today\'s matches beside it', (
      tester,
    ) async {
      fullHd(tester);
      int matchLabels() =>
          findEmojiTextContaining('Domácí – Soupeř').evaluate().length;
      await tester.pumpWidget(
        app(
          notices: [notice('1', 'Brigáda')],
          slots: [fed('m', day, 'Domácí')],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(KioskHeadline), findsOneWidget);
      final without = matchLabels();
      await finish(tester);

      await tester.pumpWidget(
        app(
          notices: [notice('1', 'Brigáda')],
          slots: [fed('m', day, 'Domácí')],
          warning: 'Dráha 3 je mimo provoz.',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Dráha 3 je mimo provoz.'), findsOneWidget);
      expect(find.byType(KioskHeadline), findsNothing);
      // The board's own day header still names the match; the bar does not.
      expect(matchLabels(), without - 1);
      await finish(tester);
    });

    testWidgets('while a warning hangs, the weather and the name day step '
        'aside too — every module but the clock', (tester) async {
      fullHd(tester);
      final forecast = KioskWeather(
        temperature: 14,
        kind: WeatherKind.clear,
        isDay: true,
        fetchedAt: nowAt,
      );
      await tester.pumpWidget(
        app(nameday: true, weather: true, forecast: forecast),
      );
      await tester.pumpAndSettle();
      expect(find.byType(KioskNameDayModule), findsOneWidget);
      expect(find.byType(KioskWeatherModule), findsOneWidget);
      await finish(tester);

      await tester.pumpWidget(
        app(
          nameday: true,
          weather: true,
          forecast: forecast,
          warning: 'Dráha 3 je mimo provoz.',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Dráha 3 je mimo provoz.'), findsOneWidget);
      expect(find.byType(KioskNameDayModule), findsNothing);
      expect(find.byType(KioskWeatherModule), findsNothing);
      // The clock stays: one module, the date over the time.
      expect(find.byType(KioskHeaderModuleFrame), findsOneWidget);
      expect(find.text('12:00'), findsOneWidget);
      await finish(tester);
    });

    group('the header\'s modules (0082)', () {
      final forecast = KioskWeather(
        temperature: 14,
        kind: WeatherKind.clear,
        isDay: true,
        max: 16,
        min: 7,
        fetchedAt: nowAt,
      );
      final current = DutyPeriod(
        id: 'now',
        startsOn: Day(2026, 10, 5),
        endsOn: Day(2026, 10, 11),
      );
      final serving = [
        DutyAssignment(periodId: 'now', userId: anna.id),
        DutyAssignment(periodId: 'now', userId: petr.id),
      ];
      // A home and an away match today.
      final away = PrioritySlot(
        type: PrioritySlot.fallbackMatchType,
        id: 'a',
        date: day,
        startsAt: const HourMinute(18, 0),
        endsAt: const HourMinute(21, 0),
        homeTeam: 'Hosté',
        awayTeam: 'Soupeř',
        isAway: true,
        importKey: 'cka:a',
      );
      final homeLabel = find.descendant(
        of: find.byType(Wrap),
        matching: findEmojiTextContaining('Domácí – Soupeř'),
      );
      final awayLabel = find.descendant(
        of: find.byType(Wrap),
        matching: findEmojiTextContaining('Hosté – Soupeř'),
      );
      Rect rectOf(WidgetTester tester, Type module) =>
          tester.getRect(find.byType(module));
      Rect clockOf(WidgetTester tester) => tester.getRect(
        find.ancestor(
          of: find.text('12:00'),
          matching: find.byType(KioskHeaderModuleFrame),
        ),
      );

      testWidgets('every module on: the titles on one line, the values on '
          'the next; the left ones after the clock and the right ones '
          'before „Rezervovat“, each side in the admin\'s order', (
        tester,
      ) async {
        fullHd(tester);
        final header = KioskHeader.defaults
            .withSide(KioskHeaderModule.weather, PanelSide.left)
            .withSide(KioskHeaderModule.nameday, PanelSide.left)
            .withSide(KioskHeaderModule.duty, PanelSide.right)
            .withSide(KioskHeaderModule.notices, PanelSide.right)
            .moved(KioskHeaderModule.nameday, -1)
            .moved(KioskHeaderModule.notices, -1);
        await tester.pumpWidget(
          app(
            header: header,
            forecast: forecast,
            weatherTitle: 'Brno',
            notices: [notice('1', 'Brigáda')],
            slots: [fed('m', day, 'Domácí'), away],
            dutyPeriods: [current],
            dutyAssignments: serving,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        final titles = [
          'Dnes je čtvrtek 8. 10.',
          'Svátek slaví:',
          'Brno:',
          'Nástěnka:',
          'Službu mají:',
        ];
        final values = [
          find.text('12:00'),
          find.text('Věra'),
          find.text('14°'),
          find.descendant(
            of: find.byType(KioskHeadline),
            matching: find.text('Brigáda'),
          ),
          find.text('AA Hráč a PP Hráč'),
        ];
        final titleTop = tester.getRect(find.text(titles.first)).top;
        final valueMiddle = tester.getRect(values.first).center.dy;
        for (final t in titles) {
          expect(
            tester.getRect(find.text(t)).top,
            closeTo(titleTop, 0.5),
            reason: t,
          );
        }
        for (final v in values) {
          expect(v, findsOneWidget);
          expect(
            tester.getRect(v).center.dy,
            closeTo(valueMiddle, 0.5),
            reason: '$v',
          );
          expect(tester.getRect(v).top, greaterThan(titleTop));
        }
        // Left to right: clock, name day, weather (moved before it), the
        // matches, the notices (moved before the duty), the duty, the
        // button.
        final order = [
          clockOf(tester),
          rectOf(tester, KioskNameDayModule),
          rectOf(tester, KioskWeatherModule),
          tester.getRect(find.byType(Wrap).first),
          tester.getRect(
            find.ancestor(
              of: find.byType(KioskHeadline),
              matching: find.byType(KioskHeaderModuleFrame),
            ),
          ),
          rectOf(tester, KioskDutyModule),
          tester.getRect(find.text(kioskReserveLabel)),
        ];
        for (var i = 1; i < order.length; i++) {
          expect(
            order[i].left,
            greaterThanOrEqualTo(order[i - 1].right),
            reason: 'item $i',
          );
        }
        // Modules [kioskHeaderGap] apart.
        expect(
          order[1].left - order[0].right,
          closeTo(kioskHeaderGap, 0.5),
        );
        expect(
          order[2].left - order[1].right,
          closeTo(kioskHeaderGap, 0.5),
        );
        expect(
          order[5].left - order[4].right,
          closeTo(kioskHeaderGap, 0.5),
        );

        await finish(tester);
      });

      testWidgets('every value fits its box, at text scale 1 and 2: none is '
          'cut to the box\'s height — the clock, cut so, sat lower than the '
          'other values', (tester) async {
        fullHd(tester);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final header = KioskHeader.defaults
            .withSide(KioskHeaderModule.weather, PanelSide.left)
            .withSide(KioskHeaderModule.nameday, PanelSide.left)
            .withSide(KioskHeaderModule.duty, PanelSide.right)
            .withSide(KioskHeaderModule.notices, PanelSide.right);
        final values = {
          'clock': find.text('12:00'),
          'name day': find.text('Věra'),
          'weather': find.text('14°'),
          'notices': find.descendant(
            of: find.byType(KioskHeadline),
            matching: find.text('Brigáda'),
          ),
          'duty': find.text('AA Hráč a PP Hráč'),
        };
        for (final scale in [1.0, 2.0]) {
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          await tester.pumpWidget(
            app(
              header: header,
              forecast: forecast,
              notices: [notice('1', 'Brigáda')],
              dutyPeriods: [current],
              dutyAssignments: serving,
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          for (final MapEntry(key: name, value: value) in values.entries) {
            expect(value, findsOneWidget, reason: name);
            final text = tester.renderObject<RenderParagraph>(
              find.descendant(of: value, matching: find.byType(RichText)),
            );
            // The line its text needs, against the height it was given.
            expect(
              text.size.height,
              greaterThanOrEqualTo(
                text.getMaxIntrinsicHeight(text.size.width) - 0.01,
              ),
              reason: '$name at text scale $scale',
            );
          }
          await finish(tester);
        }
      });

      testWidgets('the clock is a module too: the date over the time, '
          'always first', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(app());
        await tester.pumpAndSettle();
        final date = find.text('Dnes je čtvrtek 8. 10.');
        final time = find.text('12:00');
        expect(date, findsOneWidget);
        expect(
          tester.getRect(date).bottom,
          lessThanOrEqualTo(tester.getRect(time).top),
        );
        expect(tester.getRect(date).left, tester.getRect(time).left);
        // Its title in the modules' style.
        expect(tester.widget<Text>(date).style?.fontSize, 13);

        await finish(tester);
      });

      testWidgets('home and away today: the home matches on one line, the '
          'away ones under them, both in the bar\'s middle', (
        tester,
      ) async {
        fullHd(tester);
        await tester.pumpWidget(app(slots: [fed('m', day, 'Domácí'), away]));
        await tester.pumpAndSettle();
        expect(homeLabel, findsOneWidget);
        expect(awayLabel, findsOneWidget);
        final home = tester.getRect(homeLabel);
        final aways = tester.getRect(awayLabel);
        expect(home.bottom, lessThanOrEqualTo(aways.top));
        expect(home.center.dx, closeTo(aways.center.dx, 1));
        // In the bar's middle: between the clock and „Rezervovat“.
        expect(home.left, greaterThan(clockOf(tester).right));
        expect(
          home.right,
          lessThan(tester.getRect(find.text(kioskReserveLabel)).left),
        );
        await finish(tester);

        // Only away matches: one line, no gap above it.
        await tester.pumpWidget(app(slots: [away]));
        await tester.pumpAndSettle();
        expect(homeLabel, findsNothing);
        expect(awayLabel, findsOneWidget);
        await finish(tester);
      });

      testWidgets('a module with nothing to say leaves no gap: the next one '
          'closes up', (tester) async {
        fullHd(tester);
        final header = KioskHeader.defaults
            .withSide(KioskHeaderModule.weather, PanelSide.left)
            .withSide(KioskHeaderModule.duty, PanelSide.left)
            .withSide(KioskHeaderModule.nameday, PanelSide.left)
            .moved(KioskHeaderModule.nameday, 1);
        // Weather, duty, name day — nobody serves today.
        await tester.pumpWidget(
          app(
            header: header,
            forecast: forecast,
            dutyPeriods: [current],
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(KioskDutyModule), findsNothing);
        expect(
          rectOf(tester, KioskNameDayModule).left -
              rectOf(tester, KioskWeatherModule).right,
          closeTo(kioskHeaderGap, 0.5),
        );
        await finish(tester);

        // A stale forecast: no weather module, the name day right after
        // the clock.
        await tester.pumpWidget(
          app(
            header: header,
            forecast: KioskWeather(
              temperature: 14,
              kind: WeatherKind.clear,
              isDay: true,
              fetchedAt: nowAt.subtract(const Duration(hours: 4)),
            ),
            dutyPeriods: [current],
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(KioskWeatherModule), findsNothing);
        expect(
          rectOf(tester, KioskNameDayModule).left - clockOf(tester).right,
          closeTo(kioskHeaderGap, 0.5),
        );
        await finish(tester);
      });

      testWidgets('neither a centre nor the notices: the right modules stay '
          'on the right, before „Rezervovat“', (tester) async {
        fullHd(tester);
        final header = KioskHeader.defaults
            .withSide(KioskHeaderModule.weather, PanelSide.right)
            .withSide(KioskHeaderModule.nameday, PanelSide.right)
            .withSide(KioskHeaderModule.notices, PanelSide.off);
        // An open day without a match: no info line, nothing in the centre.
        await tester.pumpWidget(app(header: header, forecast: forecast));
        await tester.pumpAndSettle();
        expect(find.byType(KioskHeadline), findsNothing);
        expect(find.byType(Wrap), findsNothing);
        expect(findEmojiTextContaining('Další trénink'), findsNothing);
        final button = tester.getRect(find.byType(GradientButton));
        expect(
          rectOf(tester, KioskNameDayModule).right,
          closeTo(button.left - 16, 0.5),
        );
        expect(
          rectOf(tester, KioskNameDayModule).left -
              rectOf(tester, KioskWeatherModule).right,
          closeTo(kioskHeaderGap, 0.5),
        );
        // Not right after the clock.
        expect(
          rectOf(tester, KioskWeatherModule).left,
          greaterThan(clockOf(tester).right + 200),
        );
        await finish(tester);
      });

      testWidgets('the weather module: the admin\'s title, „Počasí“ without '
          'one; a tap shows the source in its place', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(app(weather: true, forecast: forecast));
        await tester.pumpAndSettle();
        expect(find.text(kioskWeatherTitleOf(null)), findsOneWidget);
        expect(find.text(weatherSource), findsNothing);
        await tester.tap(find.text('14°'));
        await tester.pump();
        expect(find.text(weatherSource), findsOneWidget);
        expect(find.text(kioskWeatherTitleOf(null)), findsNothing);
        await tester.pump(KioskWeatherModule.sourceFor);
        await tester.pump();
        expect(find.text(kioskWeatherTitleOf(null)), findsOneWidget);
        await finish(tester);

        await tester.pumpWidget(
          app(weather: true, forecast: forecast, weatherTitle: 'Brno'),
        );
        await tester.pumpAndSettle();
        expect(find.text('Brno:'), findsOneWidget);
        await finish(tester);
      });

      testWidgets('the weather shows the values the admin picked beside the '
          'temperature; the high and low by default', (tester) async {
        fullHd(tester);
        final windy = KioskWeather(
          temperature: 14,
          kind: WeatherKind.clear,
          isDay: true,
          max: 16,
          min: 7,
          feelsLike: 11.2,
          wind: 18,
          gusts: 35,
          fetchedAt: nowAt,
        );
        await tester.pumpWidget(app(weather: true, forecast: windy));
        await tester.pumpAndSettle();
        expect(find.text('16° / 7°'), findsOneWidget);
        expect(find.textContaining('pocitově'), findsNothing);
        expect(find.byIcon(Icons.air), findsNothing);
        await finish(tester);

        await tester.pumpWidget(
          app(
            weather: true,
            forecast: windy,
            weatherItems: {KioskWeatherItem.feels, KioskWeatherItem.wind},
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('14°'), findsOneWidget);
        expect(find.text('16° / 7°'), findsNothing);
        expect(find.text('pocitově 11°'), findsOneWidget);
        expect(find.text('18 km/h, nárazy 35'), findsOneWidget);
        // Wider than a name may be, still within its share.
        expect(
          rectOf(tester, KioskWeatherModule).width,
          lessThanOrEqualTo(1920 * kioskHeaderWeatherShare),
        );
        await finish(tester);
      });

      testWidgets('the busiest header: every value of the weather beside '
          'the name day, the duty, the matches and the notices — cut to '
          'fit, the weather keeps its larger share', (tester) async {
        fullHd(tester);
        final header = KioskHeader.defaults
            .withSide(KioskHeaderModule.weather, PanelSide.left)
            .withSide(KioskHeaderModule.nameday, PanelSide.left)
            .withSide(KioskHeaderModule.duty, PanelSide.left)
            .withSide(KioskHeaderModule.notices, PanelSide.right);
        await tester.pumpWidget(
          app(
            header: header,
            forecast: KioskWeather(
              temperature: 14,
              kind: WeatherKind.clear,
              isDay: true,
              max: 16,
              min: 7,
              feelsLike: 11.2,
              wind: 18,
              gusts: 35,
              precipitationChance: 60,
              precipitationSum: 3.2,
              fetchedAt: nowAt,
            ),
            weatherTitle: 'Brno',
            weatherItems: KioskWeatherItem.values.toSet(),
            notices: [notice('1', 'Brigáda v sobotu od devíti')],
            dutyPeriods: [current],
            dutyAssignments: serving,
            slots: [fed('m', day, 'Domácí'), away],
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final weather = rectOf(tester, KioskWeatherModule);
        final duty = rectOf(tester, KioskDutyModule);
        // Both cut to what the centre and the notices leave: the weather,
        // whose row scales down, gets half as much again as the duty's
        // names — not an equal part.
        expect(
          tester
              .renderObject<RenderParagraph>(
                find.descendant(
                  of: find.text('AA Hráč a PP Hráč'),
                  matching: find.byType(RichText),
                ),
              )
              .didExceedMaxLines,
          isTrue,
        );
        expect(
          weather.width,
          closeTo(
            duty.width * kioskHeaderWeatherShare / kioskHeaderModuleShare,
            1,
          ),
        );
        expect(
          weather.width,
          greaterThan(rectOf(tester, KioskNameDayModule).width),
        );
        // The centre and the notices keep their room.
        expect(
          tester.getRect(homeLabel).left,
          greaterThan(weather.right),
        );
        expect(
          tester.getRect(find.byType(GradientButton)).right,
          lessThanOrEqualTo(1920),
        );
        await finish(tester);
      });

      testWidgets('a tap on a module shows: its ink paints on the module\'s '
          'own Material, above the bar\'s opaque background', (tester) async {
        fullHd(tester);
        final header = KioskHeader.defaults
            .withSide(KioskHeaderModule.weather, PanelSide.left)
            .withSide(KioskHeaderModule.duty, PanelSide.right);
        await tester.pumpWidget(
          app(
            header: header,
            forecast: forecast,
            dutyPeriods: [current],
            dutyAssignments: serving,
          ),
        );
        await tester.pumpAndSettle();
        for (final module in [KioskWeatherModule, KioskDutyModule]) {
          final ink = find.descendant(
            of: find.byType(module),
            matching: find.byType(InkWell),
          );
          expect(ink, findsOneWidget, reason: '$module');
          // The Material the ink paints on is the nearest one above it; it
          // must sit in the module, not be the Scaffold's under the bar.
          final material = find
              .ancestor(of: ink, matching: find.byType(Material))
              .first;
          expect(
            find.descendant(of: find.byType(module), matching: material),
            findsOneWidget,
            reason: '$module',
          );
          expect(
            tester.widget<Material>(material).type,
            MaterialType.transparency,
            reason: '$module',
          );
        }
        await finish(tester);
      });

      testWidgets('a narrow kiosk with large text: every module on and a '
          'home and an away match, no overflow — the modules shrink, the '
          'names and the matches are cut, „Rezervovat“ stays whole', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(1024, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final header = KioskHeader.defaults
            .withSide(KioskHeaderModule.weather, PanelSide.left)
            .withSide(KioskHeaderModule.nameday, PanelSide.left)
            .withSide(KioskHeaderModule.duty, PanelSide.left)
            .withSide(KioskHeaderModule.notices, PanelSide.right);
        await tester.pumpWidget(
          app(
            header: header,
            forecast: forecast,
            weatherTitle: 'Brno',
            notices: [notice('1', 'Brigáda v sobotu od devíti')],
            dutyPeriods: [current],
            dutyAssignments: [
              for (final p in players)
                DutyAssignment(periodId: 'now', userId: p.id),
            ],
            slots: [fed('m', day, 'Domácí'), away],
          ),
        );
        // The board's day header, listing the matches too, runs out of
        // height at this text size — as it did before 0082; only what the
        // header lays out counts here.
        final errors = <FlutterErrorDetails>[];
        final reported = FlutterError.onError;
        FlutterError.onError = errors.add;
        try {
          await tester.pumpAndSettle();
        } finally {
          FlutterError.onError = reported;
        }
        expect(
          [
            for (final e in errors)
              if (!e.toString().contains('calendar_board.dart')) e.toString(),
          ],
          isEmpty,
        );
        // Each match keeps one line, cut, home over away.
        for (final label in [homeLabel, awayLabel]) {
          expect(
            tester
                .renderObject<RenderParagraph>(
                  find.descendant(of: label, matching: find.byType(RichText)),
                )
                .didExceedMaxLines,
            isTrue,
            reason: '$label',
          );
        }
        expect(
          tester.getRect(homeLabel).bottom,
          lessThanOrEqualTo(tester.getRect(awayLabel).top),
        );
        final button = tester.getRect(find.byType(GradientButton));
        expect(button.right, lessThanOrEqualTo(1024));
        for (final (module, share) in [
          (KioskWeatherModule, kioskHeaderWeatherShare),
          (KioskNameDayModule, kioskHeaderModuleShare),
          (KioskDutyModule, kioskHeaderModuleShare),
        ]) {
          final rect = rectOf(tester, module);
          expect(
            rect.width,
            lessThanOrEqualTo(1024 * share),
            reason: '$module',
          );
          expect(rect.right, lessThan(button.left), reason: '$module');
        }
        for (final names in [
          find.textContaining('AA Hráč, BB Hráč'),
          find.text('Věra'),
        ]) {
          expect(
            tester
                .renderObject<RenderParagraph>(
                  find.descendant(of: names, matching: find.byType(RichText)),
                )
                .didExceedMaxLines,
            isTrue,
            reason: '$names',
          );
        }
        // The titles still share their line.
        expect(
          tester.getRect(find.text('Svátek slaví:')).top,
          closeTo(tester.getRect(find.text('Dnes je čtvrtek 8. 10.')).top, 0.5),
        );
        await finish(tester);
      });
    });

    testWidgets('today\'s matches in the status bar: there by default; '
        'switched off, the bar reads as on a day without a match — the '
        'warning still wins', (tester) async {
      fullHd(tester);
      // The status bar's match lines (home, away) are its only Wraps.
      final inBar = find.descendant(
        of: find.byType(Wrap),
        matching: findEmojiTextContaining('Domácí – Soupeř'),
      );
      // Thursday is no training day here: without a match, the bar says
      // when the next one is.
      final nextTraining = findEmojiTextContaining('Další trénink');
      Widget kiosk({bool todaysMatches = true, String? warning}) => app(
        slots: [fed('m', day, 'Domácí')],
        trainingWeekdays: const {1, 2, 3, 5, 6, 7},
        todaysMatches: todaysMatches,
        warning: warning,
      );

      await tester.pumpWidget(kiosk());
      await tester.pumpAndSettle();
      expect(inBar, findsOneWidget);
      expect(nextTraining, findsNothing);
      await finish(tester);

      await tester.pumpWidget(kiosk(todaysMatches: false));
      await tester.pumpAndSettle();
      expect(inBar, findsNothing);
      expect(nextTraining, findsOneWidget);
      await finish(tester);

      await tester.pumpWidget(
        kiosk(todaysMatches: false, warning: 'Dráha 3 je mimo provoz.'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Dráha 3 je mimo provoz.'), findsOneWidget);
      expect(inBar, findsNothing);
      expect(nextTraining, findsNothing);
      await finish(tester);
    });

    testWidgets('closed by default: only the button shows, tap opens it, tap '
        'closes it', (tester) async {
      fullHd(tester);
      await tester.pumpWidget(app(notices: [notice('1', 'Brigáda')]));
      await tester.pumpAndSettle();

      expect(drawerText('Brigáda'), findsNothing);
      expect(openButton, findsOneWidget);
      expect(tester.getSize(find.byType(KioskPanelView)).width, 0);

      await tester.tap(openButton);
      await tester.pumpAndSettle();
      expect(drawerText('Brigáda'), findsOneWidget);
      // Two of seven day columns over 1920 − 46 px.
      expect(
        tester.getSize(find.byType(KioskPanelView)).width,
        closeTo(2 * (1920 - 46) / 7, 0.5),
      );

      await tester.tap(closeButton);
      await tester.pumpAndSettle();
      expect(drawerText('Brigáda'), findsNothing);

      await finish(tester);
    });

    testWidgets('the drawer button says which panel it opens or closes, its '
        'arrow pointing the way the panel goes', (tester) async {
      fullHd(tester);
      await tester.pumpWidget(app(notices: [notice('1', 'Brigáda')]));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Zobrazit pravý panel'), findsOneWidget);
      expect(find.bySemanticsLabel('Zobrazit levý panel'), findsNothing);
      expect(openButton, findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Zobrazit pravý panel'));
      await tester.pumpAndSettle();
      expect(drawerText('Brigáda'), findsOneWidget);
      expect(find.bySemanticsLabel('Skrýt pravý panel'), findsOneWidget);
      expect(closeButton, findsOneWidget);
      await finish(tester);
    });

    testWidgets('the admin\'s number of days on the screen sets the column '
        'width, on the whole screen', (tester) async {
      fullHd(tester);
      double column() =>
          tester.getSize(find.byType(BoardColumnHeader).first).width;
      for (final days in [7, 4]) {
        await tester.pumpWidget(app(visibleDays: days));
        await tester.pumpAndSettle();
        // The header sits in the column with a small margin.
        final width = (1920 - 46) / days;
        expect(column(), inInclusiveRange(width - 10, width));
        await finish(tester);
      }
    });

    testWidgets('the drawer is whole day columns, at most all but one: open '
        'or closed, no day is cut at its edge', (tester) async {
      fullHd(tester);
      const column = (1920 - 46) / 6;
      Future<double> drawerFor(int columns) async {
        await tester.pumpWidget(
          app(
            notices: [notice('1', 'Brigáda')],
            visibleDays: 6,
            drawerColumns: columns,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(openButton);
        await tester.pumpAndSettle();
        final drawer = tester.getSize(find.byType(KioskPanelView)).width;
        // The columns keep their width with the drawer open.
        expect(
          tester.getSize(find.byType(BoardColumnHeader).first).width,
          inInclusiveRange(column - 10, column),
        );
        await finish(tester);
        return drawer;
      }

      expect(await drawerFor(1), closeTo(column, 0.5));
      expect(await drawerFor(2), closeTo(2 * column, 0.5));
      // More than the board has: one day stays in view.
      expect(await drawerFor(9), closeTo(5 * column, 0.5));
    });

    testWidgets('a mouse wheel counts as touching the kiosk: the idle reset '
        'comes after it', (tester) async {
      fullHd(tester);
      await tester.pumpWidget(app(drawerOpen: true, notices: [notice('1', 'Brigáda')], idleSeconds: 30));
      await tester.pumpAndSettle();
      // A visitor closes the drawer by hand…
      await tester.tap(closeButton);
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(KioskPanelView)).width, 0);
      // …the idle reset reopens it…
      await tester.pump(const Duration(seconds: 31));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(KioskPanelView)).width, greaterThan(0));
      // …and after it only a wheel moves: the reset must come again.
      await tester.tap(closeButton);
      await tester.pump(const Duration(seconds: 25));
      final wheel = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        wheel.hover(tester.getCenter(find.byType(ScheduleDayColumn).first)),
      );
      await tester.sendEventToBinding(wheel.scroll(const Offset(0, 200)));
      await tester.pump(const Duration(seconds: 20));
      // 45 s after the tap, but 20 s after the wheel: not yet.
      expect(tester.getSize(find.byType(KioskPanelView)).width, 0);
      await tester.pump(const Duration(seconds: 11));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(KioskPanelView)).width, greaterThan(0));
      await finish(tester);
    });

    testWidgets('while the day scrolls, the admin\'s font size sets the '
        'text and the rows grow with it', (tester) async {
      fullHd(tester);
      Future<({double day, double scale})> boardWith(int font) async {
        await tester.pumpWidget(app(fitDay: false, fontSize: font));
        await tester.pumpAndSettle();
        final result = (
          day: tester.getSize(find.byType(ScheduleDayColumn).first).height,
          scale: tester.widget<SlotTile>(find.byType(SlotTile).first).textScale,
        );
        await finish(tester);
        return result;
      }

      final at11 = await boardWith(11);
      final at22 = await boardWith(22);
      expect(at11.scale, 1);
      expect(at22.scale, 2);
      // Twice the text, taller rows — not twice as tall: the spacing
      // around the text stays.
      expect(at22.day, greaterThan(at11.day * 1.3));
      expect(at22.day, lessThan(at11.day * 2));
    });

    testWidgets('with the day on the screen the font follows the rows: the '
        'admin\'s size is not used', (tester) async {
      fullHd(tester);
      Future<double> scaleWith(int font) async {
        await tester.pumpWidget(app(fontSize: font));
        await tester.pumpAndSettle();
        final scale =
            tester.widget<SlotTile>(find.byType(SlotTile).first).textScale;
        await finish(tester);
        return scale;
      }

      final a = await scaleWith(9);
      final b = await scaleWith(24);
      expect(a, b);
      // Within reason: 9 to 24 px.
      expect(a * kioskRowFontRef, inInclusiveRange(9, 24));
    });

    test('a row is its line of text and the same few pixels around it; the '
        'fitted font is whatever the row leaves', () {
      expect(kioskRowHeightFor(11), closeTo(31.7, 0.1));
      expect(kioskRowHeightFor(22), closeTo(47.5, 0.1));
      // The larger the text, the more of the row it fills — at 11 px about
      // half (the old 40 px row: 0.39).
      double share(int font) => font * 1.43 / kioskRowHeightFor(font);
      expect(share(11), greaterThan(0.45));
      expect(share(22), greaterThan(share(11)));
      // Back and forth.
      for (final font in [9, 11, 16, 24]) {
        expect(kioskRowFont(kioskRowHeightFor(font)), closeTo(font, 0.001));
      }
      expect(kioskRowFont(10), 9);
      expect(kioskRowFont(400), 24);
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

    testWidgets('the admin picks the drawer width in day columns', (
      tester,
    ) async {
      fullHd(tester);
      await tester.pumpWidget(
        app(notices: [notice('1', 'Brigáda')], drawerOpen: true, drawerColumns: 3),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(KioskPanelView)).width,
        closeTo(3 * (1920 - 46) / 7, 0.5),
      );

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

      // Live mode off too: on, it keeps the matches in the panel (the match
      // being played takes over the panel that holds them, 0077).
      await tester.pumpWidget(
        app(
          notices: [notice('1', 'Brigáda')],
          slots: slots,
          drawerOpen: true,
          showMatches: false,
          liveMode: false,
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
            of: find.byType(KioskPanelView),
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
                of: find.byType(KioskPanelView),
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
        of: find.byType(KioskPanelView),
        matching: find.byType(CustomScrollView),
      );
      await tester.drag(list, const Offset(0, 200));
      await tester.pumpAndSettle();
      Finder inDrawer(String t) => find.descendant(
        of: find.byType(KioskPanelView),
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
        of: find.byType(KioskPanelView),
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
        of: find.byType(KioskPanelView),
        matching: find.byType(CustomScrollView),
      );
      final listBox = tester.getRect(list);
      Rect? rowOf(String t) {
        final f = find.descendant(
          of: find.byType(KioskPanelView),
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
          of: find.byType(KioskPanelView),
          matching: find.textContaining(t),
        );
        expect(inList('DávnýZápas'), findsNothing);

        // Drag the board two weeks back, to the match's day.
        // (From a point on the board: the first built column may lie
        // off screen, left of the cache edge.)
        for (var i = 0; i < 8 && find.textContaining('25.9.').evaluate().isEmpty; i++) {
          await tester.dragFrom(const Offset(400, 600), const Offset(900, 0));
          await tester.pumpAndSettle();
        }
        expect(find.textContaining('25.9.'), findsWidgets);

        if (follow) {
          final list = tester.getRect(
            find.descendant(
              of: find.byType(KioskPanelView),
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

    testWidgets('the match list follows the board a day at a time: a day back '
        'whose match the list shows already leaves it be; day by day it moves '
        'no further than the match that came into view', (tester) async {
      fullHd(tester);
      await tester.pumpWidget(
        app(
          slots: [
            for (var i = 1; i <= 14; i++) fed('p$i', day.addDays(-i), 'Den$i '),
            fed('n', day.addDays(2), 'Příští '),
          ],
          results: {
            for (var i = 1; i <= 14; i++) 'p$i': res('p$i', 'finished', 5, 3),
          },
          drawerOpen: true,
          showNotices: false,
          weeksBack: 2,
          weeksAhead: 1,
          pastDays: 14,
        ),
      );
      await tester.pumpAndSettle();
      final list = find.descendant(
        of: find.byType(KioskPanelView),
        matching: find.byType(CustomScrollView),
      );
      final listBox = tester.getRect(list);
      bool visible(String t) {
        final f = find.descendant(
          of: find.byType(KioskPanelView),
          matching: find.textContaining(t),
        );
        if (f.evaluate().isEmpty) return false;
        final r = tester.getRect(f.first);
        return r.top >= listBox.top - 1 && r.bottom <= listBox.bottom + 1;
      }

      double pixels() => tester
          .state<ScrollableState>(
            find.descendant(of: list, matching: find.byType(Scrollable)),
          )
          .position
          .pixels;
      final column = tester.getSize(find.byType(ScheduleDayColumn).first).width;
      // Most of a column, past the touch slop: the board snaps one day.
      Future<void> dayBack() async {
        await tester.dragFrom(const Offset(400, 600), Offset(column * 0.7 + 18, 0));
        await tester.pumpAndSettle();
      }

      // Yesterday's match is on the list already, above the coming one.
      expect(visible('Den1 '), isTrue);
      final opened = pixels();
      await dayBack();
      expect(pixels(), opened, reason: 'a day the list shows: no scroll');

      // Further back, day by day: each new match comes into view, the list
      // moving at most a row at a time — never a jump to put it on top.
      for (var i = 2; i <= 14; i++) {
        final before = pixels();
        await dayBack();
        expect(visible('Den$i '), isTrue, reason: 'day -$i');
        expect((before - pixels()).abs(), lessThanOrEqualTo(65),
            reason: 'day -$i');
      }

      await finish(tester);
    });

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
      expect(liveView, findsOneWidget);
      expect(drawerText('Brigáda'), findsNothing);
      expect(find.text('ZÁPASY'), findsNothing);

      // A visitor may close it; a minute later it is back.
      await tester.tap(closeButton);
      await tester.pumpAndSettle();
      expect(liveView, findsNothing);
      await tester.pump(const Duration(seconds: 61));
      await tester.pumpAndSettle();
      expect(liveView, findsOneWidget);

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
      expect(liveView, findsNothing);
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
      expect(liveView, findsNothing);
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
            of: find.byType(KioskPanelView),
            matching: find.textContaining(t),
          )
          .evaluate()
          .isNotEmpty;
      expect(inDrawer('Prvníci'), isTrue);
      expect(inDrawer('Druzí'), isFalse);

      // A touch in the view starts the turn over: from here on the clock
      // is the test's alone. (Settling ran it for however long the panel
      // buttons' breath took — they keep the wall clock's beat — and a
      // settle after the turn could even run past the next one.)
      final touch = await tester.startGesture(
        tester.getCenter(find.byType(KioskPanelView)),
      );
      await touch.cancel();
      await tester.pump(const Duration(milliseconds: 5900));
      expect(inDrawer('Druzí'), isFalse);
      // The turn (6 s), then the 380 ms swap.
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 500));
      expect(inDrawer('Druzí'), isTrue);
      expect(inDrawer('Prvníci'), isFalse);

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
      // The newest first: the long one, cut to its share.
      expect(drawerText('Dlouhý'), findsOneWidget);
      final before = tester.getTopLeft(find.text('ZÁPASY'));

      // It fades out over the short one's smaller block — clipped, not
      // overflowing it.
      await tester.pump(const Duration(seconds: 13));
      await tester.pumpAndSettle();
      expect(drawerText('Dlouhý'), findsNothing);
      expect(drawerText('Krátký'), findsOneWidget);
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
          // The bare sheet, as before paging (0079).
          zapisNav: KioskZapisNav.off,
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

    testWidgets('the Zápis leaves the system bars to the shell: nothing hidden '
        'on opening, nothing brought back on closing', (tester) async {
      fullHd(tester);
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method.startsWith('SystemChrome.setEnabledSystemUI')) {
            calls.add(call);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        app(
          slots: [fed('m', day.addDays(-3), 'Domácí')],
          results: {'m': res('m', 'finished', 6, 2)},
          lineups: {'m': lineup},
          drawerOpen: true,
        ),
      );
      await tester.pumpAndSettle();
      // The shell's own hold on the display, nothing else.
      final atRest = calls.length;

      await tester.tap(find.text('6 : 2'));
      await tester.pumpAndSettle();
      expect(find.byType(LegacyScoreSheetPage), findsOneWidget);
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(find.byType(LegacyScoreSheetPage), findsNothing);
      expect(calls, hasLength(atRest));

      await finish(tester);
    });

    testWidgets('at 100 % the Zápis fills the screen and has a ×', (
      tester,
    ) async {
      fullHd(tester);
      await tester.pumpWidget(
        app(
          // The bare sheet, as before paging (0079).
          zapisNav: KioskZapisNav.off,
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

    group('paging through the Zápis (0079)', () {
      // Three played matches; „Soupeř“ is the away side of all of them.
      List<PrioritySlot> played() => [
        fed('a', day.addDays(-10), 'Domácí'),
        fed('b', day.addDays(-7), 'Jiný'),
        fed('c', day.addDays(-3), 'Domácí'),
      ];
      Map<String, MatchResult> scores() => {
        'a': res('a', 'finished', 6, 2),
        'b': res('b', 'finished', 3, 5),
        'c': res('c', 'finished', 7, 1),
      };
      final teamList = find.byKey(const Key('kiosk-zapis-team-matches'));
      Finder inList(Finder f) => find.descendant(of: teamList, matching: f);
      Finder bar(String text) => find.descendant(
        of: find.byType(OutlinedButton),
        matching: find.text(text),
      );
      Finder button(IconData icon) => find.widgetWithIcon(IconButton, icon);
      bool enabled(WidgetTester tester, IconData icon) =>
          tester.widget<IconButton>(button(icon)).onPressed != null;

      testWidgets('a bar of ‹, the teams, the day, › and ×; the arrows step '
          'through the played matches in time', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            slots: played(),
            results: scores(),
            lineups: {'c': lineup},
            drawerOpen: true,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('7 : 1'));
        await tester.pumpAndSettle();
        expect(find.byType(LegacyScoreSheetPage), findsOneWidget);
        expect(bar('Domácí'), findsOneWidget);
        expect(bar('Soupeř'), findsOneWidget);
        expect(find.text(dayFull(day.addDays(-3))), findsOneWidget);
        // The teams over their halves of the sheet, ‹ the day › between.
        final sheet = tester.getRect(find.byType(LegacyScoreSheetPage));
        final dayAt = tester.getCenter(find.text(dayFull(day.addDays(-3))));
        expect(dayAt.dx, closeTo(sheet.center.dx, 2));
        expect(tester.getCenter(bar('Domácí')).dx, lessThan(sheet.left + 250));
        expect(
          tester.getCenter(bar('Soupeř')).dx,
          greaterThan(sheet.right - 350),
        );
        expect(
          tester.getCenter(button(Icons.chevron_left)).dx,
          allOf(greaterThan(sheet.left + 250), lessThan(dayAt.dx)),
        );
        // The last one: no further.
        expect(enabled(tester, Icons.chevron_right), isFalse);
        expect(enabled(tester, Icons.chevron_left), isTrue);

        final arrowsAt = (
          tester.getCenter(button(Icons.chevron_left)),
          tester.getCenter(button(Icons.chevron_right)),
        );
        await tester.tap(button(Icons.chevron_left));
        await tester.pumpAndSettle();
        expect(bar('Jiný'), findsOneWidget);
        expect(find.text(dayFull(day.addDays(-7))), findsOneWidget);
        // Another day, the arrows where they were: the day has a box of
        // the widest day's width.
        expect(
          (
            tester.getCenter(button(Icons.chevron_left)),
            tester.getCenter(button(Icons.chevron_right)),
          ),
          arrowsAt,
        );
        // Its players are not on the site yet.
        expect(find.text('Zápis zápasu zatím není k dispozici.'), findsOneWidget);

        await tester.tap(button(Icons.chevron_left));
        await tester.pumpAndSettle();
        expect(find.text(dayFull(day.addDays(-10))), findsOneWidget);
        expect(enabled(tester, Icons.chevron_left), isFalse);

        await tester.tap(button(Icons.chevron_right));
        await tester.pumpAndSettle();
        expect(bar('Jiný'), findsOneWidget);

        // × closes it at any size.
        await tester.tap(button(Icons.close));
        await tester.pumpAndSettle();
        expect(bar('Jiný'), findsNothing);

        await finish(tester);
      });

      testWidgets('a club nickname (0080) names the teams in the bar and the '
          'list; a tap still lists that team\'s matches', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            slots: played(),
            results: scores(),
            lineups: {'c': lineup},
            drawerOpen: true,
            names: NameDisplay(const [
              Club(id: 's', name: 'Soupeř', nickname: 'Sok'),
              Club(id: 'd', name: 'Domácí', nickname: 'Dom'),
            ]),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('7 : 1'));
        await tester.pumpAndSettle();
        expect(bar('Dom'), findsOneWidget);
        expect(bar('Sok'), findsOneWidget);
        expect(bar('Soupeř'), findsNothing);

        await tester.tap(bar('Sok'));
        await tester.pumpAndSettle();
        final rows = inList(find.byType(ListTile));
        expect(rows, findsNWidgets(3));
        expect([
          for (final t in tester.widgetList<ListTile>(rows))
            (t.title! as Text).data,
        ], ['Dom', 'Jiný', 'Dom']);

        await finish(tester);
      });

      testWidgets('beside the modal, a tap on the sheet\'s nickname lists the '
          'team it stands for (0080)', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            zapisNav: KioskZapisNav.sides,
            slots: played(),
            results: scores(),
            lineups: {'c': lineup},
            drawerOpen: true,
            names: NameDisplay(const [
              Club(id: 's', name: 'Soupeř', nickname: 'Sok'),
            ]),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('7 : 1'));
        await tester.pumpAndSettle();

        await tester.tap(
          find.descendant(
            of: find.byType(LegacyScoreSheetPage),
            matching: find.textContaining('Sok', findRichText: true),
          ),
        );
        await tester.pumpAndSettle();
        expect(inList(find.byType(ListTile)), findsNWidgets(3));

        await finish(tester);
      });

      testWidgets('a tap on a team lists its played matches, its points first '
          'and the shown one picked out; a tap on one shows it', (
        tester,
      ) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            slots: played(),
            results: scores(),
            lineups: {'c': lineup},
            drawerOpen: true,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('7 : 1'));
        await tester.pumpAndSettle();

        await tester.tap(bar('Soupeř'));
        await tester.pumpAndSettle();
        final rows = inList(find.byType(ListTile));
        expect(rows, findsNWidgets(3));
        // Chronological; the away side's points first; the shown one picked.
        final titles = [
          for (final t in tester.widgetList<ListTile>(rows))
            (t.title! as Text).data,
        ];
        expect(titles, ['Domácí', 'Jiný', 'Domácí']);
        expect(
          [for (final t in tester.widgetList<ListTile>(rows)) t.selected],
          [false, false, true],
        );
        expect(inList(find.text('2 : 6')), findsOneWidget);
        expect(inList(find.text('5 : 3')), findsOneWidget);

        await tester.tap(find.descendant(of: rows.at(1), matching: find.text('Jiný')));
        await tester.pumpAndSettle();
        expect(rows, findsNothing);
        expect(find.text(dayFull(day.addDays(-7))), findsOneWidget);

        // The home side lists only its own matches.
        await tester.tap(bar('Jiný'));
        await tester.pumpAndSettle();
        expect(rows, findsOneWidget);
        // A tap beside the list closes it; the Zápis stays.
        final list = tester.getRect(teamList);
        await tester.tapAt(Offset(list.right + 200, list.bottom + 100));
        await tester.pumpAndSettle();
        expect(rows, findsNothing);
        expect(bar('Jiný'), findsOneWidget);

        await finish(tester);
      });

      testWidgets('beside the Zápis: no bar, ‹ › in the room beside the '
          'modal; a tap on a team\'s name in the sheet lists its matches', (
        tester,
      ) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            slots: played(),
            results: scores(),
            lineups: {'c': lineup},
            drawerOpen: true,
            zapisNav: KioskZapisNav.sides,
            // Still arrows: their breaths keep the wall clock, not the
            // test's.
            animations: false,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('7 : 1'));
        await tester.pumpAndSettle();
        final sheet = tester.getRect(find.byType(LegacyScoreSheetPage));
        // No bar: no team buttons above the sheet.
        expect(find.byType(OutlinedButton), findsNothing);
        final back = find.byIcon(Icons.chevron_left);
        final forth = find.byIcon(Icons.chevron_right);
        // Right beside the modal, not out in the middle of the room.
        expect(tester.getRect(back).right, lessThan(sheet.left));
        expect(tester.getRect(back).right, greaterThan(sheet.left - 20));
        expect(tester.getRect(forth).left, greaterThan(sheet.right));
        expect(tester.getRect(forth).left, lessThan(sheet.right + 20));
        expect(
          tester.getCenter(back).dy,
          closeTo(sheet.center.dy, 2),
        );

        // ‹: the match before, a sheet without players — its teams buttons.
        await tester.tap(back);
        await tester.pumpAndSettle();
        expect(
          find.ancestor(
            of: find.text('Jiný'),
            matching: find.byWidgetPredicate((w) => w is TextButton),
          ),
          findsOneWidget,
        );
        expect(find.byIcon(Icons.expand_more), findsNWidgets(2));
        await tester.tap(forth);
        await tester.pumpAndSettle();
        expect(find.byType(LegacyScoreSheetPage), findsOneWidget);

        // A tap on the away team's name in the sheet: its matches.
        // The name wears a ▾: it can be tapped.
        final name = find
            .descendant(
              of: find.byType(LegacyScoreSheetPage),
              matching: find.textContaining('Soupeř'),
            )
            .first;
        expect(
          find.descendant(
            of: find.byType(LegacyScoreSheetPage),
            matching: find.byIcon(Icons.expand_more),
          ),
          findsNWidgets(2),
        );
        await tester.tap(name);
        await tester.pumpAndSettle();
        expect(inList(find.byType(ListTile)), findsNWidgets(3));
        await tester.tap(
          find.descendant(
            of: inList(find.byType(ListTile)).first,
            matching: find.text('Domácí'),
          ),
        );
        await tester.pumpAndSettle();
        expect(teamList, findsNothing);
        expect(find.text('Zápis zápasu zatím není k dispozici.'), findsOneWidget);

        await finish(tester);
      });

      testWidgets('beside the Zápis at full screen: ‹ › float over the sheet; '
          'a tap hides them and the ×, another brings them back', (
        tester,
      ) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            slots: played(),
            results: scores(),
            lineups: {'c': lineup},
            drawerOpen: true,
            zapisNav: KioskZapisNav.sides,
            // Still arrows: their breaths keep the wall clock, not the
            // test's.
            animations: false,
            zapisPercent: 100,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('7 : 1'));
        await tester.pumpAndSettle();
        final sheet = tester.getRect(find.byType(LegacyScoreSheetPage));
        final back = find.byIcon(Icons.chevron_left);
        expect(sheet.contains(tester.getCenter(back)), isTrue);
        double opacity(Finder f) => tester
            .widget<AnimatedOpacity>(
              find.ancestor(of: f, matching: find.byType(AnimatedOpacity)).first,
            )
            .opacity;
        expect(opacity(back), 1);
        expect(opacity(find.byIcon(Icons.close)), 1);
        // The arrows and the × are one size.
        Size disc(Finder icon) => tester.getSize(
          find.ancestor(of: icon, matching: find.byType(InkWell)).first,
        );
        expect(disc(back), disc(find.byIcon(Icons.close)));
        expect(disc(find.byIcon(Icons.chevron_right)), disc(back));

        // A tap on the sheet (off its team names): gone.
        await tester.tapAt(sheet.center + const Offset(0, 200));
        await tester.pumpAndSettle();
        expect(opacity(back), 0);
        expect(opacity(find.byIcon(Icons.close)), 0);
        await tester.tapAt(sheet.center + const Offset(0, 200));
        await tester.pumpAndSettle();
        expect(opacity(back), 1);

        await tester.tap(find.byIcon(Icons.close));
        await tester.pumpAndSettle();
        expect(find.byType(LegacyScoreSheetPage), findsNothing);

        await finish(tester);
      });

      testWidgets('a swipe across the sheet pages like the arrows', (
        tester,
      ) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            slots: played(),
            results: scores(),
            lineups: {'c': lineup},
            drawerOpen: true,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('7 : 1'));
        await tester.pumpAndSettle();
        final sheet = tester.getRect(find.byType(LegacyScoreSheetPage));
        // To the right: the match before.
        await tester.dragFrom(sheet.center, const Offset(300, 0));
        await tester.pumpAndSettle();
        expect(bar('Jiný'), findsOneWidget);
        // To the left: back to the next one.
        final none = tester.getRect(
          find.text('Zápis zápasu zatím není k dispozici.'),
        );
        await tester.dragFrom(none.center, const Offset(-300, 0));
        await tester.pumpAndSettle();
        expect(find.byType(LegacyScoreSheetPage), findsOneWidget);
        // A slow, mostly downward stroke is no swipe.
        await tester.dragFrom(sheet.center, const Offset(80, 200));
        await tester.pumpAndSettle();
        expect(find.byType(LegacyScoreSheetPage), findsOneWidget);

        await finish(tester);
      });

      testWidgets('switched off: the bare sheet, no bar', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            slots: played(),
            results: scores(),
            lineups: {'c': lineup},
            drawerOpen: true,
            zapisNav: KioskZapisNav.off,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('7 : 1'));
        await tester.pumpAndSettle();
        expect(find.byType(LegacyScoreSheetPage), findsOneWidget);
        expect(button(Icons.chevron_left), findsNothing);
        expect(bar('Domácí'), findsNothing);

        await finish(tester);
      });
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
          // The bare sheet, as before paging (0079).
          zapisNav: KioskZapisNav.off,
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
          of: find.byType(KioskPanelView),
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
      expect(liveView, findsNothing);

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
      // The newest first.
      expect(drawerText('Druhý'), findsOneWidget);

      await tester.fling(drawerText('Druhý'), const Offset(-300, 0), 1000);
      await tester.pumpAndSettle();
      expect(drawerText('První'), findsOneWidget);
      expect(drawerText('Druhý'), findsNothing);

      await tester.fling(drawerText('První'), const Offset(300, 0), 1000);
      await tester.pumpAndSettle();
      expect(drawerText('Druhý'), findsOneWidget);

      await finish(tester);
    });

    // The notices' card, and its dots' decorations from left to right.
    final noticesCard = find.ancestor(
      of: drawerText('NÁSTĚNKA'),
      matching: find.byType(KioskCard),
    );
    List<BoxDecoration> noticeDots(WidgetTester tester) => [
      for (final c in tester.widgetList<Container>(
        find.descendant(of: noticesCard, matching: find.byType(Container)),
      ))
        if (c.decoration case final BoxDecoration d
            when d.shape == BoxShape.circle)
          d,
    ];

    testWidgets('fresh notices (0081) in the card: the newest first with '
        '„NOVÉ“ before its title, a stripe along the card and its dot in the '
        'primary colour — a ring while it waits; an old one plain', (
      tester,
    ) async {
      fullHd(tester);
      await tester.pumpWidget(
        app(
          notices: [
            notice('1', 'Brigáda'),
            notice(
              '2',
              'Turnaj',
              posted: nowAt.subtract(const Duration(days: 1)),
            ),
          ],
          drawerOpen: true,
        ),
      );
      await tester.pumpAndSettle();
      final primary = Theme.of(
        tester.element(find.byType(KioskPanelView)),
      ).colorScheme.primary;
      final chip = find.descendant(
        of: noticesCard,
        matching: find.byType(KioskNewChip),
      );

      expect(drawerText('Turnaj'), findsOneWidget);
      expect(chip, findsOneWidget);
      expect(
        tester.getRect(chip).right,
        lessThan(tester.getRect(drawerText('Turnaj')).left),
      );
      expect(tester.widget<KioskCard>(noticesCard).stripe, primary);
      expect(noticeDots(tester)[0].color, primary);
      expect(noticeDots(tester)[1].color, isNot(primary));
      expect(noticeDots(tester)[1].border, isNull);

      // The old one's turn: plain — and the fresh one's dot a ring.
      await tester.pump(const Duration(seconds: 13));
      await tester.pumpAndSettle();
      expect(drawerText('Brigáda'), findsOneWidget);
      expect(chip, findsNothing);
      expect(tester.widget<KioskCard>(noticesCard).stripe, Colors.transparent);
      expect(noticeDots(tester)[0].color, isNull);
      expect((noticeDots(tester)[0].border! as Border).left.color, primary);
      expect(noticeDots(tester)[1].color, primary);

      await finish(tester);
    });

    testWidgets('fresh notices shown longer (0081): in the card a fresh one '
        'stays two turns, an old one one — and no „NOVÉ“', (tester) async {
      fullHd(tester);
      await tester.pumpWidget(
        app(
          notices: [
            notice('1', 'Brigáda'),
            notice(
              '2',
              'Turnaj',
              posted: nowAt.subtract(const Duration(days: 1)),
            ),
          ],
          drawerOpen: true,
          noticesFresh: KioskNoticesFresh.longer,
        ),
      );
      await tester.pumpAndSettle();
      expect(drawerText('Turnaj'), findsOneWidget);
      expect(find.byType(KioskNewChip), findsNothing);
      expect(tester.widget<KioskCard>(noticesCard).stripe, Colors.transparent);

      // One turn (12 s) on: still the fresh one.
      await tester.pump(const Duration(seconds: 13));
      await tester.pumpAndSettle();
      expect(drawerText('Turnaj'), findsOneWidget);
      // Its second turn over: the old one, for one turn.
      await tester.pump(const Duration(seconds: 12));
      await tester.pumpAndSettle();
      expect(drawerText('Brigáda'), findsOneWidget);
      await tester.pump(const Duration(seconds: 13));
      await tester.pumpAndSettle();
      expect(drawerText('Turnaj'), findsOneWidget);

      await finish(tester);
    });

    testWidgets('a notice posted while the kiosk runs shows at once, first — '
        'in the card and in the status bar', (tester) async {
      fullHd(tester);
      final up = StreamController<List<Message>>();
      addTearDown(up.close);
      final before = [notice('1', 'Brigáda'), notice('2', 'Zámek')];
      await tester.pumpWidget(app(noticesStream: up.stream, drawerOpen: true));
      up.add(before);
      await tester.pumpAndSettle();
      expect(drawerText('Zámek'), findsOneWidget);

      // A turn on, the older one shows ...
      await tester.pump(const Duration(seconds: 13));
      await tester.pumpAndSettle();
      expect(drawerText('Brigáda'), findsOneWidget);

      // ... when a new one goes up: it is shown at once, in both places.
      up.add([...before, notice('3', 'Turnaj', posted: nowAt)]);
      await tester.pumpAndSettle();
      expect(drawerText('Turnaj'), findsOneWidget);
      expect(drawerText('Brigáda'), findsNothing);
      final bar = find.byType(KioskHeadline);
      expect(
        find.descendant(of: bar, matching: find.text('Turnaj')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: bar, matching: find.text('1/3')),
        findsOneWidget,
      );

      await finish(tester);
    });

    testWidgets('a notice posted after the kiosk\'s minute clock (which runs '
        'behind) is fresh at once: „NOVÉ“ and the stripe — and with fresh '
        'ones shown longer, its first turn is two', (tester) async {
      fullHd(tester);
      final bar = find.byType(KioskHeadline);
      Finder inBar(Finder f) => find.descendant(of: bar, matching: f);
      final before = [notice('1', 'Brigáda'), notice('2', 'Zámek')];
      // The server stamps it 30 s after the minute the kiosk's clock holds.
      final posted = [
        ...before,
        notice('3', 'Turnaj', posted: nowAt.add(const Duration(seconds: 30))),
      ];
      Future<void> post(KioskNoticesFresh fresh) async {
        final up = StreamController<List<Message>>();
        addTearDown(up.close);
        await tester.pumpWidget(
          app(noticesStream: up.stream, drawerOpen: true, noticesFresh: fresh),
        );
        up.add(before);
        await tester.pumpAndSettle();
        expect(drawerText('Zámek'), findsOneWidget);
        up.add(posted);
        await tester.pumpAndSettle();
        expect(drawerText('Turnaj'), findsOneWidget);
        expect(inBar(find.text('Turnaj')), findsOneWidget);
      }

      await post(KioskNoticesFresh.highlight);
      final primary = Theme.of(
        tester.element(find.byType(KioskPanelView)),
      ).colorScheme.primary;
      expect(
        find.descendant(of: noticesCard, matching: find.byType(KioskNewChip)),
        findsOneWidget,
      );
      expect(tester.widget<KioskCard>(noticesCard).stripe, primary);
      expect(inBar(find.byType(KioskNewChip)), findsOneWidget);
      await finish(tester);

      await post(KioskNoticesFresh.longer);
      expect(find.byType(KioskNewChip), findsNothing);
      // One turn (12 s) on: still the new one, in both places.
      await tester.pump(const Duration(seconds: 13));
      await tester.pumpAndSettle();
      expect(drawerText('Turnaj'), findsOneWidget);
      expect(inBar(find.text('Turnaj')), findsOneWidget);
      // Its second turn over: the next one.
      await tester.pump(const Duration(seconds: 12));
      await tester.pumpAndSettle();
      expect(drawerText('Zámek'), findsOneWidget);
      expect(inBar(find.text('Zámek')), findsOneWidget);

      await finish(tester);
    });

    testWidgets('notices taken down while the last one shows: the card shows '
        'the last one left, its dot lit', (tester) async {
      fullHd(tester);
      final up = StreamController<List<Message>>();
      addTearDown(up.close);
      final three = [
        notice('1', 'Brigáda'),
        notice('2', 'Zámek'),
        notice('3', 'Turnaj'),
      ];
      await tester.pumpWidget(app(noticesStream: up.stream, drawerOpen: true));
      up.add(three);
      await tester.pumpAndSettle();
      // Back from the newest to the last of the three.
      await tester.fling(drawerText('Turnaj'), const Offset(300, 0), 1000);
      await tester.pumpAndSettle();
      expect(drawerText('Brigáda'), findsOneWidget);

      // Brigáda is taken down.
      up.add(three.skip(1).toList());
      await tester.pumpAndSettle();
      expect(drawerText('Zámek'), findsOneWidget);
      final primary = Theme.of(
        tester.element(find.byType(KioskPanelView)),
      ).colorScheme.primary;
      final dots = noticeDots(tester);
      expect(dots, hasLength(2));
      expect(dots[0].color, isNot(primary));
      expect(dots[1].color, primary);

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
            of: find.byType(KioskPanelView),
            matching: find.textContaining(t),
          )
          .evaluate()
          .isNotEmpty;
      expect(inDrawer('Prvníci'), isTrue);
      // Touch every 6 s: the 10 s turn never comes.
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(seconds: 6));
        await tester.tap(find.byIcon(Icons.refresh));
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

    for (final layout in [MatchLayout.compact, MatchLayout.table]) {
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
        expect(liveView, findsNothing);
        expect(find.byType(DuelCard).hitTestable(), findsNothing);
        // All six duels in view, without scrolling.
        final drawer = tester.getRect(find.byType(KioskPanelView));
        final last = find.textContaining('Hráč6').first;
        expect(tester.getRect(last).bottom, lessThan(drawer.bottom));

        // The folded duel's card stays in the tree (cross-fade), hidden:
        // only the visible ones count — and only a visible name is tapped.
        final openCards = find.byType(DuelCard).hitTestable();
        Finder name(int pos) => find.textContaining('Hráč$pos').hitTestable();
        // Each opening animates; the fit is measured once it has, a timer
        // after the animation — so every tap waits it out, or the check
        // would race the fold.
        Future<void> settle() async {
          for (var i = 0; i < 6; i++) {
            await tester.pump(const Duration(milliseconds: 320));
            await tester.pumpAndSettle();
          }
        }

        // A tap opens a duel as the full card with its lane table.
        expect(openCards, findsNothing);
        await tester.tap(name(1).first);
        await settle();
        expect(openCards, findsOneWidget);
        expect(find.text('Plné'), findsWidgets);

        // More may be open while they fit; past that the first opened
        // folds. Two open cards overflow 1080 px by a few pixels, so the
        // rest runs 120 px taller: two fit there, a third does not.
        tester.view.physicalSize = const Size(1920, 1200);
        await tester.pumpAndSettle();
        await tester.tap(name(2).first);
        await settle();
        expect(openCards, findsNWidgets(2));
        for (var pos = 3; pos <= 6; pos++) {
          await tester.tap(name(pos).first);
          await settle();
        }
        final scroll = tester
            .state<ScrollableState>(
              find.descendant(
                of: find.byType(KioskPanelView),
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

    for (final layout in MatchLayout.values) {
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
                of: find.byType(KioskPanelView),
                // The full scoreboard sets the points as separate digits.
                matching: layout == MatchLayout.full
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

    testWidgets('full: a tap on a duel card opens its lanes, a tap on one '
        'not started does nothing', (tester) async {
      fullHd(tester);
      MatchPlayerResult withLanes(String side, int pos) => MatchPlayerResult(
        id: 'm-$side-$pos',
        matchId: 'm',
        side: side,
        position: pos,
        playerName: '${side == 'home' ? 'Dom' : 'Hos'} $pos',
        total: 400 + pos,
        lanes: [
          for (var l = 1; l <= 4; l++)
            PlayerLane(lane: l, total: side == 'home' ? 101 : 99),
        ],
      );
      await tester.pumpWidget(
        app(
          slots: [fed('m', day, 'Hrají')],
          results: {'m': res('m', 'in_progress', 2, 1)},
          lineups: {
            'm': [
              for (final side in ['home', 'away']) withLanes(side, 1),
              // Position 2 has not thrown: no total, no lanes.
              for (final side in ['home', 'away'])
                MatchPlayerResult(
                  id: 'm-$side-2',
                  matchId: 'm',
                  side: side,
                  position: 2,
                  playerName: '${side == 'home' ? 'Dom' : 'Hos'} 2',
                ),
            ],
          },
        ),
      );
      await tester.pumpAndSettle();
      final cards = find.descendant(
        of: find.byType(KioskPanelView),
        matching: find.byType(DuelCard),
      );
      expect(cards, findsNWidgets(2));
      expect(tester.widget<DuelCard>(cards.first).expanded, isFalse);

      await tester.tap(cards.first);
      await tester.pumpAndSettle();
      expect(tester.widget<DuelCard>(cards.first).expanded, isTrue);
      expect(find.text('Plné'), findsWidgets);

      await tester.tap(cards.last);
      await tester.pumpAndSettle();
      expect(tester.widget<DuelCard>(cards.last).expanded, isFalse);

      await tester.tap(cards.first);
      await tester.pumpAndSettle();
      expect(tester.widget<DuelCard>(cards.first).expanded, isFalse);

      await finish(tester);
    });

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
            of: find.byType(KioskPanelView),
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

    testWidgets('the live view: how old the score is, a fresh one asked for '
        'at the admin\'s pace, and back to all matches and again', (
      tester,
    ) async {
      fullHd(tester);
      final asked = <String>[];
      await tester.pumpWidget(
        app(
          slots: [fed('m', day, 'Hrají'), fed('next', day.addDays(2), 'Příští')],
          results: {'m': res('m', 'in_progress', 2, 1)},
          lineups: {'m': lineup},
          liveRefresh: 30,
          onRefresh: asked.add,
        ),
      );
      await tester.pumpAndSettle();
      // How old the score is, next to the dots.
      expect(find.byIcon(Icons.refresh), findsOneWidget);
      expect(find.textContaining('před'), findsWidgets);
      // Asked once on opening, then every 30 s.
      expect(asked, ['m']);
      await tester.pump(const Duration(seconds: 31));
      expect(asked, ['m', 'm']);

      // To all matches…
      await tester.tap(find.byTooltip('Všechny zápasy'));
      await tester.pumpAndSettle();
      expect(find.text('ZÁPASY'), findsOneWidget);
      expect(liveView, findsNothing);
      // …and back by the chip, or by the idle reset.
      await tester.tap(find.text('Právě se hraje'));
      await tester.pumpAndSettle();
      expect(liveView, findsOneWidget);
      await tester.tap(find.byTooltip('Všechny zápasy'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 61));
      await tester.pumpAndSettle();
      expect(liveView, findsOneWidget);

      await finish(tester);
    });

    group('the score\'s age is a refresh button (⟳ turns while asking)', () {
      // The ⟳ of the live view's header and whether it is turning.
      Finder spinner() => find
          .ancestor(
            of: find.descendant(
              of: find.byType(KioskPanelView),
              matching: find.byIcon(Icons.refresh),
            ),
            matching: find.byType(RotationTransition),
          )
          .first;
      bool turning(WidgetTester tester) =>
          (tester.widget<RotationTransition>(spinner()).turns
                  as AnimationController)
              .isAnimating;
      Finder ageButton() => find
          .ancestor(of: spinner(), matching: find.byType(InkWell))
          .first;

      testWidgets('a tap asks for a fresh score; the ⟳ turns until it '
          'arrives — no second ask meanwhile — or gives up after 30 s', (
        tester,
      ) async {
        fullHd(tester);
        final asked = <String>[];
        final results = StreamController<Map<String, MatchResult>>();
        addTearDown(results.close);
        MatchResult at(String fetched) =>
            res('m', 'in_progress', 2, 1, fetched: fetched);
        await tester.pumpWidget(
          app(
            slots: [fed('m', day, 'Hrají')],
            resultsStream: results.stream,
            lineups: {'m': lineup},
            liveRefresh: 600,
            onRefresh: asked.add,
            refreshAnswer: (_) async => 'queued',
          ),
        );
        results.add({'m': at('2026-10-08T09:50:00+00:00')});
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        // The ask on opening runs after the first frame; this one shows it.
        await tester.pump();
        expect(liveView, findsOneWidget);
        // Asked on opening — quietly: only a tap turns the ⟳.
        expect(asked, ['m']);
        expect(turning(tester), isFalse);
        results.add({'m': at('2026-10-08T09:59:00+00:00')});
        await tester.pump();
        // The drawer done sliding in.
        await tester.pump(const Duration(seconds: 1));

        // A tap: asked again, turning; a tap meanwhile asks nothing more.
        await tester.tap(ageButton());
        await tester.pump(const Duration(milliseconds: 100));
        expect(asked, ['m', 'm']);
        expect(turning(tester), isTrue);
        await tester.tap(ageButton());
        await tester.pump(const Duration(seconds: 10));
        expect(asked, ['m', 'm']);
        expect(turning(tester), isTrue);
        results.add({'m': at('2026-10-08T10:00:00+00:00')});
        await tester.pump();
        // It finishes the turn it is in.
        await tester.pump(const Duration(seconds: 2));
        expect(turning(tester), isFalse);

        // Queued, but nothing lands: given up on after 30 s.
        await tester.tap(ageButton());
        await tester.pump(const Duration(seconds: 29));
        expect(turning(tester), isTrue);
        await tester.pump(const Duration(seconds: 2));
        await tester.pump(const Duration(seconds: 2));
        expect(turning(tester), isFalse);
        expect(asked, ['m', 'm', 'm']);
        await finish(tester);
      });

      testWidgets('an answer that nothing will come (fresh, not live, or a '
          'failure) stops it — after a short turn, so a tap shows', (
        tester,
      ) async {
        fullHd(tester);
        for (final answer in ['fresh', 'not_live', null, 'throws']) {
          await tester.pumpWidget(
            app(
              slots: [fed('m', day, 'Hrají')],
              results: {'m': res('m', 'in_progress', 2, 1)},
              lineups: {'m': lineup},
              liveRefresh: 600,
              refreshAnswer: (_) async =>
                  answer == 'throws' ? throw Exception('offline') : answer,
            ),
          );
          await tester.pumpAndSettle();
          expect(turning(tester), isFalse, reason: '$answer');
          await tester.tap(ageButton());
          await tester.pump(const Duration(milliseconds: 500));
          expect(turning(tester), isTrue, reason: '$answer');
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pump(const Duration(seconds: 2));
          expect(turning(tester), isFalse, reason: '$answer');
          await finish(tester);
        }
      });

      testWidgets('a tap while the last turn runs out turns it again', (
        tester,
      ) async {
        fullHd(tester);
        final asked = <String>[];
        final results = StreamController<Map<String, MatchResult>>();
        addTearDown(results.close);
        MatchResult at(String fetched) =>
            res('m', 'in_progress', 2, 1, fetched: fetched);
        await tester.pumpWidget(
          app(
            slots: [fed('m', day, 'Hrají')],
            resultsStream: results.stream,
            lineups: {'m': lineup},
            liveRefresh: 600,
            onRefresh: asked.add,
            refreshAnswer: (_) async => 'queued',
          ),
        );
        results.add({'m': at('2026-10-08T09:50:00+00:00')});
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.tap(ageButton());
        await tester.pump(const Duration(seconds: 2));
        // The fetch lands: the ⟳ finishes its turn — and a tap meanwhile
        // turns it again, for as long as that ask is out.
        results.add({'m': at('2026-10-08T09:59:00+00:00')});
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(ageButton());
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(seconds: 2));
        expect(asked, ['m', 'm', 'm']);
        expect(turning(tester), isTrue);
        await tester.pump(const Duration(seconds: 5));
        expect(turning(tester), isTrue);
        await finish(tester);
      });

      testWidgets('only the asked match\'s own fetch stops it, not another '
          'match\'s', (tester) async {
        fullHd(tester);
        final results = StreamController<Map<String, MatchResult>>();
        addTearDown(results.close);
        final other = res('x', 'finished', 6, 2);
        await tester.pumpWidget(
          app(
            slots: [fed('m', day, 'Hrají')],
            resultsStream: results.stream,
            lineups: {'m': lineup},
            liveRefresh: 600,
            refreshAnswer: (_) async => 'queued',
          ),
        );
        final m = res('m', 'in_progress', 2, 1,
            fetched: '2026-10-08T09:50:00+00:00');
        results.add({'m': m});
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.tap(ageButton());
        await tester.pump(const Duration(seconds: 2));
        expect(turning(tester), isTrue);
        results.add({'m': m, 'x': other});
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        expect(turning(tester), isTrue);
        results.add({
          'm': res('m', 'in_progress', 2, 1,
              fetched: '2026-10-08T09:59:00+00:00'),
          'x': other,
        });
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        expect(turning(tester), isFalse);
        await finish(tester);
      });

      testWidgets('an answer that comes after its ask gave up does not end '
          'a later tap\'s', (tester) async {
        fullHd(tester);
        final answers = <Completer<String?>>[];
        await tester.pumpWidget(
          app(
            slots: [fed('m', day, 'Hrají')],
            results: {'m': res('m', 'in_progress', 2, 1)},
            lineups: {'m': lineup},
            liveRefresh: 600,
            refreshAnswer: (_) {
              final answer = Completer<String?>();
              answers.add(answer);
              return answer.future;
            },
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(seconds: 1));
        answers.single.complete('fresh'); // the ask on opening
        // A tap whose answer hangs past the 30 s it is given…
        await tester.tap(ageButton());
        await tester.pump(const Duration(seconds: 31));
        await tester.pump(const Duration(seconds: 2));
        expect(turning(tester), isFalse);
        // …a new tap, queued; then the old answer comes in at last.
        await tester.tap(ageButton());
        await tester.pump(const Duration(seconds: 1));
        answers.last.complete('queued');
        answers[1].complete('fresh');
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));
        expect(turning(tester), isTrue);
        await finish(tester);
      });

      testWidgets('the clock\'s ask leaves it still', (tester) async {
        fullHd(tester);
        final asked = <String>[];
        await tester.pumpWidget(
          app(
            slots: [fed('m', day, 'Hrají')],
            results: {'m': res('m', 'in_progress', 2, 1)},
            lineups: {'m': lineup},
            liveRefresh: 30,
            idleSeconds: 600,
            onRefresh: asked.add,
            // Queued: a turning ⟳ would turn for as long as it waits.
            refreshAnswer: (_) async => 'queued',
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump();
        expect(asked, ['m']);
        expect(turning(tester), isFalse);
        while (asked.length < 2) {
          await tester.pump(const Duration(seconds: 1));
        }
        await tester.pump();
        expect(turning(tester), isFalse);
        await finish(tester);
      });
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
            of: find.byType(KioskPanelView),
            matching: find.textContaining(t),
          )
          .evaluate()
          .isNotEmpty;
      expect(inDrawer('Prvníci'), isTrue);

      await tester.fling(
        find.byType(MatchScoreboard),
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

    testWidgets('a day gone by is washed with the background, not drawn '
        'through an Opacity layer', (tester) async {
      fullHd(tester);
      await tester.pumpWidget(app(pastDays: 3));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView).last, const Offset(900, 0));
      await tester.pumpAndSettle();
      expect(find.text('út 6.10.'), findsOneWidget);

      expect(find.byType(PastDayWash), findsNWidgets(3));
      expect(
        find.byWidgetPredicate((w) => w is Opacity && w.opacity < 1),
        findsNothing,
      );
      await finish(tester);
    });

    testWidgets('the drawer button breathes on a layer of its own — and keeps '
        'still when the admin turns the animation off', (tester) async {
      fullHd(tester);
      // The breaths keep the test's fake time.
      KioskDrawerButton.clock = tester.binding.clock.now;
      addTearDown(() => KioskDrawerButton.clock = DateTime.now);
      double alpha() => tester
          .widget<Icon>(
            find.descendant(
              of: find.byType(KioskDrawerButton),
              matching: find.byType(Icon),
            ),
          )
          .color!
          .a;
      Future<void> midBreath(Widget tree) async {
        await tester.pumpWidget(tree);
        await tester.pump();
        // The first breath comes on the shared rhythm's beat (the frame
        // there starts it); half-way through it the glow peaks.
        await tester.pump(
          KioskDrawerButton.untilBreath(tester.binding.clock.now()),
        );
        await tester.pump(KioskDrawerButton.pulse ~/ 2);
      }

      await midBreath(app(notices: [notice('1', 'Brigáda')]));
      expect(alpha(), greaterThan(0.6));
      expect(
        find.descendant(
          of: find.byType(KioskDrawerButton),
          matching: find.byType(RepaintBoundary),
        ),
        findsOneWidget,
      );
      await finish(tester);

      await midBreath(
        app(notices: [notice('1', 'Brigáda')], animations: false),
      );
      expect(alpha(), closeTo(0.4, 0.001));
      await finish(tester);
    });

    testWidgets('two drawer buttons breathe together, whenever each appeared',
        (tester) async {
      KioskDrawerButton.clock = tester.binding.clock.now;
      addTearDown(() => KioskDrawerButton.clock = DateTime.now);
      const sides = [PanelSide.right, PanelSide.left];
      Widget buttons(int count) => MaterialApp(
        home: Row(
          children: [
            for (final side in sides.take(count))
              KioskDrawerButton(
                key: ValueKey(side),
                side: side,
                open: false,
                onTap: () {},
              ),
          ],
        ),
      );
      double alpha(PanelSide side) => tester
          .widget<Icon>(
            find.descendant(
              of: find.byKey(ValueKey(side)),
              matching: find.byType(Icon),
            ),
          )
          .color!
          .a;

      // Frames as a display draws them: one long pump would draw only one.
      Future<void> frames(Duration span) async {
        const step = Duration(milliseconds: 50);
        var left = span;
        while (left > Duration.zero) {
          final next = left < step ? left : step;
          await tester.pump(next);
          left -= next;
        }
      }

      Duration untilBreath() =>
          KioskDrawerButton.untilBreath(tester.binding.clock.now());

      await tester.pumpWidget(buttons(1));
      await frames(untilBreath());
      // The other panel's content arrives later, at no particular moment —
      // here mid-breath of the first button.
      await frames(const Duration(milliseconds: 1500));
      await tester.pumpWidget(buttons(2));
      // From the rhythm's next beat on, both glow alike.
      await frames(untilBreath());
      final period = KioskDrawerButton.pulse + KioskDrawerButton.pause;
      var glowed = false;
      for (var t = Duration.zero; t < period * 2; t += period ~/ 42) {
        await frames(period ~/ 42);
        expect(alpha(PanelSide.left), closeTo(alpha(PanelSide.right), 1e-9));
        if (alpha(PanelSide.left) > 0.6) glowed = true;
      }
      expect(glowed, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    test('the breaths keep the wall clock\'s beat: every multiple of pulse '
        '+ pause', () {
      final beat = DateTime.fromMillisecondsSinceEpoch(
        4200 * 400000000,
        isUtc: true,
      );
      expect(KioskDrawerButton.untilBreath(beat), Duration.zero);
      expect(
        KioskDrawerButton.untilBreath(
          beat.add(const Duration(milliseconds: 1)),
        ),
        const Duration(milliseconds: 4199),
      );
      expect(
        KioskDrawerButton.untilBreath(
          beat.add(const Duration(milliseconds: 2400)),
        ),
        const Duration(milliseconds: 1800),
      );
    });

    testWidgets('the board and the drawer sit on layers of their own', (
      tester,
    ) async {
      fullHd(tester);
      await tester.pumpWidget(app(notices: [notice('1', 'Brigáda')]));
      await tester.pumpAndSettle();
      RepaintBoundary nearest(Finder of) => tester.widget<RepaintBoundary>(
        find.ancestor(of: of, matching: find.byType(RepaintBoundary)).first,
      );
      expect(nearest(find.byType(KioskBoardView)).child, isA<KioskBoardView>());
      expect(nearest(find.byType(KioskPanelView)).child, isA<KioskPanelView>());
      await finish(tester);
    });

    for (final panel in [true, false]) {
      testWidgets('the idle reset brings the board back to today, the panel '
          '${panel ? 'on' : 'off'}', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            pastDays: 7,
            panelEnabled: panel,
            notices: [notice('1', 'Brigáda')],
            fitDay: false,
            visibleDays: 6,
            idleSeconds: 30,
          ),
        );
        await tester.pumpAndSettle();
        double todayLeft() =>
            tester.getTopLeft(find.text('DNES · čt 8.10.')).dx;
        final home = todayLeft();
        // A visitor drags the board back, and forward past today.
        await tester.drag(find.byType(ListView).last, const Offset(900, 0));
        await tester.pumpAndSettle();
        expect(todayLeft(), isNot(home));
        await tester.pump(const Duration(seconds: 31));
        await tester.pumpAndSettle();
        expect(todayLeft(), closeTo(home, 1));

        await tester.drag(find.byType(ListView).last, const Offset(-900, 0));
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 31));
        await tester.pumpAndSettle();
        expect(todayLeft(), closeTo(home, 1));
        await finish(tester);
      });
    }

    testWidgets('the days stay on their grid when the columns change width '
        '(another screen width, the admin\'s number of days): today whole at '
        'the board\'s left edge, the days after it a column apart, and the '
        'idle reset brings today back there', (tester) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        app(
          pastDays: 7,
          panelEnabled: true,
          notices: [notice('1', 'Brigáda')],
          fitDay: false,
          visibleDays: 6,
          idleSeconds: 30,
        ),
      );
      await tester.pumpAndSettle();
      Rect header(String text) => tester.getRect(
        find.ancestor(
          of: find.text(text),
          matching: find.byType(BoardColumnHeader),
        ),
      );
      Rect body(int day) => tester.getRect(
        find.byWidgetPredicate(
          (w) => w is ScheduleDayColumn && w.day.date.day == day,
        ),
      );
      void onGrid(String reason) {
        final today = header('DNES · čt 8.10.');
        expect(today.left, closeTo(calendarRulerWidth, 0.5), reason: reason);
        // The day columns keep 2 px on each side.
        expect(body(8).left, closeTo(today.left + 2, 0.5), reason: reason);
        expect(
          header('pá 9.10.').left,
          closeTo(today.left + today.width, 0.5),
          reason: reason,
        );
        expect(body(9).left, closeTo(today.right + 2, 0.5), reason: reason);
      }

      onGrid('as it opens');
      for (final width in [1920.0, 1366.0, 1600.0]) {
        tester.view.physicalSize = Size(width, 900);
        await tester.pumpAndSettle();
        onGrid('$width px');
      }
      await tester.drag(find.byType(ListView).last, const Offset(-700, 0));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 31));
      await tester.pumpAndSettle();
      onGrid('after the idle reset');
      await finish(tester);
    });

    testWidgets('a match band on the board stacks the cup with the time, '
        'then home, x and away, so no team name breaks in half', (
      tester,
    ) async {
      fullHd(tester);
      await tester.pumpWidget(app(slots: [fed('m', day, 'Domácí')]));
      await tester.pumpAndSettle();
      Finder inBand(Finder f) =>
          find.descendant(of: find.byType(CalendarEventBand), matching: f);
      expect(inBand(findEmojiText('🏆 14:00–17:00')), findsOneWidget);
      expect(inBand(find.text('Domácí')), findsOneWidget);
      expect(inBand(find.text('x')), findsOneWidget);
      expect(inBand(find.text('Soupeř')), findsOneWidget);
      await finish(tester);
    });

    testWidgets('the admin\'s font size reaches the board\'s bands', (
      tester,
    ) async {
      fullHd(tester);
      await tester.pumpWidget(
        app(slots: [fed('m', day, 'Domácí')], bandFontSize: 18),
      );
      await tester.pumpAndSettle();
      final band = tester.widget<CalendarEventBand>(
        find.byType(CalendarEventBand),
      );
      expect(band.fontSize, 18);
      await finish(tester);
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
          matching: find.text('6'),
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
          of: find.byType(KioskPanelView),
          matching: find.byType(Image),
        ),
        findsOneWidget,
      );

      await finish(tester);
    });

    testWidgets('the status bar shows one notice title at a time, in turn, '
        'the newest first', (tester) async {
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
      expect(inBar('Zámek'), findsOneWidget);
      expect(inBar('1/2'), findsOneWidget);
      expect(find.textContaining('Skryté'), findsNothing);
      // A module: under its title „Nástěnka:“, starting where it starts.
      final title = find.text('Nástěnka:');
      expect(title, findsOneWidget);
      expect(
        tester.getRect(title).bottom,
        lessThanOrEqualTo(tester.getRect(bar).top),
      );
      expect(
        tester.getRect(find.byIcon(Icons.campaign_outlined)).left,
        closeTo(tester.getRect(title).left, 1),
      );
      // Left of „Rezervovat“.
      expect(
        tester.getRect(bar).right,
        lessThan(tester.getRect(find.text(kioskReserveLabel)).left),
      );

      // Within one turn (settling already ran part of the clock) it fades
      // to the next.
      for (var i = 0; i < 7 && inBar('Brigáda').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(milliseconds: 700));
      }
      // The fade over (the last pump may have only started it).
      await tester.pumpAndSettle();
      expect(inBar('Brigáda'), findsOneWidget);
      expect(inBar('Zámek'), findsNothing);

      // A tap reads the notice in full.
      await tester.tap(inBar('Brigáda'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);

      await finish(tester);
    });

    testWidgets('fresh notices (0081) in the status bar: „NOVÉ“ on one '
        'posted within the admin\'s days, none on an older one or with the '
        'highlight off', (tester) async {
      fullHd(tester);
      final bar = find.byType(KioskHeadline);
      Finder inBar(Finder f) => find.descendant(of: bar, matching: f);
      final notices = [
        notice('1', 'Brigáda'),
        notice(
          '2',
          'Turnaj',
          posted: nowAt.subtract(const Duration(days: 2)),
        ),
      ];

      await tester.pumpWidget(app(notices: notices));
      await tester.pumpAndSettle();
      expect(inBar(find.text('Turnaj')), findsOneWidget);
      expect(inBar(find.byType(KioskNewChip)), findsOneWidget);
      await finish(tester);

      // Fresh for a day only: two days up is not.
      await tester.pumpWidget(app(notices: notices, noticesFreshDays: 1));
      await tester.pumpAndSettle();
      expect(inBar(find.text('Turnaj')), findsOneWidget);
      expect(inBar(find.byType(KioskNewChip)), findsNothing);
      await finish(tester);

      await tester.pumpWidget(
        app(notices: notices, noticesFresh: KioskNoticesFresh.off),
      );
      await tester.pumpAndSettle();
      expect(inBar(find.text('Turnaj')), findsOneWidget);
      expect(inBar(find.byType(KioskNewChip)), findsNothing);
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
      // Really drawn: its 3 px, not a zero-height box.
      expect(tester.getSize(bar()).height, 3);
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

    group('two panels (0077)', () {
      // The notices left, the matches right: a panel on either side.
      final split = KioskPanels.defaults.withSide(
        KioskModule.notices,
        PanelSide.left,
      );
      // One of seven day columns, on the whole screen.
      const column = (1920 - 46) / 7;
      Finder panelOn(PanelSide side) => find.byWidgetPredicate(
        (w) => w is KioskPanelView && w.side == side,
      );
      Finder onPanel(PanelSide side, String text) =>
          find.descendant(of: panelOn(side), matching: find.text(text));
      Finder cardOn(PanelSide side, String title) => find
          .ancestor(of: onPanel(side, title), matching: find.byType(KioskCard))
          .first;
      double width(WidgetTester tester, PanelSide side) =>
          tester.getSize(panelOn(side)).width;
      // The buttons by what a screen reader says: their arrows alone are
      // the same on both sides, pointing opposite ways.
      Finder button(String label) => find.bySemanticsLabel(label);

      testWidgets('a panel on either side, each with its own button; the '
          'left one slides out of the screen\'s left edge, its content laid '
          'out from its inner edge', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            notices: [notice('1', 'Brigáda')],
            slots: [fed('next', day.addDays(1), 'Příští')],
            panels: split,
          ),
        );
        await tester.pumpAndSettle();
        // Both rest closed, as the admin set them: only the two buttons,
        // each arrow pointing the way its panel opens.
        expect(width(tester, PanelSide.left), 0);
        expect(width(tester, PanelSide.right), 0);
        expect(
          find.descendant(
            of: button('Zobrazit levý panel'),
            matching: find.byIcon(Icons.keyboard_double_arrow_right),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: button('Zobrazit pravý panel'),
            matching: find.byIcon(Icons.keyboard_double_arrow_left),
          ),
          findsOneWidget,
        );

        await tester.tap(button('Zobrazit levý panel'));
        // The frame that starts the slide, then 100 ms of its 250.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        // Mid-slide: the panel grows from the left edge, its card laid out
        // at its full width against the panel's right edge.
        final sliding = tester.getRect(panelOn(PanelSide.left));
        expect(sliding.left, 0);
        expect(sliding.width, inExclusiveRange(0, 2 * column));
        final card = tester.getRect(cardOn(PanelSide.left, 'NÁSTĚNKA'));
        expect(card.right, closeTo(sliding.right - 12, 0.5));
        expect(card.width, closeTo(2 * column - 24, 0.5));
        await tester.pumpAndSettle();
        expect(width(tester, PanelSide.left), closeTo(2 * column, 0.5));
        expect(onPanel(PanelSide.left, 'Brigáda'), findsOneWidget);
        // The board moved over, its hour ruler first.
        expect(
          tester.getRect(find.byType(HourRuler)).left,
          closeTo(2 * column, 0.5),
        );
        expect(
          find.descendant(
            of: button('Skrýt levý panel'),
            matching: find.byIcon(Icons.keyboard_double_arrow_left),
          ),
          findsOneWidget,
        );

        // Seven days leave room for both.
        await tester.tap(button('Zobrazit pravý panel'));
        await tester.pumpAndSettle();
        expect(width(tester, PanelSide.right), closeTo(2 * column, 0.5));
        expect(width(tester, PanelSide.left), closeTo(2 * column, 0.5));
        expect(onPanel(PanelSide.right, 'ZÁPASY'), findsOneWidget);
        expect(
          find.descendant(
            of: button('Skrýt pravý panel'),
            matching: find.byIcon(Icons.keyboard_double_arrow_right),
          ),
          findsOneWidget,
        );

        await tester.tap(button('Skrýt levý panel'));
        await tester.pumpAndSettle();
        expect(width(tester, PanelSide.left), 0);
        expect(width(tester, PanelSide.right), closeTo(2 * column, 0.5));
        await finish(tester);
      });

      testWidgets('the left button sits on the hour ruler, not over today\'s '
          'column: a visitor books today\'s first lane as ever', (
        tester,
      ) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(notices: [notice('1', 'Brigáda')], panels: split),
        );
        await tester.pumpAndSettle();
        final ruler = tester.getRect(find.byType(HourRuler));
        expect(
          tester.getCenter(button('Zobrazit levý panel')).dx,
          closeTo(ruler.center.dx, 0.5),
        );
        final arrow = tester.getRect(
          find.descendant(
            of: button('Zobrazit levý panel'),
            matching: find.byType(Icon),
          ),
        );
        expect(arrow.left, greaterThanOrEqualTo(ruler.left));
        expect(arrow.right, lessThanOrEqualTo(ruler.right));

        await tester.tap(find.text(kioskReserveLabel));
        await tester.pumpAndSettle();
        await tester.tap(find.text('A'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(players.first.displayName));
        await tester.pumpAndSettle();
        // Today's first lane: the board's first ＋, right of the ruler.
        final lane = find.byIcon(Icons.add).first;
        await tester.ensureVisible(lane);
        await tester.pumpAndSettle();
        expect(tester.getRect(lane).left, greaterThan(ruler.right));
        await tester.tap(lane);
        await tester.pumpAndSettle();
        expect(find.text('Rezervovat termín?'), findsOneWidget);
        await finish(tester);
      });

      group('the match list follows the days the board shows, not those a '
          'panel takes', () {
        // Eight matches a day: two days of them do not fit the list.
        Widget kiosk() => app(
          notices: [notice('1', 'Brigáda')],
          slots: [
            for (var i = 0; i <= 12; i++)
              for (var k = 1; k <= 8; k++)
                fed('d$i-$k', day.addDays(i), 'D$i-$k '),
          ],
          weeksAhead: 2,
          panels: split
              .withPanel(PanelSide.left, open: true)
              .withPanel(PanelSide.right, open: true),
        );
        Finder list() => find.descendant(
          of: panelOn(PanelSide.right),
          matching: find.byType(CustomScrollView),
        );
        bool visible(WidgetTester tester, String t) {
          final box = tester.getRect(list());
          final f = find.descendant(
            of: panelOn(PanelSide.right),
            matching: find.textContaining(t),
          );
          if (f.evaluate().isEmpty) return false;
          final r = tester.getRect(f.first);
          return r.top >= box.top - 1 && r.bottom <= box.bottom + 1;
        }

        double listAt(WidgetTester tester) => tester
            .state<ScrollableState>(
              find.descendant(of: list(), matching: find.byType(Scrollable)),
            )
            .position
            .pixels;
        // Seven days less two panels of two: three on the board. A day
        // forward shows days 1–3.
        Future<void> dayForward(WidgetTester tester) async {
          await tester.dragFrom(
            Offset(2 * column + 200, 600),
            const Offset(-column * 0.7 - 18, 0),
          );
          await tester.pumpAndSettle();
        }

        testWidgets('closing the left panel after a scroll brings the days '
            'it gave back into the list, the first of them on top when they '
            'do not all fit', (tester) async {
          fullHd(tester);
          await tester.pumpWidget(kiosk());
          await tester.pumpAndSettle();
          expect(visible(tester, 'D3-8 '), isFalse);
          await dayForward(tester);
          expect(visible(tester, 'D3-8 '), isTrue);
          expect(visible(tester, 'D4-1 '), isFalse);

          // Days 1–5 on the board: 4 and 5 came into view, told once the
          // panel has stopped — day by day, day 4's first matches would
          // scroll off again for day 5's.
          await tester.tap(button('Skrýt levý panel'));
          await tester.pumpAndSettle();
          expect(visible(tester, 'D4-1 '), isTrue);
          await finish(tester);
        });

        testWidgets('the panels stepping aside for a pick leave the list '
            'where the visitor scrolled it', (tester) async {
          fullHd(tester);
          await tester.pumpWidget(kiosk());
          await tester.pumpAndSettle();
          await dayForward(tester);
          final scrolled = listAt(tester);

          await tester.tap(find.text(kioskReserveLabel));
          await tester.pumpAndSettle();
          await tester.tap(find.text('A'));
          await tester.pumpAndSettle();
          await tester.tap(find.text(players.first.displayName));
          await tester.pumpAndSettle();
          expect(width(tester, PanelSide.left), 0);
          await tester.tap(find.byTooltip('Zrušit výběr'));
          await tester.pumpAndSettle();
          expect(listAt(tester), scrolled);
          expect(visible(tester, 'D3-8 '), isTrue);
          await finish(tester);
        });

        testWidgets('before a visitor scrolls, and again after the idle '
            'reset, a panel opened or closed leaves the list be', (
          tester,
        ) async {
          fullHd(tester);
          await tester.pumpWidget(kiosk());
          await tester.pumpAndSettle();
          final opened = listAt(tester);
          await tester.tap(button('Skrýt levý panel'));
          await tester.pumpAndSettle();
          expect(listAt(tester), opened, reason: 'nobody scrolled yet');
          await tester.tap(button('Zobrazit levý panel'));
          await tester.pumpAndSettle();

          await dayForward(tester);
          await tester.pump(const Duration(seconds: 61));
          await tester.pumpAndSettle();
          final reset = listAt(tester);
          await tester.tap(button('Skrýt levý panel'));
          await tester.pumpAndSettle();
          expect(listAt(tester), reset, reason: 'after the idle reset');
          await finish(tester);
        });
      });

      testWidgets('a match being played takes over the panel holding the '
          'matches — on the left too — and keeps it open', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            notices: [notice('1', 'Brigáda')],
            slots: [fed('m', day, 'Hrají')],
            results: {'m': res('m', 'in_progress', 2, 1)},
            lineups: {'m': lineup},
            // The matches left, the notices right.
            panels: KioskPanels.defaults.withSide(
              KioskModule.matches,
              PanelSide.left,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final liveLeft = find.descendant(
          of: panelOn(PanelSide.left),
          matching: find.byType(MatchScoreboard),
        );
        // Open although it rests closed; the right panel is left alone.
        expect(liveLeft, findsOneWidget);
        expect(width(tester, PanelSide.left), closeTo(2 * column, 0.5));
        expect(width(tester, PanelSide.right), 0);
        expect(button('Zobrazit pravý panel'), findsOneWidget);

        // A visitor may close it; after the idle time it is back.
        await tester.tap(button('Skrýt levý panel'));
        await tester.pumpAndSettle();
        expect(liveLeft, findsNothing);
        await tester.pump(const Duration(seconds: 61));
        await tester.pumpAndSettle();
        expect(liveLeft, findsOneWidget);

        // The list of matches is under it, and leads back to it.
        await tester.tap(find.byTooltip('Všechny zápasy'));
        await tester.pumpAndSettle();
        expect(liveLeft, findsNothing);
        expect(onPanel(PanelSide.left, 'ZÁPASY'), findsOneWidget);
        await tester.tap(find.text('Právě se hraje'));
        await tester.pumpAndSettle();
        expect(liveLeft, findsOneWidget);
        await finish(tester);
      });

      testWidgets('a visitor who picked their name gets the board alone: '
          'both panels and both buttons step aside, and are back as they '
          'were once the pick is cleared', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            notices: [notice('1', 'Brigáda')],
            slots: [fed('next', day.addDays(1), 'Příští')],
            panels: split
                .withPanel(PanelSide.left, open: true)
                .withPanel(PanelSide.right, open: true),
          ),
        );
        await tester.pumpAndSettle();
        expect(width(tester, PanelSide.left), closeTo(2 * column, 0.5));
        expect(width(tester, PanelSide.right), closeTo(2 * column, 0.5));

        await tester.tap(find.text(kioskReserveLabel));
        await tester.pumpAndSettle();
        await tester.tap(find.text('A'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(players.first.displayName));
        await tester.pumpAndSettle();
        expect(width(tester, PanelSide.left), 0);
        expect(width(tester, PanelSide.right), 0);
        expect(find.byType(KioskDrawerButton), findsNothing);

        await tester.tap(find.byTooltip('Zrušit výběr'));
        await tester.pumpAndSettle();
        expect(width(tester, PanelSide.left), closeTo(2 * column, 0.5));
        expect(width(tester, PanelSide.right), closeTo(2 * column, 0.5));
        expect(button('Skrýt levý panel'), findsOneWidget);
        expect(button('Skrýt pravý panel'), findsOneWidget);
        await finish(tester);
      });

      testWidgets('the idle reset puts both panels back as the admin set '
          'them and starts their cards over', (tester) async {
        fullHd(tester);
        // The matches left, resting open; the notices right, closed.
        await tester.pumpWidget(
          app(
            notices: [notice('1', 'Brigáda')],
            slots: [
              fed('b1', Day(2026, 10, 1), 'JedenZpět'),
              fed('cur', Day(2026, 10, 9), 'Tento'),
            ],
            weeksBack: 0,
            weeksAhead: 0,
            panels: KioskPanels.defaults
                .withSide(KioskModule.matches, PanelSide.left)
                .withPanel(PanelSide.left, open: true),
          ),
        );
        await tester.pumpAndSettle();
        Finder inLeft(String t) => find.descendant(
          of: panelOn(PanelSide.left),
          matching: find.textContaining(t),
        );
        // A visitor brings an older week into the list and opens the right
        // panel.
        await tester.drag(
          find.descendant(
            of: panelOn(PanelSide.left),
            matching: find.byType(CustomScrollView),
          ),
          const Offset(0, 200),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Zobrazit předchozí'));
        await tester.pumpAndSettle();
        expect(inLeft('JedenZpět'), findsWidgets);
        await tester.tap(button('Zobrazit pravý panel'));
        await tester.pumpAndSettle();
        expect(width(tester, PanelSide.right), closeTo(2 * column, 0.5));

        await tester.pump(const Duration(seconds: 61));
        await tester.pumpAndSettle();
        // The right panel rests closed again; the left one, open all along,
        // starts its list over, without the older week.
        expect(width(tester, PanelSide.right), 0);
        expect(width(tester, PanelSide.left), closeTo(2 * column, 0.5));
        expect(inLeft('Tento'), findsWidgets);
        expect(inLeft('JedenZpět'), findsNothing);

        // Closed by a visitor, the left one reopens after the idle time.
        await tester.tap(button('Skrýt levý panel'));
        await tester.pumpAndSettle();
        expect(width(tester, PanelSide.left), 0);
        await tester.pump(const Duration(seconds: 61));
        await tester.pumpAndSettle();
        expect(width(tester, PanelSide.left), closeTo(2 * column, 0.5));
        await finish(tester);
      });

      testWidgets('two days on the screen leave room for one panel: opening '
          'one closes the other', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            notices: [notice('1', 'Brigáda')],
            slots: [fed('next', day.addDays(1), 'Příští')],
            visibleDays: 2,
            panels: split
                .withPanel(PanelSide.left, open: true)
                .withPanel(PanelSide.right, open: true),
          ),
        );
        await tester.pumpAndSettle();
        // One day each; both rest open, the right one is.
        const oneDay = (1920 - 46) / 2;
        expect(width(tester, PanelSide.right), closeTo(oneDay, 0.5));
        expect(width(tester, PanelSide.left), 0);

        // Hiding the one shown must not let the other one (resting open
        // too, only held back by the shared room) slide in instead.
        await tester.tap(button('Skrýt pravý panel'));
        await tester.pumpAndSettle();
        expect(width(tester, PanelSide.right), 0);
        expect(width(tester, PanelSide.left), 0);

        await tester.tap(button('Zobrazit levý panel'));
        await tester.pumpAndSettle();
        expect(width(tester, PanelSide.left), closeTo(oneDay, 0.5));
        expect(width(tester, PanelSide.right), 0);

        await tester.tap(button('Zobrazit pravý panel'));
        await tester.pumpAndSettle();
        expect(width(tester, PanelSide.right), closeTo(oneDay, 0.5));
        expect(width(tester, PanelSide.left), 0);
        await finish(tester);
      });

      testWidgets('two days on the screen leave room for one panel: closing '
          'the panel held open by a live match does not open the other', (
        tester,
      ) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            notices: [notice('1', 'Brigáda')],
            slots: [fed('m', day, 'Hrají')],
            results: {'m': res('m', 'in_progress', 2, 1)},
            lineups: {'m': lineup},
            visibleDays: 2,
            // The matches left, the notices right resting open.
            panels: KioskPanels.defaults
                .withSide(KioskModule.matches, PanelSide.left)
                .withPanel(PanelSide.right, open: true),
          ),
        );
        await tester.pumpAndSettle();
        // Both open, the one with the match being played stays.
        const oneDay = (1920 - 46) / 2;
        expect(width(tester, PanelSide.left), closeTo(oneDay, 0.5));
        expect(width(tester, PanelSide.right), 0);

        await tester.tap(button('Skrýt levý panel'));
        await tester.pumpAndSettle();
        expect(width(tester, PanelSide.left), 0);
        expect(width(tester, PanelSide.right), 0);
        await finish(tester);
      });
    });

    group('canteen duty (0073)', () {
      DutyPeriod duty(String id, Day from, int days) =>
          DutyPeriod(id: id, startsOn: from, endsOn: from.addDays(days - 1));
      DutyAssignment assign(String periodId, PlayerName player) =>
          DutyAssignment(periodId: periodId, userId: player.id);

      // Monday 5. 10. to Sunday 11. 10. holds today (Thursday 8. 10.); six
      // weeks follow, one player each (BB, CC, …), and one was over.
      final current = duty('now', Day(2026, 10, 5), 7);
      final ahead = [
        for (var i = 0; i < 6; i++)
          duty('w$i', Day(2026, 10, 12).addDays(7 * i), 7),
      ];
      final over = duty('over', Day(2026, 9, 28), 7);
      final periods = [...ahead.reversed, current, over];
      final assignments = [
        assign('now', petr),
        assign('now', anna),
        for (var i = 0; i < 6; i++) assign('w$i', players[i + 1]),
        assign('over', players[25]),
      ];
      // The header's module: who serves today, under „Službu mají:“.
      final line = find.descendant(
        of: find.byType(KioskDutyModule),
        matching: find.text('AA Hráč a PP Hráč'),
      );
      final dialog = find.byType(AlertDialog);
      Finder inDialog(String t) =>
          find.descendant(of: dialog, matching: find.text(t));
      const nothingAhead = 'Další služby zatím nejsou naplánované.';

      testWidgets('in the header: who serves today, a module beside the '
          'clock — „Službu mají:“ over the names', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            dutyHeader: true,
            dutyPeriods: periods,
            dutyAssignments: assignments,
          ),
        );
        await tester.pumpAndSettle();
        expect(line, findsOneWidget);
        final title = find.descendant(
          of: find.byType(KioskDutyModule),
          matching: find.text('Službu mají:'),
        );
        expect(title, findsOneWidget);
        expect(
          tester.getRect(title).bottom,
          lessThanOrEqualTo(tester.getRect(line).top),
        );
        expect(tester.getRect(title).left, tester.getRect(line).left);
        // Beside the clock, not under its date; the title on the date's
        // line, the names on the time's.
        final date = find.text('Dnes je čtvrtek 8. 10.');
        final clock = find.ancestor(
          of: date,
          matching: find.byType(KioskHeaderModuleFrame),
        );
        expect(
          tester.getRect(find.byType(KioskDutyModule)).left,
          greaterThanOrEqualTo(tester.getRect(clock).right),
        );
        expect(
          tester.getRect(title).top,
          closeTo(tester.getRect(date).top, 0.5),
        );
        expect(
          tester.getRect(line).center.dy,
          closeTo(tester.getRect(find.text('12:00')).center.dy, 0.5),
        );

        await finish(tester);
      });

      testWidgets('one on duty: „Službu má:“', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            dutyHeader: true,
            dutyPeriods: periods,
            dutyAssignments: [
              for (final a in assignments)
                if (a.periodId != 'now' || a.userId == petr.id) a,
            ],
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Službu má:'), findsOneWidget);
        expect(find.text('Službu mají:'), findsNothing);
        expect(
          find.descendant(
            of: find.byType(KioskDutyModule),
            matching: find.text(petr.displayName),
          ),
          findsOneWidget,
        );

        await finish(tester);
      });

      testWidgets('while a warning hangs, the duty\'s module steps aside too',
          (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            dutyHeader: true,
            dutyPeriods: periods,
            dutyAssignments: assignments,
            warning: 'Dráha 3 je mimo provoz.',
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Dráha 3 je mimo provoz.'), findsOneWidget);
        expect(find.byType(KioskDutyModule), findsNothing);
        await finish(tester);
      });

      testWidgets('the module off, or nobody serving today: no module', (
        tester,
      ) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(dutyPeriods: periods, dutyAssignments: assignments),
        );
        await tester.pumpAndSettle();
        expect(find.byType(KioskDutyModule), findsNothing);
        expect(find.textContaining('službu'), findsNothing);
        await finish(tester);

        // Today's period without anyone on it says nothing either.
        await tester.pumpWidget(
          app(
            dutyHeader: true,
            dutyPeriods: periods,
            dutyAssignments: [
              for (final a in assignments)
                if (a.periodId != 'now') a,
            ],
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(KioskDutyModule), findsNothing);
        expect(find.textContaining('službu'), findsNothing);

        await finish(tester);
      });

      testWidgets('a long list of names stays one line, cut, at most a fifth '
          'of the screen wide', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            dutyHeader: true,
            dutyPeriods: [current],
            dutyAssignments: [for (final p in players) assign('now', p)],
          ),
        );
        await tester.pumpAndSettle();
        final text = find.textContaining('AA Hráč, BB Hráč');
        expect(text, findsOneWidget);
        expect(tester.widget<Text>(text).maxLines, 1);
        expect(tester.widget<Text>(text).overflow, TextOverflow.ellipsis);
        expect(
          tester
              .renderObject<RenderParagraph>(
                find.descendant(of: text, matching: find.byType(RichText)),
              )
              .didExceedMaxLines,
          isTrue,
        );
        expect(
          tester.getSize(find.byType(KioskDutyModule)).width,
          lessThanOrEqualTo(1920 * kioskHeaderModuleShare),
        );

        await finish(tester);
      });

      testWidgets('a tap shows the plan: who serves now, then the next five '
          'in date order', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            dutyHeader: true,
            dutyPeriods: periods,
            dutyAssignments: assignments,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(line);
        await tester.pumpAndSettle();

        expect(inDialog('Služby na kantýně'), findsOneWidget);
        expect(inDialog('Teď slouží: AA Hráč a PP Hráč'), findsOneWidget);
        expect(inDialog('po 5. 10. – ne 11. 10.'), findsOneWidget);
        expect(inDialog('Další'), findsOneWidget);
        // The five weeks ahead, top to bottom, range left of the names; the
        // sixth is not listed and the one over is gone.
        double? lastTop;
        for (var i = 0; i < 5; i++) {
          final range = inDialog(dutyRangeLabel(ahead[i]));
          final names = inDialog(players[i + 1].displayName);
          expect(range, findsOneWidget);
          expect(names, findsOneWidget);
          expect(
            tester.getRect(range).right,
            lessThan(tester.getRect(names).left),
          );
          final top = tester.getRect(range).top;
          if (lastTop != null) expect(top, greaterThan(lastTop));
          lastTop = top;
        }
        expect(inDialog('po 12. 10. – ne 18. 10.'), findsOneWidget);
        expect(inDialog(dutyRangeLabel(ahead[5])), findsNothing);
        expect(inDialog(players[6].displayName), findsNothing);
        expect(inDialog(players[25].displayName), findsNothing);
        expect(inDialog(nothingAhead), findsNothing);

        await tester.tap(inDialog('Zavřít'));
        await tester.pumpAndSettle();
        expect(dialog, findsNothing);

        await finish(tester);
      });

      testWidgets('nothing planned ahead says so', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            dutyHeader: true,
            dutyPeriods: [current, over],
            dutyAssignments: assignments,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(line);
        await tester.pumpAndSettle();

        expect(inDialog('Teď slouží: AA Hráč a PP Hráč'), findsOneWidget);
        expect(inDialog(nothingAhead), findsOneWidget);

        await finish(tester);
      });

      testWidgets('touching the plan counts for the idle timer; the idle '
          'reset closes it', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            dutyHeader: true,
            dutyPeriods: periods,
            dutyAssignments: assignments,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(line);
        await tester.pumpAndSettle();
        expect(dialog, findsOneWidget);

        // Read for 50 s, touched: another full minute from then on.
        await tester.pump(const Duration(seconds: 50));
        await tester.tap(inDialog('Služby na kantýně'));
        await tester.pump(const Duration(seconds: 20));
        // (A reset in those 20 s would still be fading the dialog out.)
        await tester.pumpAndSettle();
        expect(dialog, findsOneWidget);

        await tester.pump(const Duration(seconds: 41));
        await tester.pumpAndSettle();
        expect(dialog, findsNothing);

        await finish(tester);
      });

      // „V kalendáři“: the band's piece over one day's header, if any.
      Finder headerOf(Day date) => find.byWidgetPredicate(
        (w) => w is BoardColumnHeader && w.date == date,
      );
      BoardBandSegment? bandOn(WidgetTester tester, Day date) {
        final band = find.descendant(
          of: headerOf(date),
          matching: find.byType(BoardBand),
        );
        if (band.evaluate().isEmpty) return null;
        return tester.widget<BoardBand>(band).segment;
      }

      const both = 'AA Hráč a PP Hráč';
      // On the board's band who serves says what it is and when.
      const bothBand = '$both mají službu (5.–11. 10.)';
      const bbBand = 'BB Hráč má službu (12.–18. 10.)';

      // A band's strip over one day's header.
      Rect stripOn(WidgetTester tester, Day date) => tester.getRect(
        find.descendant(
          of: find.descendant(
            of: headerOf(date),
            matching: find.byType(BoardBand),
          ),
          matching: find.byType(Material),
        ),
      );
      // Where the board's header row starts on the screen.
      const rowLeft = calendarRulerWidth;
      final monday = Day(2026, 10, 12);

      testWidgets('„V kalendáři“: a band over each duty\'s days, rounded '
          'where it starts and ends (a one-day duty at both), who once per '
          'duty — at its start, or at the row\'s left edge for one begun off '
          'it', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            dutyBoard: true,
            dutyPeriods: periods,
            dutyAssignments: assignments,
          ),
        );
        await tester.pumpAndSettle();

        (bool, bool) piece(Day date) {
          final s = bandOn(tester, date)!;
          return (s.starts, s.ends);
        }

        expect(piece(day), (false, false));
        expect(piece(Day(2026, 10, 9)), (false, false));
        expect(piece(Day(2026, 10, 10)), (false, false));
        expect(piece(Day(2026, 10, 11)), (false, true));
        expect(piece(monday), (true, false));
        expect(piece(Day(2026, 10, 13)), (false, false));
        // Today is the first column: the duty began on Monday, off the
        // board, and still says who — one label, at the row's left edge.
        expect(bandLabelRun(tester, bothBand).left, closeTo(rowLeft + 6, 0.01));
        // The next week's starts on Monday, its name at its start.
        expect(
          bandLabelRun(tester, bbBand).left,
          closeTo(stripOn(tester, monday).left + 6, 0.01),
        );
        // Only the band: the header's module is placed elsewhere.
        expect(find.byType(KioskDutyModule), findsNothing);
        await finish(tester);

        // A one-day duty: one piece, its first day and its last.
        await tester.pumpWidget(
          app(
            dutyBoard: true,
            dutyPeriods: [duty('one', Day(2026, 10, 9), 1)],
            dutyAssignments: [assign('one', petr)],
          ),
        );
        await tester.pumpAndSettle();
        expect(piece(Day(2026, 10, 9)), (true, true));
        expect(bandOn(tester, day), isNull);
        expect(bandOn(tester, Day(2026, 10, 10)), isNull);

        await finish(tester);
      });

      testWidgets('a duty\'s last day the board\'s first column, like a '
          'weekly one on its Sunday: at rest who serves starts at the row\'s '
          'left edge, cut with „…“ at the duty\'s end — not cut off at its '
          'start by the row\'s edge', (tester) async {
        fullHd(tester);
        // Friday 2. 10. to today, four on it: a line longer than a column.
        const four =
            'AA Hráč, BB Hráč, CC Hráč a DD Hráč mají službu (2.–8. 10.)';
        await tester.pumpWidget(
          app(
            dutyBoard: true,
            dutyPeriods: [duty('ending', Day(2026, 10, 2), 7)],
            dutyAssignments: [
              for (var i = 0; i < 4; i++) assign('ending', players[i]),
            ],
          ),
        );
        await tester.pumpAndSettle();
        expect(bandOn(tester, day)!.label, four);
        expect(bandOn(tester, day)!.ends, isTrue);

        final run = bandLabelRun(tester, four);
        expect(run.left, closeTo(rowLeft + 6, 0.01));
        expect(run.right, closeTo(stripOn(tester, day).right - 6, 0.01));
        final text = find.descendant(
          of: bandPieces(four),
          matching: find.text(four),
        );
        expect(text, findsOneWidget);
        expect(tester.widget<Text>(text).overflow, TextOverflow.ellipsis);
        expect(bandLabelParagraph(tester, four).didExceedMaxLines, isTrue);

        await finish(tester);
      });

      testWidgets('the band runs on unbroken from day to day, through the '
          'gap between the headers, wherever in them it runs; the next duty '
          'starts apart', (tester) async {
        fullHd(tester);
        Rect strip(int d) => tester.getRect(
          find.descendant(
            of: find.descendant(
              of: headerOf(Day(2026, 10, d)),
              matching: find.byType(BoardBand),
            ),
            matching: find.byType(Material),
          ),
        );
        // A header's background: the first box it decorates.
        Rect background(int d) => tester.getRect(
          find
              .descendant(
                of: headerOf(Day(2026, 10, d)),
                matching: find.byType(DecoratedBox),
              )
              .first,
        );

        for (final position in KioskDutyBandPosition.values) {
          await tester.pumpWidget(
            app(
              // Matches on one day only: the band still one straight line.
              slots: [fed('m', day, 'Domácí')],
              dutyBoard: true,
              dutyBandPosition: position,
              dutyPeriods: periods,
              dutyAssignments: assignments,
            ),
          );
          await tester.pumpAndSettle();
          for (var d = 8; d < 11; d++) {
            expect(strip(d).right, strip(d + 1).left, reason: '$position');
            expect(strip(d).top, strip(d + 1).top, reason: '$position');
            expect(strip(d).bottom, strip(d + 1).bottom, reason: '$position');
            // The headers themselves keep their gap.
            expect(
              background(d + 1).left - background(d).right,
              4,
              reason: '$position',
            );
          }
          // Sunday ends one duty, Monday starts the next: rounded, apart.
          expect(
            strip(12).left,
            greaterThan(strip(11).right),
            reason: '$position',
          );
          await finish(tester);
        }
      });

      testWidgets('where the admin wants it: above the date, between the '
          'date and the matches, or under the matches on the headers\' '
          'bottom edge — the headers as tall in each', (tester) async {
        fullHd(tester);
        Finder within(Day date, Finder f) =>
            find.descendant(of: headerOf(date), matching: f);
        Rect strip(Day date) => tester.getRect(
          within(
            date,
            find.descendant(
              of: find.byType(BoardBand),
              matching: find.byType(Material),
            ),
          ),
        );
        Rect label(Day date) =>
            tester.getRect(within(date, find.textContaining(dayLabel(date))));
        Rect header(Day date) => tester.getRect(headerOf(date));
        // Today's two matches, Saturday's none.
        final lines = within(day, find.byType(EmojiText));
        final saturday = Day(2026, 10, 10);

        for (final position in KioskDutyBandPosition.values) {
          await tester.pumpWidget(
            app(
              slots: [
                fed('m', day, 'Domácí'),
                fed('m2', day, 'Domácí B', hour: 18),
              ],
              dutyBoard: true,
              dutyBandPosition: position,
              dutyPeriods: periods,
              dutyAssignments: assignments,
            ),
          );
          await tester.pumpAndSettle();
          final why = '$position';
          expect(lines, findsNWidgets(2), reason: why);
          expect(
            header(day).height,
            boardHeaderHeight(2) + boardBandHeight,
            reason: why,
          );
          switch (position) {
            case KioskDutyBandPosition.top:
              expect(strip(day).top, header(day).top, reason: why);
              expect(
                strip(day).bottom,
                lessThanOrEqualTo(label(day).top),
                reason: why,
              );
            case KioskDutyBandPosition.middle:
              expect(
                strip(day).top,
                greaterThanOrEqualTo(label(day).bottom),
                reason: why,
              );
              expect(
                strip(day).bottom,
                lessThanOrEqualTo(tester.getRect(lines.first).top),
                reason: why,
              );
            case KioskDutyBandPosition.bottom:
              expect(
                strip(day).top,
                greaterThanOrEqualTo(tester.getRect(lines.last).bottom),
                reason: why,
              );
              expect(strip(day).bottom, header(day).bottom, reason: why);
              // A day without matches: the band on the same bottom edge.
              expect(strip(saturday).top, strip(day).top, reason: why);
              expect(strip(saturday).bottom, strip(day).bottom, reason: why);
          }
          // The date above the matches, on one line across the days.
          expect(
            label(day).bottom,
            lessThanOrEqualTo(tester.getRect(lines.first).top),
            reason: why,
          );
          expect(label(saturday).top, label(day).top, reason: why);
          await finish(tester);
        }
      });

      testWidgets('above the date, a day without a duty keeps the band\'s '
          'room: the dates stay on one line', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            dutyBoard: true,
            dutyBandPosition: KioskDutyBandPosition.top,
            dutyPeriods: periods,
            // Nobody on this week's duty: no band until Monday.
            dutyAssignments: [
              for (final a in assignments)
                if (a.periodId != 'now') a,
            ],
          ),
        );
        await tester.pumpAndSettle();
        final monday = Day(2026, 10, 12);
        expect(bandOn(tester, day), isNull);
        expect(bandOn(tester, monday)!.label, bbBand);
        double labelTop(Day date) => tester
            .getRect(
              find.descendant(
                of: headerOf(date),
                matching: find.textContaining(dayLabel(date)),
              ),
            )
            .top;
        // Monday's band on the top edge, its date under it — today's date
        // on the same line, over nothing.
        expect(
          tester
              .getRect(
                find.descendant(
                  of: find.descendant(
                    of: headerOf(monday),
                    matching: find.byType(BoardBand),
                  ),
                  matching: find.byType(Material),
                ),
              )
              .top,
          tester.getRect(headerOf(monday)).top,
        );
        expect(labelTop(day), labelTop(monday));
        expect(
          tester.getSize(headerOf(day)).height,
          boardHeaderHeight(0) + boardBandHeight,
        );

        await finish(tester);
      });

      testWidgets('while the board moves, mid-drag too, each duty keeps one '
          'label: stuck to the row\'s left edge, cut with „…“ where less of '
          'the duty is left, pushed off the row only at its very end, at the '
          'next one\'s start — and the board is not rebuilt for it; the idle '
          'reset brings it back', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            pastDays: 3,
            dutyBoard: true,
            dutyPeriods: periods,
            dutyAssignments: assignments,
          ),
        );
        await tester.pumpAndSettle();
        const columnWidth = (1920 - rowLeft) / 7;
        final sunday = Day(2026, 10, 11);
        final board = find.byType(ListView).last;
        expect(tester.getTopLeft(headerOf(day)).dx, rowLeft);

        // The names uncut, and the least they are cut to.
        final whole = bandLabelParagraph(
          tester,
          bothBand,
        ).getMaxIntrinsicWidth(double.infinity);
        final least = bandLabelLeast(tester, bothBand);

        // Where and how wide the geometry puts the current duty's names: the
        // duty began on Monday 5. 10., seven columns before its end on
        // Sunday.
        void expectLabels(String why) {
          final run = bandLabelRun(tester, bothBand);
          final end = stripOn(tester, sunday).right;
          final at = stickyBandLabel(
            viewportLeft: rowLeft,
            bandStart: end + 12 - 7 * columnWidth,
            bandEnd: end,
            labelWidth: whole,
            minWidth: least,
          );
          expect(run.left, closeTo(at.left, 0.01), reason: why);
          expect(run.width, closeTo(at.width, 0.01), reason: why);
          // The next duty's at its start, while its Monday is in view.
          if (headerOf(monday).evaluate().isNotEmpty) {
            expect(
              bandLabelRun(tester, bbBand).left,
              closeTo(stripOn(tester, monday).left + 6, 0.01),
              reason: why,
            );
          }
        }

        expectLabels('at rest');
        expect(bandLabelRun(tester, bothBand).left, closeTo(rowLeft + 6, 0.01));

        // The finger stays down: no settling, frame by frame.
        final sundayHeader = tester.widget(headerOf(sunday));
        final gesture = await tester.startGesture(tester.getCenter(board));
        var cut = false;
        var pushed = false;
        // On to Sunday's end and back: it settles on Sunday.
        for (final dx in <double>[
          -30,
          -77,
          -150,
          -200,
          -250,
          -150,
          -100,
          -90,
          150,
        ]) {
          await gesture.moveBy(Offset(dx, 0));
          await tester.pump();
          expectLabels('$dx');
          final run = bandLabelRun(tester, bothBand);
          final stuck = run.left >= rowLeft + 6 - 0.01;
          final cutShort = run.width < whole - 0.01;
          if (!stuck) pushed = true;
          if (stuck && cutShort) cut = true;
          if (cutShort) {
            // Never past the duty's end, „…“ where it is cut.
            expect(
              run.right,
              closeTo(stripOn(tester, sunday).right - 6, 0.01),
              reason: '$dx',
            );
            expect(
              bandLabelParagraph(tester, bothBand).didExceedMaxLines,
              isTrue,
              reason: '$dx',
            );
          }
          // Only the labels moved: the headers were not built again.
          expect(
            identical(tester.widget(headerOf(sunday)), sundayHeader),
            isTrue,
            reason: '$dx',
          );
        }
        expect(cut, isTrue, reason: 'the drag nears the duty\'s end');
        expect(pushed, isTrue, reason: 'the drag reaches the duty\'s end');
        await gesture.up();
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(headerOf(sunday)).dx, closeTo(rowLeft, 0.01));
        expectLabels('settled');

        // Back to the board's first day, the duty's first: the names ride
        // its start again.
        final back = await tester.startGesture(tester.getCenter(board));
        for (final dx in <double>[30, 400, 400, 400, 400, 400]) {
          await back.moveBy(Offset(dx, 0));
          await tester.pump();
          expectLabels('back $dx');
        }
        expect(
          bandLabelRun(tester, bothBand).left,
          closeTo(stripOn(tester, Day(2026, 10, 5)).left + 6, 0.01),
        );
        await back.up();
        await tester.pumpAndSettle();

        await tester.pump(const Duration(seconds: 61));
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(headerOf(day)).dx, rowLeft);
        expect(bandLabelRun(tester, bothBand).left, closeTo(rowLeft + 6, 0.01));

        await finish(tester);
      });

      testWidgets('a player at the limit picks their name, then lets go of '
          'it: the note comes and goes above the board, which stays where '
          'it was, each duty\'s label drawn throughout', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            dutyBoard: true,
            dutyPeriods: periods,
            dutyAssignments: assignments,
            // Anna's one live reservation is all she may hold.
            maxActiveReservations: 1,
            reservations: [
              Reservation(
                id: 'r1',
                playerId: anna.id,
                date: day.addDays(1),
                blockId: 'b1',
                lane: 2,
                createdVia: 'app',
                createdAt: DateTime.utc(2026, 1, 1),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();
        // Two columns on: Saturday first, the current duty's names stuck
        // to the row's left edge, the next one's at its Monday.
        const columnWidth = (1920 - rowLeft) / 7;
        final saturday = Day(2026, 10, 10);
        await tester.drag(
          find.byType(ListView).last,
          const Offset(-2 * columnWidth, 0),
        );
        await tester.pumpAndSettle();
        final note = find.textContaining('Máš maximální počet rezervací (1)');

        // Every frame of it, the one where the note comes or goes too.
        Future<void> expectBoard(String why) async {
          for (var frame = 0; frame < 30; frame++) {
            expect(tester.takeException(), isNull, reason: '$why $frame');
            expect(
              tester.getTopLeft(headerOf(saturday)).dx,
              closeTo(rowLeft, 0.01),
              reason: '$why $frame',
            );
            expect(
              bandLabelRun(tester, bothBand).left,
              closeTo(rowLeft + 6, 0.01),
              reason: '$why $frame',
            );
            expect(
              bandLabelRun(tester, bbBand).left,
              closeTo(stripOn(tester, monday).left + 6, 0.01),
              reason: '$why $frame',
            );
            await tester.pump(const Duration(milliseconds: 20));
          }
        }

        await expectBoard('before');
        await tester.tap(find.text(kioskReserveLabel));
        await tester.pumpAndSettle();
        await tester.tap(find.text('A'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(NamePicker),
            matching: find.text(anna.displayName),
          ),
        );
        await expectBoard('picked');
        expect(note, findsOneWidget);

        await tester.tap(find.byIcon(Icons.close));
        await expectBoard('let go');
        expect(note, findsNothing);

        await finish(tester);
      });

      testWidgets('a tap on the band shows the plan; the rest of the header '
          'still lists the day\'s matches; the idle reset closes the plan', (
        tester,
      ) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            slots: [fed('m', day, 'Domácí')],
            dutyBoard: true,
            dutyPeriods: periods,
            dutyAssignments: assignments,
          ),
        );
        await tester.pumpAndSettle();
        final band = find.descendant(
          of: headerOf(Day(2026, 10, 10)),
          matching: find.byType(BoardBand),
        );

        await tester.tap(band);
        await tester.pumpAndSettle();
        expect(inDialog('Služby na kantýně'), findsOneWidget);
        expect(inDialog('Teď slouží: $both'), findsOneWidget);
        await tester.tap(inDialog('Zavřít'));
        await tester.pumpAndSettle();
        expect(dialog, findsNothing);

        await tester.tap(
          find.descendant(
            of: headerOf(day),
            matching: find.textContaining('Domácí'),
          ),
        );
        await tester.pumpAndSettle();
        expect(dialog, findsOneWidget);
        expect(inDialog('Služby na kantýně'), findsNothing);
        await tester.tap(inDialog('Zavřít'));
        await tester.pumpAndSettle();

        await tester.tap(band);
        await tester.pumpAndSettle();
        expect(inDialog('Služby na kantýně'), findsOneWidget);
        await tester.pump(const Duration(seconds: 61));
        await tester.pumpAndSettle();
        expect(dialog, findsNothing);

        await finish(tester);
      });

      testWidgets('the band off: none, and the headers as they were; on, '
          'they grow by it, and a duty nobody is on has none', (
        tester,
      ) async {
        fullHd(tester);
        double headerHeight() =>
            tester.getSize(find.byType(BoardColumnHeader).first).height;
        await tester.pumpWidget(
          app(dutyPeriods: periods, dutyAssignments: assignments),
        );
        await tester.pumpAndSettle();
        expect(find.byType(BoardBand), findsNothing);
        expect(headerHeight(), boardHeaderHeight(0));
        await finish(tester);

        await tester.pumpWidget(
          app(
            dutyBoard: true,
            dutyPeriods: periods,
            dutyAssignments: [
              for (final a in assignments)
                if (a.periodId != 'now') a,
            ],
          ),
        );
        await tester.pumpAndSettle();
        expect(headerHeight(), boardHeaderHeight(0) + boardBandHeight);
        for (var d = 8; d <= 11; d++) {
          expect(bandOn(tester, Day(2026, 10, d)), isNull);
        }
        expect(bandOn(tester, Day(2026, 10, 12))!.label, bbBand);

        await finish(tester);
      });

      // „V panelu“: the drawer's cards, each found by its title.
      const dutyTitle = 'SLUŽBA NA KANTÝNĚ';
      Finder cardTitled(String title) => find
          .ancestor(of: drawerText(title), matching: find.byType(Container))
          .first;
      Finder inCard(String t) =>
          find.descendant(of: cardTitled(dutyTitle), matching: find.text(t));
      final withoutNow = [
        for (final a in assignments)
          if (a.periodId != 'now') a,
      ];

      testWidgets('„V panelu“: a card on top of the drawer — who serves now, '
          'then the next five; the switch off, none', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            notices: [notice('1', 'Brigáda')],
            drawerOpen: true,
            dutyPeriods: periods,
            dutyAssignments: assignments,
          ),
        );
        await tester.pumpAndSettle();
        expect(drawerText('Brigáda'), findsOneWidget);
        expect(drawerText(dutyTitle), findsNothing);
        await finish(tester);

        await tester.pumpWidget(
          app(
            notices: [notice('1', 'Brigáda')],
            drawerOpen: true,
            dutyDrawer: true,
            dutyShare: 60,
            dutyPeriods: periods,
            dutyAssignments: assignments,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(drawerText(dutyTitle), findsOneWidget);
        expect(
          find.descendant(
            of: cardTitled(dutyTitle),
            matching: find.byIcon(Icons.local_cafe_outlined),
          ),
          findsOneWidget,
        );
        expect(inCard('Teď slouží'), findsOneWidget);
        expect(inCard(both), findsOneWidget);
        expect(inCard('po 5. 10. – ne 11. 10.'), findsOneWidget);
        expect(inCard('Další'), findsOneWidget);
        // The five weeks ahead, top to bottom, range left of the names; the
        // sixth is not listed and the one over is gone.
        double? lastTop;
        for (var i = 0; i < 5; i++) {
          final range = inCard(dutyRangeLabel(ahead[i]));
          final names = inCard(players[i + 1].displayName);
          expect(range, findsOneWidget);
          expect(names, findsOneWidget);
          expect(
            tester.getRect(range).right,
            lessThan(tester.getRect(names).left),
          );
          final top = tester.getRect(range).top;
          if (lastTop != null) expect(top, greaterThan(lastTop));
          lastTop = top;
        }
        expect(inCard(dutyRangeLabel(ahead[5])), findsNothing);
        expect(inCard(players[6].displayName), findsNothing);
        expect(inCard(players[25].displayName), findsNothing);
        expect(inCard(nothingAhead), findsNothing);
        // Above the notices.
        expect(
          tester.getRect(cardTitled(dutyTitle)).bottom,
          lessThan(tester.getRect(cardTitled('NÁSTĚNKA')).top),
        );
        // Only the card: the module and the band are placed on their own.
        expect(find.byType(KioskDutyModule), findsNothing);
        expect(find.byType(BoardBand), findsNothing);

        await finish(tester);
      });

      testWidgets('nobody on today\'s duty, or nobody ahead: the card says '
          'so', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            notices: [notice('1', 'Brigáda')],
            drawerOpen: true,
            dutyDrawer: true,
            dutyShare: 60,
            dutyPeriods: periods,
            dutyAssignments: withoutNow,
          ),
        );
        await tester.pumpAndSettle();
        expect(inCard('Dnes nikdo neslouží.'), findsOneWidget);
        expect(inCard('Teď slouží'), findsNothing);
        expect(inCard(both), findsNothing);
        expect(inCard('Další'), findsOneWidget);
        expect(inCard('BB Hráč'), findsOneWidget);
        await finish(tester);

        await tester.pumpWidget(
          app(
            notices: [notice('1', 'Brigáda')],
            drawerOpen: true,
            dutyDrawer: true,
            dutyPeriods: [current, over],
            dutyAssignments: assignments,
          ),
        );
        await tester.pumpAndSettle();
        expect(inCard(both), findsOneWidget);
        expect(inCard('Další'), findsNothing);
        expect(inCard(nothingAhead), findsOneWidget);

        await finish(tester);
      });

      testWidgets('the card takes its share of the panel; the notices and '
          'the matches keep their split of the rest', (tester) async {
        fullHd(tester);
        for (final dutyShare in [30, 60]) {
          await tester.pumpWidget(
            app(
              notices: [notice('1', 'Brigáda')],
              slots: [fed('next', day.addDays(1), 'Příští')],
              drawerOpen: true,
              dutyDrawer: true,
              dutyShare: dutyShare,
              dutyPeriods: periods,
              dutyAssignments: assignments,
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final drawer = tester.getRect(find.byType(KioskPanelView));
          final duty = tester.getRect(cardTitled(dutyTitle));
          final notices = tester.getRect(cardTitled('NÁSTĚNKA'));
          final matches = tester.getRect(cardTitled('ZÁPASY'));
          expect(duty.top, closeTo(drawer.top + 12, 0.01));
          expect(notices.top, closeTo(duty.bottom + 12, 0.01));
          expect(matches.bottom, closeTo(drawer.bottom - 12, 0.01));
          // One stack of three shares (0077): the gaps come off first.
          expect(
            duty.height / (duty.height + notices.height + matches.height),
            closeTo(dutyShare / 100, 0.001),
          );
          // The notices keep their 40 % of what is left.
          expect(
            notices.height / (notices.height + matches.height),
            closeTo(0.4, 0.001),
          );
          await finish(tester);
        }
      });

      testWidgets('with nothing else to show the card alone makes the drawer '
          'and fills it; nothing planned, no card and no drawer', (
        tester,
      ) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            dutyDrawer: true,
            dutyPeriods: periods,
            dutyAssignments: assignments,
          ),
        );
        await tester.pumpAndSettle();
        // It rests closed, as the admin set the drawer.
        expect(openButton, findsOneWidget);
        await tester.tap(openButton);
        await tester.pumpAndSettle();
        final drawer = tester.getRect(find.byType(KioskPanelView));
        final card = tester.getRect(cardTitled(dutyTitle));
        expect(card.top, closeTo(drawer.top + 12, 0.01));
        expect(card.bottom, closeTo(drawer.bottom - 12, 0.01));
        expect(drawerText('NÁSTĚNKA'), findsNothing);
        expect(drawerText('ZÁPASY'), findsNothing);
        await finish(tester);

        // Only a duty that is over: nothing to say, no drawer.
        await tester.pumpWidget(
          app(
            dutyDrawer: true,
            dutyPeriods: [over],
            dutyAssignments: assignments,
          ),
        );
        await tester.pumpAndSettle();
        expect(openButton, findsNothing);
        expect(closeButton, findsNothing);

        await finish(tester);
      });

      testWidgets('in a narrow drawer the names go under the range, and '
          'nothing overflows', (tester) async {
        fullHd(tester);
        // One of ten day columns: under 190 px for the whole drawer.
        await tester.pumpWidget(
          app(
            drawerOpen: true,
            visibleDays: 10,
            drawerColumns: 1,
            dutyDrawer: true,
            dutyPeriods: periods,
            dutyAssignments: assignments,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(drawerText(dutyTitle), findsOneWidget);
        expect(inCard(both), findsOneWidget);
        for (var i = 0; i < 2; i++) {
          final range = tester.getRect(inCard(dutyRangeLabel(ahead[i])));
          final names = tester.getRect(inCard(players[i + 1].displayName));
          expect(names.top, greaterThanOrEqualTo(range.bottom));
          expect(names.left, range.left);
          expect(names.width, greaterThan(0));
        }

        await finish(tester);
      });

      testWidgets('a card too short for the plan scrolls; the idle reset '
          'brings it back to the top', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            notices: [notice('1', 'Brigáda')],
            slots: [fed('next', day.addDays(1), 'Příští')],
            drawerOpen: true,
            dutyDrawer: true,
            dutyShare: 10,
            dutyPeriods: periods,
            dutyAssignments: assignments,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final card = tester.getRect(cardTitled(dutyTitle));
        final last = inCard(players[5].displayName);
        expect(tester.getRect(last).top, greaterThan(card.bottom));

        await tester.drag(
          find.descendant(
            of: cardTitled(dutyTitle),
            matching: find.byType(Scrollable),
          ),
          const Offset(0, -600),
        );
        await tester.pumpAndSettle();
        expect(tester.getRect(last).bottom, lessThanOrEqualTo(card.bottom));

        await tester.pump(const Duration(seconds: 61));
        await tester.pumpAndSettle();
        expect(tester.getRect(last).top, greaterThan(card.bottom));

        await finish(tester);
      });

      testWidgets('a match being played takes the whole drawer, the card '
          'too; the list of matches brings it back', (tester) async {
        fullHd(tester);
        await tester.pumpWidget(
          app(
            slots: [fed('m', day, 'Hrají')],
            results: {'m': res('m', 'in_progress', 2, 1)},
            lineups: {'m': lineup},
            dutyDrawer: true,
            dutyPeriods: periods,
            dutyAssignments: assignments,
          ),
        );
        await tester.pumpAndSettle();
        expect(liveView, findsOneWidget);
        expect(drawerText(dutyTitle), findsNothing);

        await tester.tap(find.byTooltip('Všechny zápasy'));
        await tester.pumpAndSettle();
        expect(liveView, findsNothing);
        expect(drawerText(dutyTitle), findsOneWidget);
        expect(drawerText('ZÁPASY'), findsOneWidget);

        await finish(tester);
      });
    });
  });

  testWidgets('the plan without anyone serving today leaves the „Teď slouží“ '
      'block out', (tester) async {
    final next = DutyPeriod(
      id: 'next',
      startsOn: Day(2026, 10, 12),
      endsOn: Day(2026, 10, 18),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          kioskDutyPlanProvider.overrideWithValue((
            now: null,
            next: [KioskDutyEntry(next, const ['Jan Novák'])],
          )),
        ],
        child: const MaterialApp(home: Scaffold(body: KioskDutyDialog())),
      ),
    );
    expect(find.text('Služby na kantýně'), findsOneWidget);
    expect(find.textContaining('Teď slouží'), findsNothing);
    expect(find.text('Další'), findsOneWidget);
    expect(find.text('po 12. 10. – ne 18. 10.'), findsOneWidget);
    expect(find.text('Jan Novák'), findsOneWidget);
  });
}

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/theme.dart';
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/kiosk_layout.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/week_players.dart';
import 'package:rezervator/features/kiosk/kiosk_connection.dart';
import 'package:rezervator/features/kiosk/kiosk_info_panel.dart';
import 'package:rezervator/features/clubhouse/widgets/zapis_page.dart';
import 'package:rezervator/features/kiosk/kiosk_shell.dart';
import 'package:rezervator/features/kiosk/kiosk_stream_window.dart';
import 'package:rezervator/features/kiosk/kiosk_week.dart';
import 'package:rezervator/features/schedule/widgets/calendar_board.dart'
    show calendarRulerWidth;

/// The app's own font: the test font's glyphs are wider than Manrope's, so
/// a fit measured against it would not be the kiosk's.
Future<void> _loadManrope() async {
  final loader = FontLoader(appFontFamily);
  for (final weight in ['Regular', 'Medium', 'Bold', 'ExtraBold']) {
    final bytes = File('assets/fonts/Manrope-$weight.ttf').readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

/// „Hráči týdne“ (module `week`, 0078): the card's fit on a Full HD kiosk
/// (the categories that fit, each its best three, „Více“ for the rest), the
/// full-screen detail (chips, segments, columns, the tap to the Zápis), and
/// the module in a panel and in the shell — no line in the week, no room.
void main() {
  setUpAll(_loadManrope);

  // Thursday 15 October: the week shown is 5.–11. 10.
  final now = DateTime(2026, 10, 15, 12);

  // One day column of a Full HD kiosk with 8 days on the screen; a panel
  // is whole columns of it (kioskPanelWidths).
  const column = (1920 - calendarRulerWidth) / 8;
  // The shell's panel at 1080: the status bar and the idle bar take the
  // rest.
  const panelHeight = 981.0;
  // A panel's padding (12 around) and the gap between two modules.
  const pad = 12.0;

  Size cardSize({required int days, required int share}) => Size(
    days * column - 2 * pad,
    share == 100
        ? panelHeight - 2 * pad
        : (panelHeight - 2 * pad - pad) * share / 100,
  );

  void fullHd(WidgetTester tester) {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  WeekLine line(
    String name,
    int total, {
    WeekGender? gender = WeekGender.male,
    int? throws = 120,
    bool away = false,
    String match = 'm1',
    String competition = 'Divize AS',
    String team = 'Termínátor A',
    String? clubId = 'c1',
    String? clubName = 'Termínátor',
    int clubColor = 4,
  }) => WeekLine(
    matchId: match,
    date: Day(2026, 10, 10),
    playerName: name,
    playerSlug: name.toLowerCase().replaceAll(' ', '-'),
    total: total,
    throws: throws,
    isAway: away,
    competition: competition,
    teamName: team,
    opponent: 'KK Slavoj',
    clubId: clubId,
    clubName: clubName,
    clubColor: clubColor,
    gender: gender,
  );

  // Four players in each of the four categories.
  final week = [
    for (final (category, gender, throws) in const [
      ('M', WeekGender.male, 120),
      ('Z', WeekGender.female, 120),
      ('N', WeekGender.male, 100),
      ('R', WeekGender.female, 100),
    ])
      for (var i = 0; i < 4; i++)
        line(
          'Hráč $category$i',
          600 - 10 * i,
          gender: gender,
          throws: throws,
          away: i.isOdd,
        ),
  ];

  // The week the clock shows: 5. 10.
  final lastWeek = previousWeekMonday(now);

  /// [lines] as the provider read them for [monday] (the clock's week when
  /// null).
  List<Override> overrides(List<WeekLine> lines, {Day? monday}) => [
    nowProvider.overrideWith((ref) => Stream.value(now)),
    weekPlayersProvider.overrideWith(
      (ref) async => (monday: monday ?? lastWeek, lines: lines),
    ),
  ];

  Future<void> pumpCard(
    WidgetTester tester,
    Size size,
    List<WeekLine> lines, {
    VoidCallback? onOpen,
    Day? monday,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(lines, monday: monday),
        child: MaterialApp(
          theme: buildTheme(Brightness.dark),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox.fromSize(
                size: size,
                child: KioskWeekCard(onOpen: onOpen ?? () {}),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  final more = find.text('Více');

  group('KioskWeekCard', () {
    testWidgets('the title names the week; alone in a panel every category '
        'fits, each its best three', (tester) async {
      fullHd(tester);
      await pumpCard(tester, cardSize(days: 2, share: 100), week);
      expect(find.text('HRÁČI TÝDNE · 5.–11. 10.'), findsOneWidget);
      for (final category in WeekCategory.values) {
        expect(find.text(category.label), findsOneWidget);
      }
      expect(find.text('1. Hráč M0'), findsOneWidget);
      expect(find.text('600'), findsNWidgets(4));
      expect(find.text('3. Hráč M2'), findsOneWidget);
      // The fourth is in the detail only.
      expect(find.text('4. Hráč M3'), findsNothing);
      expect(find.text('Termínátor A · doma'), findsNWidgets(8));
      expect(find.text('Termínátor A · venku'), findsNWidgets(4));
      expect(more, findsNothing);
    });

    testWidgets('the title names the week the lines were read for, not the '
        'clock\'s: lines kept while a read is under way or failed keep their '
        'dates', (tester) async {
      fullHd(tester);
      // The clock is past the turn to 5.–11. 10.; the lines are still the
      // ones read for 28. 9.
      await pumpCard(
        tester,
        cardSize(days: 2, share: 100),
        week,
        monday: Day(2026, 9, 28),
      );
      expect(find.text('HRÁČI TÝDNE · 28. 9.–4. 10.'), findsOneWidget);
      expect(find.text('HRÁČI TÝDNE · 5.–11. 10.'), findsNothing);
    });

    testWidgets('at 30 % only the categories that fit whole, „Více“ for '
        'the rest', (tester) async {
      fullHd(tester);
      await pumpCard(tester, cardSize(days: 2, share: 30), week);
      expect(find.text(WeekCategory.men120.label), findsOneWidget);
      expect(find.text(WeekCategory.women100.label), findsNothing);
      expect(more, findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('one entry per player: two matches in the week, his best '
        'line once', (tester) async {
      fullHd(tester);
      await pumpCard(tester, cardSize(days: 2, share: 100), [
        line('Jan Novák', 571, match: 'm1'),
        line('Jan Novák', 590, match: 'm2', away: true),
        line('Petr Malý', 580),
      ]);
      expect(find.text('1. Jan Novák'), findsOneWidget);
      expect(find.text('2. Petr Malý'), findsOneWidget);
      expect(find.textContaining('Jan Novák'), findsOneWidget);
      expect(find.text('590'), findsOneWidget);
      expect(find.text('571'), findsNothing);
    });

    testWidgets('no gender known yet: the competitions instead of the '
        'categories', (tester) async {
      fullHd(tester);
      await pumpCard(tester, cardSize(days: 2, share: 55), [
        line('Jan Novák', 571, gender: null),
        line('Petr Malý', 580, gender: null, competition: '1. KLM'),
      ]);
      expect(find.text('1. KLM'), findsOneWidget);
      expect(find.text('Divize AS'), findsOneWidget);
      expect(find.text('1. Petr Malý'), findsOneWidget);
    });

    testWidgets('a tap anywhere on the card opens the week', (tester) async {
      fullHd(tester);
      var opened = 0;
      await pumpCard(
        tester,
        cardSize(days: 2, share: 30),
        week,
        onOpen: () => opened++,
      );
      await tester.tap(find.text('HRÁČI TÝDNE · 5.–11. 10.'));
      await tester.tap(more);
      await tester.tap(find.text('1. Hráč M0'));
      expect(opened, 3);
    });
  });

  group('showKioskWeekPlayers', () {
    PrioritySlot slot(String id) => PrioritySlot(
      id: id,
      date: Day(2026, 10, 10),
      startsAt: const HourMinute(14, 0),
      endsAt: const HourMinute(17, 0),
      type: PrioritySlot.fallbackMatchType,
      homeTeam: 'Termínátor A',
      awayTeam: 'KK Slavoj',
      importKey: 'cka:$id',
    );

    Future<List<PrioritySlot>> pumpDetail(
      WidgetTester tester,
      List<WeekLine> lines, {
      List<PrioritySlot>? slots,
      Day? monday,
    }) async {
      final opened = <PrioritySlot>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...overrides(lines, monday: monday),
            prioritySlotsProvider.overrideWithValue(
              slots ?? [slot('m1'), slot('m2')],
            ),
          ],
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showKioskWeekPlayers(
                    context,
                    wrap: (child) =>
                        Theme(data: buildTheme(Brightness.dark), child: child),
                    onOpenMatch: opened.add,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return opened;
    }

    final page = find.byType(KioskWeekPlayersPage);
    Finder inPage(Finder f) => find.descendant(of: page, matching: f);

    testWidgets('full screen in the theme [wrap] gives it: the title, one '
        'column per category, each a full ranking; „Zavřít“ closes it', (
      tester,
    ) async {
      fullHd(tester);
      await pumpDetail(tester, week);
      expect(tester.getSize(page).width, 1920);
      expect(tester.getSize(page).height, 1080);
      expect(Theme.of(tester.element(page)).brightness, Brightness.dark);
      expect(find.text('Hráči týdne 5.–11. 10.'), findsOneWidget);
      for (final category in WeekCategory.values) {
        expect(inPage(find.text(category.label)), findsOneWidget);
      }
      // All four of a category, the fourth too.
      expect(inPage(find.text('Hráč M3')), findsOneWidget);
      expect(
        inPage(find.text('Termínátor A – KK Slavoj · venku')),
        findsNWidgets(8),
      );
      // Side by side: men's 120 left of women's.
      expect(
        tester.getCenter(find.text(WeekCategory.men120.label)).dx,
        lessThan(tester.getCenter(find.text(WeekCategory.women120.label)).dx),
      );

      await tester.tap(find.byTooltip('Zavřít'));
      await tester.pumpAndSettle();
      expect(page, findsNothing);
    });

    testWidgets('the title names the week the lines were read for, not the '
        'clock\'s', (tester) async {
      fullHd(tester);
      await pumpDetail(tester, week, monday: Day(2026, 9, 28));
      expect(find.text('Hráči týdne 28. 9.–4. 10.'), findsOneWidget);
      expect(find.text('Hráči týdne 5.–11. 10.'), findsNothing);
    });

    testWidgets('Doma / Venku keep the lines played there; Vše all', (
      tester,
    ) async {
      fullHd(tester);
      await pumpDetail(tester, week);
      await tester.tap(find.text('Venku'));
      await tester.pumpAndSettle();
      expect(inPage(find.text('Hráč M1')), findsOneWidget);
      expect(inPage(find.text('Hráč M0')), findsNothing);
      // Ranked among themselves: first of its column.
      expect(
        find.descendant(
          of: find
              .ancestor(of: find.text('Hráč M1'), matching: find.byType(Row))
              .first,
          matching: find.text('1.'),
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Doma'));
      await tester.pumpAndSettle();
      expect(inPage(find.text('Hráč M0')), findsOneWidget);
      expect(inPage(find.text('Hráč M1')), findsNothing);

      await tester.tap(find.text('Vše'));
      await tester.pumpAndSettle();
      expect(inPage(find.text('Hráč M0')), findsOneWidget);
      expect(inPage(find.text('Hráč M1')), findsOneWidget);
    });

    testWidgets('Soutěže and Oddíly: a column per competition and per club, '
        'Czech order, the ones without one last; unknown gender there too', (
      tester,
    ) async {
      fullHd(tester);
      final lines = [
        line('Jan Novák', 571),
        line('Eva Malá', 520, competition: 'Česká liga', gender: null),
        line(
          'Petr Malý',
          580,
          competition: 'Celostátní liga',
          clubId: null,
          clubName: null,
          clubColor: -1,
        ),
        line(
          'Ota Bílý',
          560,
          clubId: 'c2',
          clubName: 'Čechie',
          clubColor: 2,
        ),
      ];
      await pumpDetail(tester, lines);
      // Eva's gender is unknown: in no category.
      expect(inPage(find.text('Eva Malá')), findsNothing);

      await tester.tap(find.text('Soutěže'));
      await tester.pumpAndSettle();
      final competitions = [
        for (final name in ['Celostátní liga', 'Česká liga', 'Divize AS'])
          tester.getCenter(inPage(find.text(name))).dx,
      ];
      expect(competitions, orderedEquals([...competitions]..sort()));
      expect(inPage(find.text('Eva Malá')), findsOneWidget);

      await tester.tap(find.text('Oddíly'));
      await tester.pumpAndSettle();
      final clubs = [
        for (final name in ['Čechie', 'Termínátor', weekOtherGroup])
          tester.getCenter(inPage(find.text(name))).dx,
      ];
      expect(clubs, orderedEquals([...clubs]..sort()));
    });

    testWidgets('columns that do not fit scroll sideways', (tester) async {
      fullHd(tester);
      await pumpDetail(tester, [
        for (var i = 0; i < 8; i++)
          line('Hráč $i', 500 + i, competition: 'Soutěž $i'),
      ]);
      await tester.tap(find.text('Soutěže'));
      await tester.pumpAndSettle();
      expect(inPage(find.text('Soutěž 0')), findsOneWidget);
      expect(inPage(find.text('Soutěž 7')), findsNothing);
      await tester.drag(find.text('Soutěž 0'), const Offset(-2000, 0));
      await tester.pumpAndSettle();
      expect(inPage(find.text('Soutěž 7')), findsOneWidget);
    });

    testWidgets('a tap on a line opens that match\'s Zápis; a match the '
        'slots do not hold opens nothing', (tester) async {
      fullHd(tester);
      final opened = await pumpDetail(
        tester,
        [
          line('Jan Novák', 571, match: 'm2'),
          line('Petr Malý', 560, match: 'gone'),
        ],
      );
      await tester.tap(inPage(find.text('Jan Novák')));
      await tester.tap(inPage(find.text('Petr Malý')));
      expect([for (final s in opened) s.id], ['m2']);
    });

    testWidgets('nothing for the filter: says so', (tester) async {
      fullHd(tester);
      await pumpDetail(tester, [line('Jan Novák', 571)]);
      await tester.tap(find.text('Venku'));
      await tester.pumpAndSettle();
      expect(find.text('Žádné výsledky pro tento výběr.'), findsOneWidget);
    });
  });

  group('in the panels', () {
    const settings = ScheduleSettings(
      laneCount: 2,
      trainingWeekdays: {1, 2, 3, 4, 5, 6, 7},
      bookingHorizonDays: 14,
      maxActiveReservations: 3,
      kioskVisibleDays: 8,
      kioskPanels: KioskPanels(
        left: KioskPanel(days: 2, open: true),
        right: KioskPanel(days: 2, open: false),
        modules: [
          KioskModulePlacement(id: 'duty', side: PanelSide.off, share: 30),
          KioskModulePlacement(id: 'notices', side: PanelSide.off, share: 40),
          KioskModulePlacement(id: 'matches', side: PanelSide.off, share: 60),
          KioskModulePlacement(id: 'guide', side: PanelSide.left, share: 45),
          KioskModulePlacement(id: 'week', side: PanelSide.left, share: 55),
        ],
      ),
    );

    Future<KioskPanelContent?> leftContent(List<WeekLine> lines) async {
      final container = ProviderContainer(
        overrides: [
          ...overrides(lines),
          settingsProvider.overrideWith((ref) => Stream.value(settings)),
        ],
      );
      addTearDown(container.dispose);
      final sub = container.listen(
        kioskPanelContentProvider(PanelSide.left),
        (_, _) {},
      );
      addTearDown(sub.close);
      await container.read(settingsProvider.future);
      await container.read(nowProvider.future);
      await container.read(weekPlayersProvider.future);
      return container.read(kioskPanelContentProvider(PanelSide.left));
    }

    test('the module takes room only while the week has lines', () async {
      final empty = await leftContent(const []);
      expect([for (final e in empty!.entries) e.module], [KioskModule.guide]);
      final full = await leftContent(week);
      expect(
        [for (final e in full!.entries) (e.module, e.share)],
        [(KioskModule.guide, 45), (KioskModule.week, 55)],
      );
    });

    testWidgets('KioskPanelView: the card takes its share and opens the '
        'week on a tap', (tester) async {
      fullHd(tester);
      var opened = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...overrides(week),
            settingsProvider.overrideWith((ref) => Stream.value(settings)),
          ],
          child: MaterialApp(
            theme: buildTheme(Brightness.dark),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  height: panelHeight,
                  child: KioskPanelView(
                    side: PanelSide.left,
                    width: 2 * column,
                    open: true,
                    content: const KioskPanelContent(
                      side: PanelSide.left,
                      entries: [KioskPanelEntry(KioskModule.week, 55)],
                    ),
                    onOpenNotice: (_) {},
                    onOpenMatch: (_) {},
                    onOpenWeek: () => opened++,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final card = find.byType(KioskWeekCard);
      // Alone in the panel: all of it.
      final want = cardSize(days: 2, share: 100);
      expect(tester.getSize(card).width, closeTo(want.width, 1e-6));
      expect(tester.getSize(card).height, closeTo(want.height, 1e-6));
      await tester.tap(card);
      expect(opened, 1);
    });

    Future<void> pumpShell(
      WidgetTester tester,
      List<WeekLine> lines, {
      List<PrioritySlot> slots = const [],
      Map<String, MatchResult> results = const {},
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...overrides(lines),
            settingsProvider.overrideWith(
              (ref) => Stream.value(
                ScheduleSettings(
                  laneCount: 2,
                  trainingWeekdays: const {1, 2, 3, 4, 5, 6, 7},
                  bookingHorizonDays: 14,
                  maxActiveReservations: 3,
                  kioskVisibleDays: 8,
                  // The week alone on the left: without lines, no panel.
                  kioskPanels: KioskPanels.defaults
                      .withSide(KioskModule.notices, PanelSide.off)
                      .withSide(KioskModule.matches, PanelSide.off)
                      .withSide(KioskModule.week, PanelSide.left)
                      .withPanel(PanelSide.left, open: true),
                ),
              ),
            ),
            timeBlocksProvider.overrideWith((ref) => Stream.value(const [])),
            dayOverridesProvider.overrideWith((ref) => Stream.value(const [])),
            prioritySlotsProvider.overrideWithValue(slots),
            rentalsProvider.overrideWith((ref) => Stream.value(const [])),
            weekReservationsProvider.overrideWith(
              (ref, monday) => Stream.value(const []),
            ),
            playersProvider.overrideWith((ref) async => const []),
            messagesProvider.overrideWith((ref) => Stream.value(const [])),
            kioskSocketOpenProvider.overrideWithValue(() => true),
            matchResultsProvider.overrideWith((ref) => Stream.value(results)),
            matchPlayerResultsProvider.overrideWith(
              (ref, id) => Stream.value(const []),
            ),
            matchRegnumsProvider.overrideWith((ref, key) async => const {}),
            // The stream's player stands in as text: a platform view does
            // not run under flutter_test.
            kioskStreamContentProvider.overrideWithValue(
              (videoId, {required interactive, onEnded}) => Text(
                'player $videoId ${interactive ? 'on' : 'off'}',
                key: const ValueKey('player'),
              ),
            ),
            dutyPeriodsProvider.overrideWith((ref) => Stream.value(const [])),
            dutyAssignmentsProvider.overrideWith(
              (ref) => Stream.value(const []),
            ),
          ],
          // The app's light theme around the kiosk's dark one: the detail
          // is dark only through the shell's wrap.
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: const KioskShell(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the shell: no line in the week, no left panel', (
      tester,
    ) async {
      fullHd(tester);
      await pumpShell(tester, const []);
      expect(find.byType(KioskPanelView), findsNothing);
      expect(find.byType(KioskWeekCard), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the shell: the week in the left panel, a tap opens it full '
        'screen in the kiosk\'s theme, the idle reset closes it', (
      tester,
    ) async {
      fullHd(tester);
      await pumpShell(tester, week);
      final card = find.byType(KioskWeekCard);
      expect(card, findsOneWidget);
      expect(tester.getSize(find.byType(KioskPanelView)).width, 2 * column);

      await tester.tap(card);
      await tester.pumpAndSettle();
      final page = find.byType(KioskWeekPlayersPage);
      expect(page, findsOneWidget);
      expect(Theme.of(tester.element(page)).brightness, Brightness.dark);

      // A minute without a touch: the kiosk starts over, the week shut.
      await tester.pump(const Duration(seconds: 61));
      await tester.pumpAndSettle();
      expect(page, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the shell: no gender known yet — the card lists the '
        'competitions, and a tap opens the week on Soutěže, not on an empty '
        'Kategorie', (tester) async {
      fullHd(tester);
      await pumpShell(tester, [
        line('Jan Novák', 571, gender: null),
        line('Petr Malý', 580, gender: null, competition: '1. KLM'),
      ]);
      await tester.tap(find.byType(KioskWeekCard));
      await tester.pumpAndSettle();
      final page = find.byType(KioskWeekPlayersPage);
      Finder inPage(Finder f) => find.descendant(of: page, matching: f);
      expect(page, findsOneWidget);
      expect(inPage(find.text('1. KLM')), findsOneWidget);
      expect(inPage(find.text('Divize AS')), findsOneWidget);
      expect(inPage(find.text('Petr Malý')), findsOneWidget);
      expect(inPage(find.text('Jan Novák')), findsOneWidget);
      const empty = 'Žádné výsledky pro tento výběr.';
      expect(inPage(find.text(empty)), findsNothing);
      expect(
        tester
            .widget<SegmentedButton<Object>>(
              inPage(find.byWidgetPredicate((w) => w is SegmentedButton)),
            )
            .selected
            .map((v) => (v as Enum).name)
            .toList(),
        ['competitions'],
      );

      // Kategorie is still the visitor's to pick: none there yet.
      await tester.tap(inPage(find.text('Kategorie')));
      await tester.pumpAndSettle();
      expect(inPage(find.text(empty)), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the shell: week → line → Zápis → „Přehrát záznam“ leaves '
        'the week and plays the stream on the board, not behind the '
        'week', (tester) async {
      fullHd(tester);
      await pumpShell(
        tester,
        week,
        slots: [
          PrioritySlot(
            id: 'm1',
            date: Day(2026, 10, 10),
            startsAt: const HourMinute(14, 0),
            endsAt: const HourMinute(17, 0),
            type: PrioritySlot.fallbackMatchType,
            homeTeam: 'Termínátor A',
            awayTeam: 'KK Slavoj',
            importKey: 'cka:m1',
            videoUrl: 'https://www.youtube.com/watch?v=wOq9EODb8w8',
          ),
        ],
        results: {
          'm1': MatchResult.fromJson(const {
            'match_id': 'm1',
            'status': 'finished',
            'home_points': 6,
            'away_points': 2,
            'fetched_at': '2026-10-10T18:00:00+00:00',
          }),
        },
      );
      final page = find.byType(KioskWeekPlayersPage);
      final player = find.byKey(const ValueKey('player'));
      await tester.tap(find.byType(KioskWeekCard));
      await tester.pumpAndSettle();
      expect(page, findsOneWidget);
      expect(player, findsNothing);

      await tester.tap(
        find.descendant(of: page, matching: find.text('Hráč M0')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ZapisPage), findsOneWidget);

      await tester.tap(find.text('Přehrát záznam'));
      await tester.pumpAndSettle();
      // Both routes are gone: the player runs on the board, where the
      // visitor sees it and can touch it.
      expect(find.byType(ZapisPage), findsNothing);
      expect(page, findsNothing);
      expect(find.text('player wOq9EODb8w8 on'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}

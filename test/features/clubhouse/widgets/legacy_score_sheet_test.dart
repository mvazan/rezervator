import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/clubhouse/widgets/legacy_score_sheet.dart';

void main() {
  const home = 'SKK Veverky Brno A';
  const away = 'KK MS Brno D';

  final slot = PrioritySlot(
    id: 'm1',
    date: Day(2026, 9, 20),
    startsAt: const HourMinute(17, 30),
    endsAt: const HourMinute(20, 30),
    type: PrioritySlot.fallbackMatchType,
    homeTeam: home,
    awayTeam: away,
  );

  final result = MatchResult.fromJson(const {
    'match_id': 'm1',
    'status': 'finished',
    'home_points': 13,
    'away_points': 7,
    'home_total': 3460,
    'away_total': 3349,
    'home_fulls': 1780,
    'away_fulls': 1700,
    'home_spares': 120,
    'away_spares': 110,
    'home_errors': 40,
    'away_errors': 35,
    'home_set_points': 15,
    'away_set_points': 9,
    'fetched_at': '2026-09-23T10:00:00+00:00',
  });

  // Lane values deliberately DON'T sum to the player's own totals below —
  // proves the Celkem row reads `player.fulls/…/setPoints` straight off the
  // row, not by re-summing `player.lanes`.
  final homePlayer = MatchPlayerResult.fromJson(const {
    'id': 'p1',
    'match_id': 'm1',
    'side': 'home',
    'position': 1,
    'player_name': 'Jan Novák',
    'fulls': 350,
    'spares': 20,
    'errors': 6,
    'total': 580,
    'set_points': 2,
    'team_points': 1,
    'lanes': [
      {
        'lane': 1,
        'fulls': 175,
        'spares': 10,
        'errors': 2,
        'total': 290,
        'setPoints': 1,
      },
      {
        'lane': 2,
        'fulls': 170,
        'spares': 11,
        'errors': 3,
        'total': 285,
        'setPoints': 0,
      },
    ],
  });

  final awayPlayer = MatchPlayerResult.fromJson(const {
    'id': 'p2',
    'match_id': 'm1',
    'side': 'away',
    'position': 1,
    'player_name': 'Petr Svoboda',
    'fulls': 340,
    'spares': 18,
    'errors': 8,
    'total': 550,
    'set_points': 0,
    'team_points': 0,
  });

  Widget app({
    MatchResult? result,
    List<MatchPlayerResult> players = const [],
  }) => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: LegacyScoreSheet(slot: slot, result: result, players: players),
      ),
    ),
  );

  testWidgets(
    'team summary row shows both team names, Body (match points), team '
    'stat totals and the Družstvo (team points) sum',
    (tester) async {
      await tester.pumpWidget(
        app(result: result, players: [homePlayer, awayPlayer]),
      );
      await tester.pumpAndSettle();

      expect(find.text(home), findsOneWidget);
      expect(find.text(away), findsOneWidget);
      expect(find.text('13'), findsOneWidget); // Body (home match points)
      expect(find.text('7'), findsOneWidget); // Body (away match points)
      expect(find.text('1780'), findsOneWidget); // Plné (home team total)
      expect(find.text('1700'), findsOneWidget); // Plné (away team total)
      expect(find.text('3460'), findsOneWidget); // Celkem (home team total)
      expect(find.text('3349'), findsOneWidget); // Celkem (away team total)
      expect(find.text('15'), findsOneWidget); // Dílčí (home set points)
      expect(find.text('9'), findsOneWidget); // Dílčí (away set points)
      // Družstvo: sum of player.teamPoints on each side — only homePlayer
      // (1) has any; awayPlayer's is 0.
      expect(find.text('+111'), findsOneWidget); // team Rozdíl
    },
  );

  testWidgets(
    'a pairing block shows both players, lane and Celkem lines (from the '
    "player's own totals, not the lane sum), the Družstvo team-points "
    'value instead of a badge, and a signed Rozdíl',
    (tester) async {
      await tester.pumpWidget(
        app(result: result, players: [homePlayer, awayPlayer]),
      );
      await tester.pumpAndSettle();

      expect(find.text('1. Jan Novák'), findsOneWidget);
      expect(find.text('1. Petr Svoboda'), findsOneWidget);

      // Lane lines (home player only).
      expect(find.text('175'), findsOneWidget);
      expect(find.text('170'), findsOneWidget);
      expect(find.text('290'), findsOneWidget);
      expect(find.text('285'), findsOneWidget);

      // Celkem line per player: the player's OWN fulls/spares/errors/total/
      // setPoints, which deliberately differ from summing the lanes above.
      expect(find.text('350'), findsOneWidget);
      expect(find.text('580'), findsOneWidget);
      expect(find.text('340'), findsOneWidget);
      expect(find.text('550'), findsOneWidget);
      // The header row2 label (once per side) + the per-player Celkem-row
      // label (once per player) — 2 + 2.
      expect(find.text('Celkem'), findsNWidgets(4));

      // Rozdíl: home 580 - away 550 = +30.
      expect(find.text('+30'), findsOneWidget);
    },
  );

  testWidgets('no stray digit-only text renders beyond the known stats (guards '
      'against a registration number or similar ever appearing)', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(result: result, players: [homePlayer, awayPlayer]),
    );
    await tester.pumpAndSettle();

    const expectedNumbers = {
      // Team summary (home/away) + pin differential.
      '13', '7', '1780', '1700', '120', '110', '40', '35', '3460', '3349',
      '15', '9', '+111',
      // Home player: lane 1, lane 2, Celkem.
      '175', '10', '2', '290', '1',
      '170', '11', '3', '285', '0',
      '350', '20', '6', '580',
      // Away player: Celkem only (no lanes).
      '340', '18', '8', '550',
      // Rozdíl.
      '+30',
    };
    final digitOnly = RegExp(r'^[+-]?\d+$');
    final rendered = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .whereType<String>()
        .where(digitOnly.hasMatch)
        .toSet();

    expect(rendered.difference(expectedNumbers), isEmpty);
  });

  testWidgets(
    'a position present on only one side renders that side alone, blank '
    'on the other, without crashing',
    (tester) async {
      final raggedHome = MatchPlayerResult.fromJson(const {
        'id': 'p3',
        'match_id': 'm1',
        'side': 'home',
        'position': 2,
        'player_name': 'Karel Dvořák',
        'fulls': 300,
        'spares': 15,
        'errors': 9,
        'total': 480,
        'set_points': 1,
        'team_points': 0,
      });
      await tester.pumpWidget(
        app(result: result, players: [homePlayer, awayPlayer, raggedHome]),
      );
      await tester.pumpAndSettle();

      expect(find.text('2. Karel Dvořák'), findsOneWidget);
      // No away player at position 2, and no crash getting there.
      expect(tester.takeException(), isNull);
      // Ragged position's Rozdíl is blank (no away total to diff against) —
      // no stray '+'/'-' beyond the position-1 pairing's own '+30'.
      expect(find.textContaining('-'), findsNothing);
      expect(find.text('+30'), findsOneWidget);
    },
  );

  testWidgets('Rozdíl is negative and red (#FF0000) when the away side '
      'scored more', (tester) async {
    final home2 = MatchPlayerResult.fromJson(const {
      'id': 'ph',
      'match_id': 'm2',
      'side': 'home',
      'position': 1,
      'player_name': 'Home Player',
      'total': 500,
    });
    final away2 = MatchPlayerResult.fromJson(const {
      'id': 'pa',
      'match_id': 'm2',
      'side': 'away',
      'position': 1,
      'player_name': 'Away Player',
      'total': 520,
    });
    await tester.pumpWidget(app(players: [home2, away2]));
    await tester.pumpAndSettle();

    final diffText = tester.widget<Text>(find.text('-20'));
    expect(diffText.style?.color, const Color(0xFFFF0000));
  });

  testWidgets('Rozdíl on a tie renders 0, black (not tinted as a win)', (
    tester,
  ) async {
    final home2 = MatchPlayerResult.fromJson(const {
      'id': 'ph',
      'match_id': 'm2',
      'side': 'home',
      'position': 1,
      'player_name': 'Home Player',
      'total': 500,
      // Non-zero, so the team-level Družstvo sum (also '0' by default,
      // since these fixtures have no result/other players) doesn't
      // collide with the Rozdíl cell's own '0' below.
      'team_points': 0.5,
    });
    final away2 = MatchPlayerResult.fromJson(const {
      'id': 'pa',
      'match_id': 'm2',
      'side': 'away',
      'position': 1,
      'player_name': 'Away Player',
      'total': 500,
      'team_points': 0.5,
    });
    await tester.pumpWidget(app(players: [home2, away2]));
    await tester.pumpAndSettle();

    final diffText = tester.widget<Text>(find.text('0'));
    expect(diffText.style?.color, const Color(0xFF000000));
  });

  testWidgets('Rozdíl renders blank, not a bogus number, when one total '
      'is null', (tester) async {
    final home2 = MatchPlayerResult.fromJson(const {
      'id': 'ph',
      'match_id': 'm2',
      'side': 'home',
      'position': 1,
      'player_name': 'Home Player',
      // total intentionally absent — the match is still live on this lane.
    });
    final away2 = MatchPlayerResult.fromJson(const {
      'id': 'pa',
      'match_id': 'm2',
      'side': 'away',
      'position': 1,
      'player_name': 'Away Player',
      'total': 500,
    });
    await tester.pumpWidget(app(players: [home2, away2]));
    await tester.pumpAndSettle();

    expect(find.textContaining('+'), findsNothing);
    expect(find.textContaining('-'), findsNothing);
  });

  testWidgets('a result with no lineup yet still shows the team summary row', (
    tester,
  ) async {
    await tester.pumpWidget(app(result: result, players: const []));
    await tester.pumpAndSettle();

    expect(find.text('Zápis'), findsOneWidget);
    expect(find.text(home), findsOneWidget);
    expect(find.text(away), findsOneWidget);
    expect(find.text('3460'), findsOneWidget);
    // No lineup: no player-column header rows.
    expect(find.text('Jméno a příjmení hráče'), findsNothing);
  });

  testWidgets('no result and no players renders nothing', (tester) async {
    await tester.pumpWidget(app(result: null, players: const []));
    await tester.pumpAndSettle();

    expect(find.text('Zápis'), findsNothing);
    expect(find.text(home), findsNothing);
    expect(find.text('Jméno a příjmení hráče'), findsNothing);
  });

  testWidgets('the Zvětšit button is hidden when there is no lineup yet', (
    tester,
  ) async {
    await tester.pumpWidget(app(result: result, players: const []));
    await tester.pumpAndSettle();

    expect(find.text('Zápis'), findsOneWidget);
    expect(find.byIcon(Icons.open_in_full), findsNothing);
  });

  testWidgets(
    'tapping Zvětšit pushes a full-screen page with the same data and no '
    'header row of its own; close pops it back',
    (tester) async {
      await tester.pumpWidget(
        app(result: result, players: [homePlayer, awayPlayer]),
      );
      await tester.pumpAndSettle();

      expect(find.text('580'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.open_in_full));
      await tester.pumpAndSettle();

      final page = find.byType(LegacyScoreSheetPage);
      expect(page, findsOneWidget);
      expect(find.widgetWithText(AppBar, 'Zápis'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
      expect(find.text('580'), findsWidgets);
      expect(
        find.descendant(of: page, matching: find.byIcon(Icons.open_in_full)),
        findsNothing,
      );
      expect(
        find.descendant(of: page, matching: find.text('Zápis')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: page, matching: find.byType(SingleChildScrollView)),
        findsNothing,
      );

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(find.byType(LegacyScoreSheetPage), findsNothing);
      expect(find.text('580'), findsOneWidget);
    },
  );

  testWidgets(
    'the score sheet ignores the app-wide text-size setting and stays at '
    'its own authored (1.0×) size',
    (tester) async {
      Future<Size> sizeAtAmbientScale(double ambientScale) async {
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(ambientScale)),
            child: app(result: result, players: [homePlayer, awayPlayer]),
          ),
        );
        await tester.pumpAndSettle();
        return tester.renderObject<RenderParagraph>(find.text('1780')).size;
      }

      final atNormal = await sizeAtAmbientScale(1.0);
      final atLargest = await sizeAtAmbientScale(1.3); // "Zvětšené" setting
      expect(atLargest, atNormal);
    },
  );

  group('kuzelky.com 1:1 styling (Fix round 4)', () {
    Color? bgOf(WidgetTester tester, Finder textFinder) {
      final container = tester.widget<Container>(
        find.ancestor(of: textFinder, matching: find.byType(Container)).first,
      );
      return (container.decoration as BoxDecoration?)?.color;
    }

    testWidgets(
      'a handful of cells carry the reference site\'s exact colours and '
      'sizes',
      (tester) async {
        // Deliberately unambiguous values (no two cells render the same
        // text) so every `find.text` below is unique — a dedicated small
        // fixture rather than reusing the shared one, which repeats values
        // (e.g. team `Dílčí` 9/15 also appear as lane numbers).
        final colorSlot = PrioritySlot(
          id: 'c1',
          date: Day(2026, 9, 20),
          startsAt: const HourMinute(17, 30),
          endsAt: const HourMinute(20, 30),
          type: PrioritySlot.fallbackMatchType,
          homeTeam: 'Colour Home',
          awayTeam: 'Colour Away',
        );
        final colorResult = MatchResult.fromJson(const {
          'match_id': 'c1',
          'status': 'finished',
          'home_points': 9001,
          'away_points': 9011,
          // team Rozdíl = 9002 - 9003 = -1 (negative → red).
          'home_total': 9002,
          'away_total': 9003,
          'home_fulls': 9004,
          'away_fulls': 9014,
          'home_spares': 9005,
          'away_spares': 9015,
          'home_errors': 9006,
          'away_errors': 9016,
          'home_set_points': 9007,
          'away_set_points': 9017,
          'fetched_at': '2026-09-23T10:00:00+00:00',
        });
        final colorHomePlayer = MatchPlayerResult.fromJson(const {
          'id': 'ch1',
          'match_id': 'c1',
          'side': 'home',
          'position': 1,
          'player_name': 'Colour Player',
          'total': 9020,
          'team_points': 9,
        });
        final colorAwayPlayer = MatchPlayerResult.fromJson(const {
          'id': 'ca1',
          'match_id': 'c1',
          'side': 'away',
          'position': 1,
          'player_name': 'Colour Rival',
          // pairing Rozdíl = 9020 - 9008 = +12 (positive → green).
          'total': 9008,
        });

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: LegacyScoreSheet(
                  slot: colorSlot,
                  result: colorResult,
                  players: [colorHomePlayer, colorAwayPlayer],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Header row: grey #CCCCCC, 10dp. Both sides mirror this label —
        // either instance proves the assertion.
        final headerText = find.text('Jméno a příjmení hráče').first;
        expect(bgOf(tester, headerText), const Color(0xFFCCCCCC));
        expect(tester.widget<Text>(headerText).style?.fontSize, 10);

        // Team name cell: grey #CCCCCC, 16dp bold.
        final nameText = find.text('Colour Home');
        expect(bgOf(tester, nameText), const Color(0xFFCCCCCC));
        expect(tester.widget<Text>(nameText).style?.fontSize, 16);

        // Team "Body" (Série column, match points): yellow #FDFDEC, 24dp.
        final bodyText = find.text('9001');
        expect(bgOf(tester, bodyText), const Color(0xFFFDFDEC));
        expect(tester.widget<Text>(bodyText).style?.fontSize, 24);

        // Team Družstvo (sum of player team points): blue #ADD8E6, 20dp.
        // Two cells legitimately show '9' here — the team-level sum and
        // the (single) player's own pairing-level value happen to be the
        // same number — but both are styled identically per the brief, so
        // either instance proves the assertion.
        final druzstvoText = find.text('9').first;
        expect(bgOf(tester, druzstvoText), const Color(0xFFADD8E6));
        expect(tester.widget<Text>(druzstvoText).style?.fontSize, 20);

        // Team-level Rozdíl, negative: red #FF0000.
        expect(
          tester.widget<Text>(find.text('-1')).style?.color,
          const Color(0xFFFF0000),
        );

        // Pairing-level Rozdíl, positive: green #008000.
        expect(
          tester.widget<Text>(find.text('+12')).style?.color,
          const Color(0xFF008000),
        );

        // Player Celkem total: dark red #8B0000, 16dp.
        final totalText = find.text('9020');
        expect(
          tester.widget<Text>(totalText).style?.color,
          const Color(0xFF8B0000),
        );
        expect(tester.widget<Text>(totalText).style?.fontSize, 16);
      },
    );

    testWidgets(
      'the table\'s total width matches the reference site (≈963dp)',
      (tester) async {
        await tester.pumpWidget(
          app(result: result, players: [homePlayer, awayPlayer]),
        );
        await tester.pumpAndSettle();

        final tableSize = tester.getSize(
          find.byWidgetPredicate(
            (w) => w.runtimeType.toString() == '_ScoreTableBody',
          ),
        );
        expect(tableSize.width, 963.0);
      },
    );
  });

  MatchPlayerResult bigPlayer(String side, int position) =>
      MatchPlayerResult.fromJson({
        'id': '$side-$position',
        'match_id': 'big',
        'side': side,
        'position': position,
        'player_name': '${side == 'home' ? 'Home' : 'Away'} $position',
        'fulls': 700,
        'spares': 40,
        'errors': 10,
        'total': 1160,
        'set_points': 4,
        'team_points': side == 'home' ? 1 : 0,
        'lanes': [
          for (var lane = 1; lane <= 4; lane++)
            {
              'lane': lane,
              'fulls': 175,
              'spares': 10,
              'errors': 2,
              'total': 290,
              'setPoints': 1,
            },
        ],
      });
  final bigPlayers = [
    for (var pos = 1; pos <= 6; pos++) ...[
      bigPlayer('home', pos),
      bigPlayer('away', pos),
    ],
  ];
  final bigSlot = PrioritySlot(
    id: 'big',
    date: Day(2026, 9, 20),
    startsAt: const HourMinute(17, 30),
    endsAt: const HourMinute(20, 30),
    type: PrioritySlot.fallbackMatchType,
    homeTeam: home,
    awayTeam: away,
  );

  group('full-screen page: scale-to-fit via pinch-zoom, never scrolled '
      '(Fix round 3)', () {
    // A real phone-ish logical size — this repo's other tests set screen
    // size the same way (see test/features/players_screen_test.dart).
    void setPhoneScreen(WidgetTester tester) {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    Finder scoreTableBodyFinder() => find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_ScoreTableBody',
    );

    testWidgets('a big lineup (6 pairings × 4 lanes) on a phone screen opens '
        'scaled DOWN to fit — no scroll, no overflow — not hardcoded 1.0×', (
      tester,
    ) async {
      setPhoneScreen(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: LegacyScoreSheetPage(
            slot: bigSlot,
            result: result,
            players: bigPlayers,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(SingleChildScrollView), findsNothing);
      expect(find.byType(Scrollable), findsNothing);
      final viewerFinder = find.byType(InteractiveViewer);
      expect(viewerFinder, findsOneWidget);
      expect(find.text('6. Away 6'), findsOneWidget);

      final viewer = tester.widget<InteractiveViewer>(viewerFinder);
      final tableSize = tester.getSize(scoreTableBodyFinder());
      final viewportSize = tester.getSize(viewerFinder);
      final expectedFit = math.min(
        viewportSize.width / tableSize.width,
        viewportSize.height / tableSize.height,
      );

      expect(expectedFit, lessThan(1.0));
      expect(viewer.minScale, closeTo(expectedFit, 0.01));
    });

    testWidgets('pinching in past the initial fit scale actually enlarges the '
        'rendered content, not just changes a number', (tester) async {
      setPhoneScreen(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: LegacyScoreSheetPage(
            slot: bigSlot,
            result: result,
            players: bigPlayers,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final viewer = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      final controller = viewer.transformationController!;
      final probe = find.text('6. Away 6');
      Size onScreenSize() {
        final delta = tester.getBottomRight(probe) - tester.getTopLeft(probe);
        return Size(delta.dx, delta.dy);
      }

      final beforeZoom = onScreenSize();

      final zoomedScale = math.min(viewer.maxScale, viewer.minScale * 2);
      controller.value = Matrix4.diagonal3Values(zoomedScale, zoomedScale, 1.0);
      await tester.pump();

      final afterZoom = onScreenSize();
      expect(afterZoom.width, greaterThan(beforeZoom.width));
      expect(afterZoom.height, greaterThan(beforeZoom.height));
    });

    testWidgets('a small lineup also renders with no scroll view', (
      tester,
    ) async {
      setPhoneScreen(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: LegacyScoreSheetPage(
            slot: slot,
            result: result,
            players: [homePlayer, awayPlayer],
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(SingleChildScrollView), findsNothing);
      expect(find.byType(Scrollable), findsNothing);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.text('1. Jan Novák'), findsOneWidget);
    });
  });
}

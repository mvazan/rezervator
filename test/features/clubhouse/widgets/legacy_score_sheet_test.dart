import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/clubhouse/widgets/legacy_score_sheet.dart';

/// Loads the real Manrope font into the test binding — without this, every
/// `TextStyle(fontFamily: 'Manrope', ...)` measures against the test
/// harness's fallback font instead, which has different metrics and can
/// hide a real overflow/clipping regression (this is exactly what made
/// an earlier round's own width test vacuous).
Future<void> loadManrope() async {
  final loader = FontLoader('Manrope');
  for (final weight in ['Regular', 'Medium', 'Bold', 'ExtraBold']) {
    final bytes = File('assets/fonts/Manrope-$weight.ttf').readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

void main() {
  // Every measurement in this file uses the real font, whatever order the
  // tests run in.
  setUpAll(loadManrope);

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

  // The team summary row's two Družstvo cells (home, then away): the only
  // Družstvo-blue cells exactly one team row (43px) tall.
  List<String?> teamDruzstvo(WidgetTester tester) => [
    for (final cell
        in find
            .byWidgetPredicate(
              (w) =>
                  w is Container &&
                  (w.decoration as BoxDecoration?)?.color ==
                      const Color(0xFFADD8E6) &&
                  w.constraints?.maxHeight == 43.0,
            )
            .evaluate())
      tester
          .widget<Text>(
            find.descendant(
              of: find.byWidget(cell.widget),
              matching: find.byType(Text),
            ),
          )
          .data,
  ];

  testWidgets(
    'team summary row shows both team names, Body (match points), team '
    'stat totals and the Družstvo (pin-total bonus) points',
    (tester) async {
      await tester.pumpWidget(
        app(result: result, players: [homePlayer, awayPlayer]),
      );
      await tester.pumpAndSettle();

      expect(find.text(home), findsOneWidget);
      expect(find.text(away), findsOneWidget);
      expect(find.text('13'), findsOneWidget); // Body (home match points)
      // Body (away match points), and Družstvo too (7 - 0 duel points).
      expect(find.text('7'), findsNWidgets(2));
      expect(find.text('1780'), findsOneWidget); // Plné (home team total)
      expect(find.text('1700'), findsOneWidget); // Plné (away team total)
      expect(find.text('3460'), findsOneWidget); // Celkem (home team total)
      expect(find.text('3349'), findsOneWidget); // Celkem (away team total)
      expect(find.text('15'), findsOneWidget); // Dílčí (home set points)
      expect(find.text('9'), findsOneWidget); // Dílčí (away set points)
      // Družstvo: Body minus the side's duel points — 13 - 1 and 7 - 0.
      expect(teamDruzstvo(tester), ['12', '7']);
      expect(find.text('+111'), findsOneWidget); // team Rozdíl
    },
  );

  testWidgets(
    'team-row Družstvo is the points for the higher pin total (Body minus '
    'the duel points), as kuzelky prints it — not the duel-point sum',
    (tester) async {
      // Shaped like the federation fixture match_finished.html: Body 7 : 1,
      // duels won 5 (home) and 1 (away) → 2 / 0 for the pin total.
      MatchPlayerResult duelist(String side, int position, num teamPoints) =>
          MatchPlayerResult.fromJson({
            'id': '$side-$position',
            'match_id': 'm1',
            'side': side,
            'position': position,
            'player_name': '$side $position',
            'team_points': teamPoints,
          });
      final sixVsSix = [
        for (final (i, points) in [1, 1, 1, 1, 1, 0].indexed)
          duelist('home', i + 1, points),
        for (final (i, points) in [0, 0, 0, 0, 0, 1].indexed)
          duelist('away', i + 1, points),
      ];
      final sevenToOne = MatchResult.fromJson(const {
        'match_id': 'm1',
        'status': 'finished',
        'home_points': 7,
        'away_points': 1,
        'fetched_at': '2026-09-23T10:00:00+00:00',
      });

      await tester.pumpWidget(app(result: sevenToOne, players: sixVsSix));
      await tester.pumpAndSettle();
      expect(teamDruzstvo(tester), ['2', '0']);

      // A duel still undecided on one side: that side's bonus is unknown.
      await tester.pumpWidget(
        app(
          result: sevenToOne,
          players: [
            for (final p in sixVsSix)
              if (p.side == 'away' && p.position == 6)
                MatchPlayerResult.fromJson(const {
                  'id': 'away-6',
                  'match_id': 'm1',
                  'side': 'away',
                  'position': 6,
                  'player_name': 'away 6',
                })
              else
                p,
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(teamDruzstvo(tester), ['2', '–']);
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

      expect(find.text('Jan Novák'), findsOneWidget);
      expect(find.text('Petr Svoboda'), findsOneWidget);

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
      '15', '9', '12', '+111',
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

      expect(find.text('Karel Dvořák'), findsOneWidget);
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
      // Non-zero, so the players' own Družstvo cells don't collide with
      // the Rozdíl cell's own '0' below.
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
    // No duel points to subtract yet — unknown, not a made-up 0.
    expect(teamDruzstvo(tester), ['–', '–']);
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
    'tapping Zvětšit pushes a full-screen page with the same data, no '
    'header of its own and no close button; system back pops it',
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
      expect(find.byType(AppBar), findsNothing);
      expect(find.byIcon(Icons.close), findsNothing);
      expect(find.byTooltip('Zpět'), findsNothing, reason: 'Android: system back');
      expect(find.text('580'), findsWidgets);
      expect(
        find.descendant(of: page, matching: find.byIcon(Icons.open_in_full)),
        findsNothing,
      );
      expect(
        find.descendant(of: page, matching: find.text('Zápis')),
        findsNothing,
      );
      expect(
        find.descendant(of: page, matching: find.byType(SingleChildScrollView)),
        findsNothing,
      );

      // Android's back button / gesture.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byType(LegacyScoreSheetPage), findsNothing);
      expect(find.text('580'), findsOneWidget);
    },
  );

  testWidgets(
    'full screen prints the pairing numbers bigger than the embedded 1:1 '
    'sheet: lane values 15 instead of 10, the player total 20 instead of 16',
    (tester) async {
      double sizeOf(Finder text) =>
          tester.renderObject<RenderParagraph>(text).text.style!.fontSize!;
      await tester.pumpWidget(
        app(result: result, players: [homePlayer, awayPlayer]),
      );
      await tester.pumpAndSettle();
      expect(sizeOf(find.text('175')), 10);
      expect(sizeOf(find.text('580')), 16);

      await tester.tap(find.byIcon(Icons.open_in_full));
      await tester.pumpAndSettle();
      final page = find.byType(LegacyScoreSheetPage);
      expect(sizeOf(find.descendant(of: page, matching: find.text('175'))), 15);
      expect(sizeOf(find.descendant(of: page, matching: find.text('580'))), 20);
      // The team summary row keeps its own sizes.
      expect(sizeOf(find.descendant(of: page, matching: find.text('3460'))), 20);
    },
  );

  testWidgets(
    'on the web (no system back) a small back button shows for 3 s, a tap '
    'on the sheet brings it back, and it closes the page; Android gets none',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => LegacyScoreSheetPage(
                      slot: slot,
                      result: result,
                      players: [homePlayer, awayPlayer],
                      showBackButton: true,
                    ),
                  ),
                ),
                child: const Text('otevřít'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('otevřít'));
      await tester.pumpAndSettle();

      double opacity() => tester
          .widget<AnimatedOpacity>(
            find.ancestor(
              of: find.byTooltip('Zpět'),
              matching: find.byType(AnimatedOpacity),
            ),
          )
          .opacity;
      expect(find.byTooltip('Zpět'), findsOneWidget);
      expect(opacity(), 1);

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(opacity(), 0);

      await tester.tap(find.text('580'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(opacity(), 1);

      await tester.tap(find.byTooltip('Zpět'));
      await tester.pumpAndSettle();
      expect(find.byType(LegacyScoreSheetPage), findsNothing);
      expect(find.text('otevřít'), findsOneWidget);
    },
  );

  testWidgets(
    'full screen hides the system bars while open and brings them back on '
    'the way out',
    (tester) async {
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
        app(result: result, players: [homePlayer, awayPlayer]),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.open_in_full));
      await tester.pumpAndSettle();
      expect(calls.map((c) => '${c.method} ${c.arguments}'), [
        'SystemChrome.setEnabledSystemUIMode SystemUiMode.immersiveSticky',
      ]);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(calls.last.method, 'SystemChrome.setEnabledSystemUIOverlays');
      expect(calls.last.arguments, [
        'SystemUiOverlay.top',
        'SystemUiOverlay.bottom',
      ]);
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

        // Team Družstvo (Body 9001 minus the duel points 9): blue #ADD8E6,
        // 20dp.
        final druzstvoText = find.text('8992');
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

    testWidgets('content narrower than the brief keeps every column at the '
        'reference site\'s own minimum — auto-width only ever grows a '
        'column, never shrinks it below the brief', (tester) async {
      final tiny = PrioritySlot(
        id: 'tiny',
        date: Day(2026, 9, 20),
        startsAt: const HourMinute(17, 30),
        endsAt: const HourMinute(20, 30),
        type: PrioritySlot.fallbackMatchType,
        homeTeam: 'A',
        awayTeam: 'B',
      );
      final tinyResult = MatchResult.fromJson(const {
        'match_id': 'tiny',
        'status': 'finished',
        'home_points': 5,
        'away_points': 3,
        'home_total': 99,
        'away_total': 97,
        'home_fulls': 60,
        'away_fulls': 60,
        'home_spares': 39,
        'away_spares': 37,
        'home_errors': 1,
        'away_errors': 2,
        'home_set_points': 5,
        'away_set_points': 3,
        'fetched_at': '2026-09-23T10:00:00+00:00',
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: LegacyScoreSheet(
                slot: tiny,
                result: tinyResult,
                players: const [],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final tableSize = tester.getSize(
        find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_ScoreTableBody',
        ),
      );
      // Per side: jméno 144, série 46 (its "Celkem" label, 45.4dp in
      // Manrope, outgrows the 42 minimum), plné 55, dor. 46, ch. 33,
      // celkem 58, dílčí 31, družstvo 51; then Rozdíl 46 and the 3dp frame.
      expect(
        tableSize.width,
        2 * (144 + 46 + 55 + 46 + 33 + 58 + 31 + 51) + 46 + 3,
      );
    });
  });

  MatchPlayerResult bigPlayer(
    String side,
    int position, {
    String? name,
    int lanes = 4,
  }) => MatchPlayerResult.fromJson({
    'id': '$side-$position',
    'match_id': 'big',
    'side': side,
    'position': position,
    'player_name': name ?? '${side == 'home' ? 'Home' : 'Away'} $position',
    'fulls': 700,
    'spares': 40,
    'errors': 10,
    'total': 1160,
    'set_points': 4,
    'team_points': side == 'home' ? 1 : 0,
    'lanes': [
      for (var lane = 1; lane <= lanes; lane++)
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

  testWidgets('the embedded sheet keeps kuzelky\'s own natural row heights '
      '(43 team, 2 × 23 header, 23 per lane, 31 Celkem, 9 separator, 3 '
      'frame) — the full-screen fill never leaks into it', (tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Future<Size> embeddedSize(
      PrioritySlot s,
      List<MatchPlayerResult> players,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: LegacyScoreSheet(
                slot: s,
                result: result,
                players: players,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return tester.getSize(
        find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_ScoreTableBody',
        ),
      );
    }

    expect((await embeddedSize(slot, const [])).height, 43 + 3);
    expect(
      (await embeddedSize(slot, [homePlayer, awayPlayer])).height,
      43 + 2 * 23 + (2 * 23 + 31) + 3,
    );
    final big = await embeddedSize(bigSlot, bigPlayers);
    expect(big.height, 43 + 2 * 23 + 6 * (4 * 23 + 31) + 5 * 9 + 3);
    // "SKK Veverky Brno A" in 16/w700 outgrows the 144 name minimum.
    expect(
      big.width,
      greaterThan(2 * (144 + 42 + 55 + 46 + 33 + 58 + 31 + 51)),
    );
  });

  group('full-screen page fills the whole body area, 100% width AND 100% '
      'height, with pinch-zoom on top', () {
    // Realistic two-word Czech names: each wraps once the name column is
    // narrowed to its widest single word.
    const homeNames = [
      'Jaroslav Procházka',
      'Miroslav Dvořák',
      'Zdeněk Kučera',
      'Vlastimil Horák',
      'Bohumil Němec',
      'Stanislav Veselý',
    ];
    const awayNames = [
      'František Marek',
      'Radoslav Pospíšil',
      'Ladislav Hájek',
      'Květoslav Jelínek',
      'Svatopluk Král',
      'Jaromír Růžička',
    ];
    List<MatchPlayerResult> lineup({required int size, required int lanes}) => [
      for (var pos = 1; pos <= size; pos++) ...[
        bigPlayer('home', pos, name: homeNames[pos - 1], lanes: lanes),
        bigPlayer('away', pos, name: awayNames[pos - 1], lanes: lanes),
      ],
    ];
    final fourLanes = lineup(size: 6, lanes: 4);
    final twoLanes = lineup(size: 4, lanes: 2);

    // The body area this page gets: the whole view (no AppBar; the test
    // view has no status bar) minus whatever [padding] the view reports as
    // unsafe.
    const portrait = Size(390, 760);
    const landscape = Size(844, 330);
    const desktop = Size(1400, 900);

    void setBodyArea(
      WidgetTester tester,
      Size body, {
      FakeViewPadding padding = FakeViewPadding.zero,
    }) {
      tester.view.devicePixelRatio = 1.0;
      tester.view.padding = padding;
      tester.view.physicalSize = Size(
        body.width + padding.left + padding.right,
        body.height + padding.top + padding.bottom,
      );
      addTearDown(tester.view.reset);
    }

    Future<void> openPage(
      WidgetTester tester,
      List<MatchPlayerResult> players, {
      PrioritySlot? matchSlot,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: LegacyScoreSheetPage(
            slot: matchSlot ?? bigSlot,
            result: result,
            players: players,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    Finder scoreTableBodyFinder() => find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_ScoreTableBody',
    );

    // The whole view inside its safe insets — computed from the view
    // itself, never from this page's own widgets.
    Rect expectedBodyArea(WidgetTester tester) {
      final view = tester.view;
      final screen = view.physicalSize / view.devicePixelRatio;
      final pad = view.padding;
      final dpr = view.devicePixelRatio;
      return Rect.fromLTRB(
        pad.left / dpr,
        pad.top / dpr,
        screen.width - pad.right / dpr,
        screen.height - pad.bottom / dpr,
      );
    }

    void expectFillsBodyArea(WidgetTester tester) {
      final area = expectedBodyArea(tester);
      final table = tester.getRect(scoreTableBodyFinder());
      expect(table.left, closeTo(area.left, 1), reason: 'left edge');
      expect(table.top, closeTo(area.top, 1), reason: 'top edge');
      expect(table.right, closeTo(area.right, 1), reason: 'right edge');
      expect(table.bottom, closeTo(area.bottom, 1), reason: 'bottom edge');
    }

    void expectNothingTruncated(WidgetTester tester) {
      final paragraphs = find
          .descendant(
            of: scoreTableBodyFinder(),
            matching: find.byType(RichText),
          )
          .evaluate();
      expect(paragraphs, isNotEmpty);
      for (final element in paragraphs) {
        final rp = element.renderObject! as RenderParagraph;
        expect(
          rp.didExceedMaxLines,
          isFalse,
          reason: '"${rp.text.toPlainText()}" got cut off',
        );
      }
    }

    // A 16px/height-1.0 name's line count, read off its laid-out height.
    int linesOf(WidgetTester tester, String name) =>
        (tester.renderObject<RenderParagraph>(find.text(name)).size.height / 16)
            .round();

    for (final (label, players) in [
      ('6 players × 4 lanes', fourLanes),
      ('4 players × 2 lanes', twoLanes),
    ]) {
      for (final (areaLabel, area) in [
        ('portrait phone', portrait),
        ('landscape phone', landscape),
        ('desktop', desktop),
      ]) {
        testWidgets('$label on a $areaLabel ($area) fills the body area '
            'within 1px on all 4 sides, nothing truncated', (tester) async {
          setBodyArea(tester, area);
          await openPage(tester, players);

          expectFillsBodyArea(tester);
          expectNothingTruncated(tester);
        });
      }
    }

    testWidgets('on a portrait phone the player names wrap onto more than '
        'one line (the narrow, wrapping name column wins)', (tester) async {
      setBodyArea(tester, portrait);
      await openPage(tester, fourLanes);

      expectFillsBodyArea(tester);
      expectNothingTruncated(tester);
      for (final name in [...homeNames, ...awayNames]) {
        expect(linesOf(tester, name), greaterThan(1), reason: name);
      }
    });

    testWidgets('a hyphenated surname narrows the name column only to its '
        'widest part, since the line breaker also breaks after "-": the '
        'other names on a portrait phone still wrap', (tester) async {
      // "Nováková-Dvořáková" is one whitespace-free run, far wider than any
      // other word here, but it renders as "Nováková-" / "Dvořáková".
      const hyphenated = 'Eva Nováková-Dvořáková';
      final players = [
        for (final p in fourLanes)
          p.side == 'away' && p.position == 6
              ? bigPlayer('away', 6, name: hyphenated)
              : p,
      ];
      setBodyArea(tester, portrait);
      await openPage(tester, players);

      expectFillsBodyArea(tester);
      expectNothingTruncated(tester);
      expect(linesOf(tester, hyphenated), greaterThan(1));
      for (final name in [...homeNames, ...awayNames.take(5)]) {
        expect(linesOf(tester, name), greaterThan(1), reason: name);
      }
    });

    testWidgets('on a landscape phone the names stay on one line', (
      tester,
    ) async {
      setBodyArea(tester, landscape);
      await openPage(tester, fourLanes);

      for (final name in [...homeNames, ...awayNames]) {
        expect(linesOf(tester, name), 1, reason: name);
      }
    });

    testWidgets('a small lineup (one pairing, one side without lanes) also '
        'fills a portrait phone, with no scroll view', (tester) async {
      setBodyArea(tester, portrait);
      await openPage(tester, [homePlayer, awayPlayer], matchSlot: slot);

      expect(find.byType(SingleChildScrollView), findsNothing);
      expect(find.byType(Scrollable), findsNothing);
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.text('Jan Novák'), findsOneWidget);
      expectFillsBodyArea(tester);
      expectNothingTruncated(tester);
    });

    testWidgets('a notched landscape phone: the table fills the SAFE area, '
        'not the area under the notch or the home indicator', (tester) async {
      setBodyArea(
        tester,
        landscape,
        padding: const FakeViewPadding(left: 47, right: 47, bottom: 21),
      );
      await openPage(tester, fourLanes);

      expect(expectedBodyArea(tester).left, 47);
      expectFillsBodyArea(tester);
      expectNothingTruncated(tester);
    });

    testWidgets('rotating from portrait to landscape re-fits: the new area is '
        'filled and a pinch made before is reset', (tester) async {
      setBodyArea(tester, portrait);
      await openPage(tester, fourLanes);
      expectFillsBodyArea(tester);

      final controller = tester
          .widget<InteractiveViewer>(find.byType(InteractiveViewer))
          .transformationController!;
      controller.value = Matrix4.diagonal3Values(2.5, 2.5, 1.0);
      await tester.pump();

      setBodyArea(tester, landscape);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(controller.value, Matrix4.identity());
      expectFillsBodyArea(tester);
      expectNothingTruncated(tester);

      // …and back again.
      setBodyArea(tester, portrait);
      await tester.pumpAndSettle();
      expectFillsBodyArea(tester);
      expectNothingTruncated(tester);
    });

    testWidgets('pinch-zoom: opens at 1.0 (the fit), zooms in up to 4×, and '
        'zooming in actually enlarges the rendered content', (tester) async {
      setBodyArea(tester, portrait);
      await openPage(tester, fourLanes);

      final viewer = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      expect(viewer.minScale, 1.0);
      expect(viewer.maxScale, 4.0);
      final controller = viewer.transformationController!;
      expect(controller.value, Matrix4.identity());

      final probe = find.text(awayNames.last);
      final beforeZoom = tester.getRect(probe);
      controller.value = Matrix4.diagonal3Values(2.0, 2.0, 1.0);
      await tester.pump();
      final afterZoom = tester.getRect(probe);

      expect(afterZoom.width, closeTo(beforeZoom.width * 2, 0.5));
      expect(afterZoom.height, closeTo(beforeZoom.height * 2, 0.5));
    });
  });

  group('Fix round 5: 1px collapsed grid, auto-width columns', () {
    testWidgets(
      'the grid is a 2px outer frame with 1px collapsed internal seams — '
      'not the other way around',
      (tester) async {
        // Wide enough that the embedded card's own horizontal scroll
        // viewport shows the WHOLE table at once — otherwise
        // `RepaintBoundary.toImage()` only captures the visible viewport
        // slice, silently cutting off the right edge this test needs to
        // see.
        tester.view.physicalSize = const Size(1200, 300);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: RepaintBoundary(
                  key: boundaryKey,
                  child: LegacyScoreSheet(
                    slot: slot,
                    result: result,
                    players: [homePlayer, awayPlayer],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final boundary =
            boundaryKey.currentContext!.findRenderObject()
                as RenderRepaintBoundary;
        // `toImage`/`toByteData` schedule real engine work that never
        // completes inside `testWidgets`' fake-async zone — `runAsync`
        // steps outside it so the awaited Futures actually resolve,
        // instead of hanging forever.
        late Uint8List bytes;
        late int imgWidth;
        late int imgHeight;
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1.0);
          final byteData = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          bytes = byteData!.buffer.asUint8List();
          imgWidth = image.width;
          imgHeight = image.height;
        });

        bool isDark(int x, int y) {
          if (x < 0 || y < 0 || x >= imgWidth || y >= imgHeight) return false;
          final i = (y * imgWidth + x) * 4;
          final a = bytes[i + 3];
          if (a < 200) return false;
          return bytes[i] < 80 && bytes[i + 1] < 80 && bytes[i + 2] < 80;
        }

        // Every dark (border-coloured) run along a scan line, as a list of
        // run lengths — independent of exact column/row positions, so this
        // doesn't need to know the table's own widths.
        List<int> darkRuns({
          required int fixedAxis,
          required int scanStart,
          required int scanEnd,
          required bool horizontal,
        }) {
          final runs = <int>[];
          var pos = scanStart;
          while (pos < scanEnd) {
            final dark = horizontal
                ? isDark(pos, fixedAxis)
                : isDark(fixedAxis, pos);
            if (dark) {
              var len = 0;
              while (pos < scanEnd &&
                  (horizontal
                      ? isDark(pos, fixedAxis)
                      : isDark(fixedAxis, pos))) {
                len++;
                pos++;
              }
              runs.add(len);
            } else {
              pos++;
            }
          }
          return runs;
        }

        final tableTopLeft = tester.getTopLeft(
          find.byWidgetPredicate(
            (w) => w.runtimeType.toString() == '_ScoreTableBody',
          ),
        );
        final tableSize = tester.getSize(
          find.byWidgetPredicate(
            (w) => w.runtimeType.toString() == '_ScoreTableBody',
          ),
        );
        final boundaryTopLeft = tester.getTopLeft(find.byKey(boundaryKey));
        final originX = (tableTopLeft.dx - boundaryTopLeft.dx).round();
        final originY = (tableTopLeft.dy - boundaryTopLeft.dy).round();
        final tableRight = originX + tableSize.width.round();
        final tableBottom = originY + tableSize.height.round();
        // A couple of px of slack beyond the logical bounds — layout size
        // vs. actual painted pixels can be off by a hair from float
        // accumulation, and `isDark` already returns false outside the
        // image, so widening the scan never introduces a spurious run.
        const scanSlack = 2;

        // Horizontal scan 2px into the team row (43px tall) — safely inside
        // every cell's own 4px padding, so it never crosses glyph ink, only
        // the vertical seams between columns.
        final horizontalRuns = darkRuns(
          fixedAxis: originY + 2,
          scanStart: originX - scanSlack,
          scanEnd: tableRight + scanSlack,
          horizontal: true,
        );
        expect(
          horizontalRuns.length,
          greaterThan(2),
          reason: 'expected several column seams in the team row',
        );
        expect(horizontalRuns.first, 2, reason: 'left outer frame');
        expect(horizontalRuns.last, 2, reason: 'right outer frame');
        for (final run in horizontalRuns.sublist(
          1,
          horizontalRuns.length - 1,
        )) {
          expect(run, 1, reason: 'internal column seam should collapse to 1px');
        }

        // Vertical scan 2px into the name column — inside its own left
        // padding, so it only ever crosses the horizontal row seams.
        final verticalRuns = darkRuns(
          fixedAxis: originX + 2,
          scanStart: originY - scanSlack,
          scanEnd: tableBottom + scanSlack,
          horizontal: false,
        );
        expect(
          verticalRuns.length,
          greaterThan(2),
          reason: 'expected several row seams down the name column',
        );
        expect(verticalRuns.first, 2, reason: 'top outer frame');
        expect(verticalRuns.last, 2, reason: 'bottom outer frame');
        for (final run in verticalRuns.sublist(1, verticalRuns.length - 1)) {
          expect(run, 1, reason: 'internal row seam should collapse to 1px');
        }
      },
    );

    for (final boldText in [false, true]) {
      testWidgets(
        'with realistic full-width data (4 lanes, totals ≈3460, "15,5", '
        '"+211", Ch. "40"), no cell text is clipped or exceeds its line limit'
        '${boldText ? ' — even with the platform Bold text setting on' : ''}',
        (tester) async {
          if (boldText) {
            tester.platformDispatcher.accessibilityFeaturesTestValue =
                const FakeAccessibilityFeatures(boldText: true);
            addTearDown(
              tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
            );
          }

          final realisticResult = MatchResult.fromJson(const {
            'match_id': 'r1',
            'status': 'finished',
            'home_points': 6,
            'away_points': 2,
            'home_total': 3460,
            'away_total': 3249, // team Rozdíl = +211
            'home_fulls': 2280,
            'away_fulls': 2100,
            'home_spares': 1180,
            'away_spares': 1049,
            'home_errors': 40,
            'away_errors': 38,
            'home_set_points': 15.5,
            'away_set_points': 8.5,
            'fetched_at': '2026-09-23T10:00:00+00:00',
          });
          MatchPlayerResult fourLanePlayer(String side, String name) =>
              MatchPlayerResult.fromJson({
                'id': '$side-r1',
                'match_id': 'r1',
                'side': side,
                'position': 1,
                'player_name': name,
                'fulls': 570,
                'spares': 295,
                'errors': 10,
                'total': 865,
                'set_points': 4,
                'team_points': side == 'home' ? 1 : 0,
                'lanes': [
                  for (var lane = 1; lane <= 4; lane++)
                    {
                      'lane': lane,
                      'fulls': 142,
                      'spares': 74,
                      'errors': 3,
                      'total': 217,
                      'setPoints': 1,
                    },
                ],
              });
          final realisticHome = fourLanePlayer('home', 'Realistický Domácí');
          final realisticAway = fourLanePlayer('away', 'Realistický Host');

          await tester.pumpWidget(
            app(
              result: realisticResult,
              players: [realisticHome, realisticAway],
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          // The exact strings the bug report named as broken.
          expect(find.text('2280'), findsOneWidget); // was "22…"
          expect(find.text('1180'), findsOneWidget); // was "11…"
          expect(find.text('3460'), findsOneWidget); // was "34…"
          expect(find.text('15,5'), findsOneWidget); // was "1…"
          expect(find.text('+211'), findsOneWidget); // was "+…"
          expect(find.text('40'), findsOneWidget); // was blank

          final tableFinder = find.byWidgetPredicate(
            (w) => w.runtimeType.toString() == '_ScoreTableBody',
          );
          for (final element
              in find
                  .descendant(of: tableFinder, matching: find.byType(RichText))
                  .evaluate()) {
            final rp = element.renderObject! as RenderParagraph;
            final text = rp.text.toPlainText();
            expect(
              rp.didExceedMaxLines,
              isFalse,
              reason: '"$text" wrapped past its line limit and got clipped',
            );
            // "Série hodů" is the one header deliberately allowed to wrap
            // onto its own 2-row-tall cell (Fix round 5, item 3) — its
            // single-line natural width is expected to exceed its (narrow,
            // content-driven) column, that's the whole point of letting it
            // wrap instead of forcing the column wide enough for one line.
            if (text == 'Série hodů') continue;
            final natural = rp.getMaxIntrinsicWidth(double.infinity);
            expect(
              natural,
              lessThanOrEqualTo(rp.size.width + 0.5),
              reason:
                  '"$text" needs $natural but its box is only '
                  '${rp.size.width}',
            );
          }
        },
      );
    }

    testWidgets(
      'uneven lane counts pad the shorter side with filler cells instead '
      'of leaving a gap, and both sides report the same block height',
      (tester) async {
        final fourLaneHome = MatchPlayerResult.fromJson(const {
          'id': 'fh',
          'match_id': 'm3',
          'side': 'home',
          'position': 1,
          'player_name': 'Čtyři Dráhy',
          'total': 900,
          'lanes': [
            {'lane': 1, 'total': 225},
            {'lane': 2, 'total': 225},
            {'lane': 3, 'total': 225},
            {'lane': 4, 'total': 225},
          ],
        });
        final twoLaneAway = MatchPlayerResult.fromJson(const {
          'id': 'tl',
          'match_id': 'm3',
          'side': 'away',
          'position': 1,
          'player_name': 'Dvě Dráhy',
          'total': 460,
          'lanes': [
            {'lane': 1, 'total': 230},
            {'lane': 2, 'total': 230},
          ],
        });
        await tester.pumpWidget(app(players: [fourLaneHome, twoLaneAway]));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        // 4 real lane numbers (home) + 2 real lane numbers (away) + 2
        // filler rows padding the away side up to 4 — filler cells render
        // blank, not a stray extra "1"/"2".
        expect(find.text('3'), findsOneWidget);
        expect(find.text('4'), findsOneWidget);

        // Družstvo (spans the whole block) reports the SAME height on
        // both sides — proof the shorter side was padded up, not left
        // short.
        final druzstvoCells = tester
            .widgetList<Container>(
              find.byWidgetPredicate(
                (w) =>
                    w is Container &&
                    (w.decoration as BoxDecoration?)?.color ==
                        const Color(0xFFADD8E6),
              ),
            )
            .toList();
        final allHeights = {
          for (final c in druzstvoCells)
            if (c.constraints?.maxHeight != null) c.constraints!.maxHeight,
        };
        // Exclude the team summary row's own Družstvo cells (43px, fixed
        // per the brief) — only the two PAIRING-level cells (one per side)
        // are what this test is about.
        final pairingHeights = allHeights.where((h) => h != 43.0).toSet();
        expect(
          pairingHeights.length,
          1,
          reason:
              'both Družstvo cells should share one height, got $allHeights',
        );
      },
    );

    testWidgets(
      'a player with zero lanes gets a single-line name that fits the '
      '31px Celkem row without wrapping',
      (tester) async {
        final noLaneHome = MatchPlayerResult.fromJson(const {
          'id': 'nl',
          'match_id': 'm4',
          'side': 'home',
          'position': 1,
          'player_name': 'Živě Bez Drah',
          'total': 500,
        });
        await tester.pumpWidget(app(players: [noLaneHome]));
        await tester.pumpAndSettle();

        final nameFinder = find.text('Živě Bez Drah');
        expect(nameFinder, findsOneWidget);
        expect(tester.widget<Text>(nameFinder).maxLines, 1);
        final rp = tester.renderObject<RenderParagraph>(nameFinder);
        expect(rp.didExceedMaxLines, isFalse);
      },
    );

    testWidgets(
      'a player with a single lane also gets the name in the 31px Celkem '
      'row — a 23px lane row cannot hold the 16px name unclipped',
      (tester) async {
        final oneLaneHome = MatchPlayerResult.fromJson(const {
          'id': 'ol',
          'match_id': 'm4',
          'side': 'home',
          'position': 1,
          'player_name': 'Jedna Dráha',
          'total': 250,
          'lanes': [
            {'lane': 1, 'total': 250},
          ],
        });
        await tester.pumpWidget(app(players: [oneLaneHome]));
        await tester.pumpAndSettle();

        final nameFinder = find.text('Jedna Dráha');
        expect(nameFinder, findsOneWidget);
        final rp = tester.renderObject<RenderParagraph>(nameFinder);
        expect(rp.didExceedMaxLines, isFalse);
        expect(rp.size.height, greaterThanOrEqualTo(16));
      },
    );
  });
}

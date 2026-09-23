import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/theme.dart';
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
  // row, not by re-summing `player.lanes` (Fix round 1: the original
  // fixture's lanes happened to sum exactly to the totals, so a re-summing
  // implementation would have passed the old test too).
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
    'team summary row shows both team names, Body, team totals and Sady',
    (tester) async {
      await tester.pumpWidget(
        app(result: result, players: [homePlayer, awayPlayer]),
      );
      await tester.pumpAndSettle();

      expect(find.text(home), findsOneWidget);
      expect(find.text(away), findsOneWidget);
      expect(find.text('13'), findsOneWidget); // Body (home)
      expect(find.text('7'), findsOneWidget); // Body (away)
      expect(find.text('1780'), findsOneWidget); // Plné (home team total)
      expect(find.text('1700'), findsOneWidget); // Plné (away team total)
      expect(find.text('3460'), findsOneWidget); // Celkem (home team total)
      expect(find.text('3349'), findsOneWidget); // Celkem (away team total)
      expect(find.text('15'), findsOneWidget); // Sady (home)
      expect(find.text('9'), findsOneWidget); // Sady (away)
    },
  );

  testWidgets('the team summary row has its own column labels', (tester) async {
    await tester.pumpWidget(
      app(result: result, players: [homePlayer, awayPlayer]),
    );
    await tester.pumpAndSettle();

    expect(find.text('Družstvo'), findsNWidgets(2));
    expect(find.text('Body'), findsNWidgets(2));
    // 2 team-summary Sady labels; the player section reuses 'Plné'/'Dor.'/
    // 'Ch.'/'Celkem' too, so those alone aren't distinctive here.
    expect(find.text('Sady'), findsNWidgets(2));
  });

  testWidgets(
    'a pairing block shows both players, lane and Celkem lines (from the '
    "player's own totals, not the lane sum), the bod badge only for the "
    'player with team points, and a signed Rozdíl',
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
      // 2 team-summary labels + 2 column-header labels + 2 per-player
      // Celkem rows.
      expect(find.text('Celkem'), findsNWidgets(6));

      // Only the home player has team_points > 0.
      expect(find.text('bod'), findsOneWidget);

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

  testWidgets('Rozdíl is negative and tinted when the away side scored more', (
    tester,
  ) async {
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
    expect(
      diffText.style?.color,
      Theme.of(tester.element(find.text('-20'))).colorScheme.error,
    );
  });

  testWidgets('Rozdíl on a tie renders 0, neutral (not tinted as a win)', (
    tester,
  ) async {
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
      'total': 500,
    });
    await tester.pumpWidget(app(players: [home2, away2]));
    await tester.pumpAndSettle();

    final diffText = tester.widget<Text>(find.text('0'));
    final scheme = Theme.of(tester.element(find.text('0'))).colorScheme;
    expect(diffText.style?.color, scheme.onSurface);
    expect(diffText.style?.color, isNot(scheme.tertiary));
    expect(diffText.style?.color, isNot(scheme.error));
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
    // No lineup: no player section.
    expect(find.text('Jméno a příjmení hráče'), findsNothing);
  });

  testWidgets('no result and no players renders nothing', (tester) async {
    await tester.pumpWidget(app(result: null, players: const []));
    await tester.pumpAndSettle();

    expect(find.text('Zápis'), findsNothing);
    expect(find.text(home), findsNothing);
    expect(find.text('Jméno a příjmení hráče'), findsNothing);
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
      // The pushed page has no zvětšit control of its own — showHeader is
      // suppressed there (Fix round 1: it used to stack another identical
      // page on tap).
      expect(
        find.descendant(of: page, matching: find.byIcon(Icons.open_in_full)),
        findsNothing,
      );
      // 'Zápis' appears exactly once inside the page — from its own AppBar
      // title, not also from an embedded header row.
      expect(
        find.descendant(of: page, matching: find.text('Zápis')),
        findsOneWidget,
      );
      // Fix round 2: the full-screen page is never scrolled, in either
      // axis — it scales the table to fit instead (see the FittedBox
      // group below).
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

  testWidgets('the Zvětšit button is hidden when there is no lineup yet', (
    tester,
  ) async {
    await tester.pumpWidget(app(result: result, players: const []));
    await tester.pumpAndSettle();

    expect(find.text('Zápis'), findsOneWidget);
    expect(find.byIcon(Icons.open_in_full), findsNothing);
  });

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

  group('full-screen page: scale-to-fit, never scrolled (Fix round 2)', () {
    testWidgets(
      'a big lineup (6 pairings × 4 lanes) is scaled to fit, not scrolled '
      'or clipped',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: LegacyScoreSheetPage(
              slot: bigSlot,
              result: result,
              players: bigPlayers,
            ),
          ),
        );
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(find.byType(SingleChildScrollView), findsNothing);
        expect(find.byType(FittedBox), findsOneWidget);
        // FittedBox lays its child out unconstrained then scales the
        // result — the last pairing is fully built, just shrunk to fit.
        expect(find.text('6. Away 6'), findsOneWidget);
      },
    );

    testWidgets('a small lineup also renders with no scroll view', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: LegacyScoreSheetPage(
            slot: slot,
            result: result,
            players: [homePlayer, awayPlayer],
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byType(SingleChildScrollView), findsNothing);
      expect(find.byType(FittedBox), findsOneWidget);
      expect(find.text('1. Jan Novák'), findsOneWidget);
    });
  });

  group('column widths against the real font (Fix round 2)', () {
    // The table is sized for its OWN real content (Manrope, via
    // buildTheme) at 1.0× — see `_ScoreTableBody`'s width constants. The
    // test harness's fallback font has different metrics than Manrope, so
    // without loading the real font this test would measure the wrong
    // typeface and could pass even for widths too narrow for the real app
    // (this is exactly what made fix round 1's own width test vacuous).
    setUpAll(() async {
      final loader = FontLoader('Manrope');
      for (final weight in ['Regular', 'Medium', 'Bold', 'ExtraBold']) {
        final bytes = File(
          'assets/fonts/Manrope-$weight.ttf',
        ).readAsBytesSync();
        loader.addFont(Future.value(ByteData.view(bytes.buffer)));
      }
      await loader.load();
    });

    // The longest team name actually seen among this club's real synced
    // opponents (see my_trainings_screen_test.dart/results_screen_test.dart
    // fixtures) — the tightest real-world fit for the name column.
    final longNameSlot = PrioritySlot(
      id: 'm1',
      date: Day(2026, 9, 20),
      startsAt: const HourMinute(17, 30),
      endsAt: const HourMinute(20, 30),
      type: PrioritySlot.fallbackMatchType,
      homeTeam: 'TJ Slovan Karlovy Vary',
      awayTeam: away,
    );

    Widget realApp() => MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: SingleChildScrollView(
          child: LegacyScoreSheet(
            slot: longNameSlot,
            result: result,
            players: [homePlayer, awayPlayer],
          ),
        ),
      ),
    );

    testWidgets(
      'every cell (name, numeric headers and data, the label column, '
      'Rozdíl) fits its own actual laid-out width — no clipping or overflow',
      (tester) async {
        await tester.pumpWidget(realApp());
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        void expectFits(Finder finder) {
          final count = tester.widgetList<Text>(finder).length;
          expect(count, greaterThan(0));
          for (var i = 0; i < count; i++) {
            final instance = finder.at(i);
            final rp = tester.renderObject<RenderParagraph>(instance);
            final natural = rp.getMaxIntrinsicWidth(double.infinity);
            expect(
              natural,
              lessThanOrEqualTo(rp.size.width + 0.5),
              reason:
                  '"${tester.widget<Text>(instance).data}" needs '
                  '$natural but its laid-out box is only ${rp.size.width}',
            );
          }
        }

        // Name column: the tightest real team name, plus the two header
        // labels sharing that column.
        expectFits(find.text('TJ Slovan Karlovy Vary'));
        expectFits(find.text('Jméno a příjmení hráče'));
        expectFits(find.text('Družstvo'));
        // Label column: "Série" (header), lane numbers and the bold
        // "Celkem" row-label — plus the "Celkem" HEADER label, which lives
        // in a (narrower) numeric column instead.
        expectFits(find.text('Série'));
        expectFits(find.text('Celkem'));
        // Numeric data: the widest real values in this fixture.
        expectFits(find.text('1780'));
        expectFits(find.text('3460'));
        expectFits(find.text('350'));
        // Rozdíl: header and a signed value.
        expectFits(find.text('Rozdíl'));
        expectFits(find.text('+30'));
      },
    );
  });
}

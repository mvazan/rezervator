import 'package:flutter/material.dart';
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

  final homePlayer = MatchPlayerResult.fromJson(const {
    'id': 'p1',
    'match_id': 'm1',
    'side': 'home',
    'position': 1,
    'player_name': 'Jan Novák',
    'fulls': 350,
    'spares': 20,
    'errors': 5,
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
        'fulls': 175,
        'spares': 10,
        'errors': 3,
        'total': 290,
        'setPoints': 1,
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

  testWidgets(
    'a pairing block shows both players, lane and Celkem lines, the bod '
    'badge only for the player with team points, and a signed Rozdíl',
    (tester) async {
      await tester.pumpWidget(
        app(result: result, players: [homePlayer, awayPlayer]),
      );
      await tester.pumpAndSettle();

      expect(find.text('1. Jan Novák'), findsOneWidget);
      expect(find.text('1. Petr Svoboda'), findsOneWidget);

      // Lane lines (home player only): fulls/spares/errors/total/setPoints.
      expect(find.text('175'), findsNWidgets(2));
      expect(find.text('290'), findsNWidgets(2));

      // Celkem line per player (summed values, taken straight from the
      // player's own totals, not re-summed from lanes).
      expect(find.text('350'), findsOneWidget);
      expect(find.text('580'), findsOneWidget);
      expect(find.text('340'), findsOneWidget);
      expect(find.text('550'), findsOneWidget);
      // 2 column-header labels (one per side) + 2 per-player Celkem rows.
      expect(find.text('Celkem'), findsNWidgets(4));

      // Only the home player has team_points > 0.
      expect(find.text('bod'), findsOneWidget);

      // Rozdíl: home 580 - away 550 = +30.
      expect(find.text('+30'), findsOneWidget);
    },
  );

  testWidgets('no registration-number text is shown anywhere', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(result: result, players: [homePlayer, awayPlayer]),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('egistra'), findsNothing);
  });

  testWidgets('empty players renders nothing', (tester) async {
    await tester.pumpWidget(app(result: result, players: const []));
    await tester.pumpAndSettle();

    expect(find.text('Zápis'), findsNothing);
    expect(find.text('Jméno a příjmení hráče'), findsNothing);
  });

  testWidgets(
    'tapping Zvětšit pushes a full-screen page with the same data; close '
    'pops it back',
    (tester) async {
      await tester.pumpWidget(
        app(result: result, players: [homePlayer, awayPlayer]),
      );
      await tester.pumpAndSettle();

      expect(find.text('580'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.open_in_full));
      await tester.pumpAndSettle();

      expect(find.byType(LegacyScoreSheetPage), findsOneWidget);
      expect(find.widgetWithText(AppBar, 'Zápis'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
      expect(find.text('580'), findsWidgets);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(find.byType(LegacyScoreSheetPage), findsNothing);
      expect(find.text('580'), findsOneWidget);
    },
  );
}

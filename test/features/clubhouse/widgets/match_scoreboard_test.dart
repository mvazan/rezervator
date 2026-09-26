import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/theme.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/palette.dart';
import 'package:rezervator/features/clubhouse/widgets/match_scoreboard.dart';

import '../../../support/rudna_vrsovice.dart';

/// Loads the real Manrope into the test binding (as the Zápis sheet's test
/// does): with the harness's fallback font a name's line breaks — and so
/// whether it fits 2 lines — would not be the app's.
Future<void> _loadManrope() async {
  final loader = FontLoader(appFontFamily);
  for (final weight in ['Regular', 'Medium', 'Bold', 'ExtraBold']) {
    final bytes = File('assets/fonts/Manrope-$weight.ttf').readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

/// The morning after the Rudná match (Thursday 17. 9. 2026, 10:00).
final _now = DateTime(2026, 9, 17, 10);

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

/// One `match_player_results` row with only what the scoreboard reads.
MatchPlayerResult _player(
  String side,
  int pos,
  List<Map<String, Object?>> lanes, {
  int? total,
  num? sb,
  num? tb,
}) => MatchPlayerResult.fromJson({
  'id': '$side$pos',
  'match_id': 'x',
  'side': side,
  'position': pos,
  'player_name': '$side $pos',
  'total': total,
  'set_points': sb,
  'team_points': tb,
  'lanes': lanes,
});

/// One lane of the `lanes` jsonb; a null [total] is a lane not thrown yet.
Map<String, Object?> _lane(int n, int? total, [num? sp]) => {
  'lane': n,
  'fulls': null,
  'spares': null,
  'errors': null,
  'total': total,
  'setPoints': sp,
};

/// A `match_results` row for [rudnaSlot]'s teams with [status] and only the
/// given team values.
MatchResult _result(
  String status, {
  num? homePoints,
  num? awayPoints,
  int? homeTotal,
  int? awayTotal,
  DateTime? fetchedAt,
}) => MatchResult.fromJson({
  'match_id': 'x',
  'status': status,
  'match_type': 'TEAMS_OF_6',
  'discipline': 'T100',
  'home_points': homePoints,
  'away_points': awayPoints,
  'home_total': homeTotal,
  'away_total': awayTotal,
  'fetched_at': (fetchedAt ?? DateTime.utc(2026, 9, 17, 8))
      .toUtc()
      .toIso8601String(),
});

/// Live, today at 9:00 (an hour before [_now]): duel 1 done, duel 2 on its
/// second lane, duels 3–6 waiting.
final _liveSlot = PrioritySlot(
  id: 'lv',
  date: Day(2026, 9, 17),
  startsAt: const HourMinute(9, 0),
  endsAt: const HourMinute(12, 0),
  type: PrioritySlot.fallbackMatchType,
  homeTeam: 'TJ Sokol Rudná A',
  awayTeam: 'TJ Sokol Vršovice A',
  venue: 'TJ Sokol Rudná',
);

/// The lineups of [_liveSlot]'s match, as described there.
final _livePlayers = [
  _player(
    'home',
    1,
    [_lane(1, 213, 0), _lane(2, 194, 1)],
    total: 407,
    sb: 1,
    tb: 1,
  ),
  _player(
    'away',
    1,
    [_lane(1, 216, 1), _lane(2, 169, 0)],
    total: 385,
    sb: 1,
    tb: 0,
  ),
  _player('home', 2, [_lane(1, 209), _lane(2, null)], total: 209),
  _player('away', 2, [_lane(1, 194), _lane(2, null)], total: 194),
  for (var pos = 3; pos <= 6; pos++) ...[
    _player('home', pos, [_lane(1, null), _lane(2, null)]),
    _player('away', pos, [_lane(1, null), _lane(2, null)]),
  ],
];

/// The running score of [_liveSlot]'s match, fetched 2 min before [_now].
final _liveResult = _result(
  'in_progress',
  homePoints: 1,
  awayPoints: 0,
  homeTotal: 616,
  awayTotal: 579,
  fetchedAt: _now.subtract(const Duration(minutes: 2)),
);

Text _text(WidgetTester tester, String data) =>
    tester.widget<Text>(find.text(data));

Rect _rect(WidgetTester tester, String key) =>
    tester.getRect(find.byKey(Key(key)));

void main() {
  group('the finished Rudná A 7 : 1 Vršovice A', () {
    Future<void> pump(WidgetTester tester, {VoidCallback? onVenueTap}) =>
        tester.pumpWidget(
          _host(
            MatchScoreboard(
              slot: rudnaSlot,
              result: rudnaResult,
              players: rudnaPlayers,
              now: _now,
              onVenueTap: onVenueTap,
            ),
          ),
        );

    testWidgets('the date, the status, the score and the pins', (tester) async {
      await pump(tester);
      expect(find.text('středa 16. 9. · 17:30'), findsOneWidget);
      expect(find.text('Dokončeno'), findsOneWidget);
      expect(find.text('7'), findsOneWidget);
      // The away score and the first tile.
      expect(find.text('1'), findsNWidgets(2));
      expect(find.text('2555'), findsOneWidget);
      expect(find.text('2321'), findsOneWidget);
      expect(find.text('← 234'), findsOneWidget);
      expect(find.text('průběžně'), findsNothing);
    });

    testWidgets('the explanation line adds up the score', (tester) async {
      await pump(tester);
      expect(
        find.text('Souboje 5 : 1 · Kuželky 2 : 0 · SB 8,5 : 3,5'),
        findsOneWidget,
      );
    });

    testWidgets('one tile per duel, then +2 kuž. for the pins', (tester) async {
      await pump(tester);
      for (var pos = 1; pos <= 6; pos++) {
        expect(find.byKey(Key('scoreboard-tile-$pos')), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(Key('scoreboard-tile-$pos')),
            matching: find.text('$pos'),
          ),
          findsOneWidget,
        );
      }
      expect(find.byKey(const Key('scoreboard-tile-7')), findsNothing);
      expect(find.text('+2 kuž.'), findsOneWidget);
      expect(find.text('+1 kuž.'), findsNothing);
    });

    testWidgets('each point bar sits on the side that won the duel', (
      tester,
    ) async {
      await pump(tester);
      // Duels 1–5 went home: the bar hugs the tile's left edge.
      for (var pos = 1; pos <= 5; pos++) {
        final bar = _rect(tester, 'scoreboard-bar-$pos');
        final tile = _rect(tester, 'scoreboard-tile-$pos');
        expect(bar.left, tile.left, reason: 'duel $pos');
        expect(bar.width, closeTo(tile.width / 2, 0.01), reason: 'duel $pos');
      }
      // Duel 6 went away: the bar hugs the right edge.
      final bar = _rect(tester, 'scoreboard-bar-6');
      final tile = _rect(tester, 'scoreboard-tile-6');
      expect(bar.right, closeTo(tile.right, 0.01));
      expect(bar.width, closeTo(tile.width / 2, 0.01));
    });

    for (final brightness in Brightness.values) {
      testWidgets('${brightness.name}: the point bars and „+2 kuž.“ take the '
          'sides\' colours when given — the same the duel cards use', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: Scaffold(
              body: SingleChildScrollView(
                child: MatchScoreboard(
                  slot: rudnaSlot,
                  result: rudnaResult,
                  players: rudnaPlayers,
                  now: _now,
                  homeColor: const Color(0xFF0B8043),
                  awayColor: const Color(0xFF8E24AA),
                ),
              ),
            ),
          ),
        );
        Color? fillOf(Finder f) =>
            (tester
                        .widget<DecoratedBox>(
                          find
                              .descendant(
                                of: f,
                                matching: find.byType(DecoratedBox),
                              )
                              .first,
                        )
                        .decoration
                    as BoxDecoration)
                .color;
        // The bars are marks on the card: a legible shade of the colour.
        expect(
          fillOf(find.byKey(const Key('scoreboard-bar-1'))),
          legibleShadeOf(const Color(0xFF0B8043), brightness),
        );
        expect(
          fillOf(find.byKey(const Key('scoreboard-bar-6'))),
          legibleShadeOf(const Color(0xFF8E24AA), brightness),
        );
        // „+2 kuž.“ is styled like the duel card's „bod“: the side colour
        // at 16 % under onSurface text.
        final pill = tester.widget<DecoratedBox>(
          find
              .ancestor(
                of: find.text('+2 kuž.'),
                matching: find.byType(DecoratedBox),
              )
              .first,
        );
        expect(
          (pill.decoration as ShapeDecoration).color,
          const Color(0xFF0B8043).withValues(alpha: 0.16),
        );
        final scheme = Theme.of(
          tester.element(find.text('+2 kuž.')),
        ).colorScheme;
        expect(_text(tester, '+2 kuž.').style?.color, scheme.onSurface);
      });
    }

    testWidgets('the format and the venue, as plain text', (tester) async {
      await pump(tester);
      expect(find.text('6 hráčů · 100 HS · TJ Sokol Rudná'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsNothing);
    });

    testWidgets('a known venue is a link with a chevron', (tester) async {
      var taps = 0;
      await pump(tester, onVenueTap: () => taps++);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
      await tester.tap(find.text('TJ Sokol Rudná'));
      expect(taps, 1);
    });

    testWidgets("the winner's name is w800, the loser's w400", (tester) async {
      await pump(tester);
      expect(
        _text(tester, 'TJ Sokol Rudná A').style?.fontWeight,
        FontWeight.w800,
      );
      expect(
        _text(tester, 'TJ Sokol Vršovice A').style?.fontWeight,
        FontWeight.w400,
      );
    });

    testWidgets('numbers use tabular figures', (tester) async {
      await pump(tester);
      for (final number in ['2555', '2321', '7', '← 234']) {
        expect(
          _text(tester, number).style?.fontFeatures,
          contains(const FontFeature.tabularFigures()),
          reason: number,
        );
      }
    });
  });

  group('live', () {
    Future<void> pump(WidgetTester tester) => tester.pumpWidget(
      _host(
        MatchScoreboard(
          slot: _liveSlot,
          result: _liveResult,
          players: _livePlayers,
          now: _now,
        ),
      ),
    );

    testWidgets('the chip says Živě with the freshness, after an 8dp dot', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('Živě · před 2 min'), findsOneWidget);
      expect(find.text('Dokončeno'), findsNothing);
      // The dot is an icon, not a „●“ Manrope lacks.
      expect(find.textContaining('●'), findsNothing);
      final dot = find.byIcon(Icons.circle);
      expect(tester.widget<Icon>(dot).size, 8);
      final label = tester.getRect(find.text('Živě · před 2 min'));
      expect(tester.getRect(dot).right, lessThanOrEqualTo(label.left));
      expect(tester.getCenter(dot).dy, closeTo(label.center.dy, 2));
    });

    testWidgets('the score is průběžně and the pins are „zatím“', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('průběžně'), findsOneWidget);
      expect(find.text('Kuželky zatím ← 37'), findsOneWidget);
    });

    testWidgets('the live pins count only lanes both players threw, not the '
        'result\'s totals', (tester) async {
      // Home has thrown duel 2's second lane (226), away has not: the
      // result's totals already count it (842 : 579, a false lead of 263).
      final players = [
        for (final p in _livePlayers)
          if (p.side == 'home' && p.position == 2)
            _player('home', 2, [_lane(1, 209), _lane(2, 226)], total: 435)
          else
            p,
      ];
      await tester.pumpWidget(
        _host(
          MatchScoreboard(
            slot: _liveSlot,
            result: _result(
              'in_progress',
              homePoints: 1,
              awayPoints: 0,
              homeTotal: 842,
              awayTotal: 579,
              fetchedAt: _now.subtract(const Duration(minutes: 2)),
            ),
            players: players,
            now: _now,
          ),
        ),
      );
      expect(find.text('616'), findsOneWidget);
      expect(find.text('579'), findsOneWidget);
      expect(find.text('842'), findsNothing);
      expect(find.text('Kuželky zatím ← 37'), findsOneWidget);
    });

    testWidgets('the explanation counts the done and the running duels', (
      tester,
    ) async {
      await pump(tester);
      expect(find.textContaining('1 rozehrané'), findsOneWidget);
      expect(find.text('Souboje 1 : 0 · 1 rozehrané'), findsOneWidget);
    });

    testWidgets('only a done duel has a bar; no pin points yet', (
      tester,
    ) async {
      await pump(tester);
      expect(find.byKey(const Key('scoreboard-bar-1')), findsOneWidget);
      expect(find.byKey(const Key('scoreboard-bar-2')), findsNothing);
      expect(find.byKey(const Key('scoreboard-bar-3')), findsNothing);
      expect(find.byKey(const Key('scoreboard-tile-3')), findsOneWidget);
      expect(find.textContaining('kuž.'), findsNothing);
    });
  });

  testWidgets('a split: +1 kuž. for each side, a full-width duel bar', (
    tester,
  ) async {
    final players = [
      _player('home', 1, [_lane(1, 220, 1)], total: 220, sb: 1, tb: 1),
      _player('away', 1, [_lane(1, 200, 0)], total: 200, sb: 0, tb: 0),
      _player('home', 2, [_lane(1, 190, 0)], total: 190, sb: 0, tb: 0),
      _player('away', 2, [_lane(1, 210, 1)], total: 210, sb: 1, tb: 1),
      _player('home', 3, [_lane(1, 205, 0.5)], total: 205, sb: 0.5, tb: 0.5),
      _player('away', 3, [_lane(1, 205, 0.5)], total: 205, sb: 0.5, tb: 0.5),
    ];
    await tester.pumpWidget(
      _host(
        MatchScoreboard(
          slot: rudnaSlot,
          result: _result(
            'finished',
            homePoints: 2.5,
            awayPoints: 2.5,
            homeTotal: 615,
            awayTotal: 615,
          ),
          players: players,
          now: _now,
        ),
      ),
    );
    expect(find.text('+1 kuž.'), findsNWidgets(2));
    expect(find.text('='), findsOneWidget);
    // No set points on the result: the explanation leaves SB out.
    expect(find.text('Souboje 1,5 : 1,5 · Kuželky 1 : 1'), findsOneWidget);
    expect(
      _rect(tester, 'scoreboard-bar-2').right,
      closeTo(_rect(tester, 'scoreboard-tile-2').right, 0.01),
    );
    expect(
      _rect(tester, 'scoreboard-bar-3').width,
      closeTo(_rect(tester, 'scoreboard-tile-3').width, 0.01),
    );
    // A tie on points: both names w500.
    expect(
      _text(tester, 'TJ Sokol Rudná A').style?.fontWeight,
      FontWeight.w500,
    );
    expect(
      _text(tester, 'TJ Sokol Vršovice A').style?.fontWeight,
      FontWeight.w500,
    );
  });

  testWidgets('a forfeit says the duels were not played', (tester) async {
    await tester.pumpWidget(
      _host(
        MatchScoreboard(
          slot: rudnaSlot,
          result: _result('forfeit', homePoints: 8, awayPoints: 0),
          players: const [],
          now: _now,
        ),
      ),
    );
    expect(find.text('Kontumace'), findsOneWidget);
    expect(
      find.text('Zápas skončil kontumací – souboje se nehrály.'),
      findsOneWidget,
    );
    expect(find.text('Sestavy zatím nejsou k dispozici.'), findsNothing);
  });

  testWidgets('no lineup yet: a note, and no strip', (tester) async {
    await tester.pumpWidget(
      _host(
        MatchScoreboard(
          slot: rudnaSlot,
          result: _result('scheduled'),
          players: const [],
          now: _now,
        ),
      ),
    );
    expect(find.text('Sestavy zatím nejsou k dispozici.'), findsOneWidget);
    expect(find.text('Naplánováno'), findsOneWidget);
    expect(find.text('–'), findsOneWidget);
    expect(find.text('1'), findsNothing);
    expect(find.byKey(const Key('scoreboard-tile-1')), findsNothing);
  });

  testWidgets('preparation has its chip; no result, no chip', (tester) async {
    await tester.pumpWidget(
      _host(
        MatchScoreboard(
          slot: rudnaSlot,
          result: _result('preparation'),
          players: const [],
          now: _now,
        ),
      ),
    );
    expect(find.text('Příprava'), findsOneWidget);

    await tester.pumpWidget(
      _host(
        MatchScoreboard(
          slot: rudnaSlot,
          result: null,
          players: const [],
          now: _now,
        ),
      ),
    );
    for (final label in [
      'Příprava',
      'Naplánováno',
      'Dokončeno',
      'Kontumace',
      'Probíhá',
    ]) {
      expect(find.text(label), findsNothing, reason: label);
    }
    expect(find.textContaining('Živě'), findsNothing);
    // Without a result there is no format, only the venue.
    expect(find.text('TJ Sokol Rudná'), findsOneWidget);
  });

  group('team names that do not fit 2 lines beside the score', () {
    setUpAll(_loadManrope);

    const kostelec = 'TJ Sokol Kostelec nad Černými lesy A';

    /// [rudnaSlot] with [homeTeam] at home.
    PrioritySlot slotWith(String homeTeam) => PrioritySlot(
      id: rudnaSlot.id,
      date: rudnaSlot.date,
      startsAt: rudnaSlot.startsAt,
      endsAt: rudnaSlot.endsAt,
      type: rudnaSlot.type,
      homeTeam: homeTeam,
      awayTeam: rudnaSlot.awayTeam,
      venue: rudnaSlot.venue,
    );

    /// The finished Rudná result for [slot], 360dp wide at text [scale], in
    /// the app's own theme (Manrope).
    Future<void> pump(
      WidgetTester tester,
      PrioritySlot slot, {
      double scale = 1.3,
    }) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(360, 800),
              textScaler: TextScaler.linear(scale),
            ),
            child: Scaffold(
              body: SingleChildScrollView(
                child: MatchScoreboard(
                  slot: slot,
                  result: rudnaResult,
                  players: rudnaPlayers,
                  now: _now,
                ),
              ),
            ),
          ),
        ),
      );
    }

    final stacked = find.byKey(const Key('scoreboard-stacked'));

    testWidgets('stack: each name on its own row with its score at the '
        'right, and nothing cut short', (tester) async {
      await pump(tester, slotWith(kostelec));
      expect(tester.takeException(), isNull);
      expect(stacked, findsOneWidget);

      final home = tester.getRect(find.text(kostelec));
      final away = tester.getRect(find.text('TJ Sokol Vršovice A'));
      final homeScore = find.descendant(of: stacked, matching: find.text('7'));
      final awayScore = find.descendant(of: stacked, matching: find.text('1'));
      expect(away.top, greaterThanOrEqualTo(home.bottom));
      expect(tester.getRect(homeScore).left, greaterThan(home.right));
      expect(tester.getRect(awayScore).left, greaterThan(away.right));
      expect(
        tester.getCenter(homeScore).dy,
        inInclusiveRange(home.top, home.bottom),
      );
      expect(
        tester.getCenter(awayScore).dy,
        inInclusiveRange(away.top, away.bottom),
      );
      // 36dp, the winner's w800 and the loser's w400, tabular digits.
      final winner = tester.widget<Text>(homeScore).style!;
      final loser = tester.widget<Text>(awayScore).style!;
      expect([winner.fontSize, loser.fontSize], [36, 36]);
      expect(winner.fontWeight, FontWeight.w800);
      expect(loser.fontWeight, FontWeight.w400);
      expect(winner.fontFeatures, contains(const FontFeature.tabularFigures()));

      for (final paragraph in tester.renderObjectList<RenderParagraph>(
        find.descendant(
          of: find.byType(MatchScoreboard),
          matching: find.byType(RichText),
        ),
      )) {
        expect(
          paragraph.didExceedMaxLines,
          isFalse,
          reason: paragraph.text.toPlainText(),
        );
      }
    });

    testWidgets('names that fit keep the side-by-side layout', (tester) async {
      // At 1.3 even „TJ Sokol Vršovice A“ would need a third line on 360dp;
      // at 1.0 both fit 2.
      await pump(tester, rudnaSlot, scale: 1.0);
      expect(tester.takeException(), isNull);
      expect(stacked, findsNothing);
      expect(_text(tester, '7').style?.fontSize, 44);
    });
  });

  final states = {
    'finished': (slot: rudnaSlot, result: rudnaResult, players: rudnaPlayers),
    'live': (slot: _liveSlot, result: _liveResult, players: _livePlayers),
  };
  for (final MapEntry(key: name, value: state) in states.entries) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('$name: no overflow on a 360dp phone at text scale $scale', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: const Size(360, 800),
                textScaler: TextScaler.linear(scale),
              ),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: MatchScoreboard(
                    slot: state.slot,
                    result: state.result,
                    players: state.players,
                    now: _now,
                    onVenueTap: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        // The strip scales down to fit rather than overflowing.
        expect(
          tester.getRect(find.byKey(const Key('scoreboard-tile-6'))).right,
          lessThanOrEqualTo(360),
        );
      });
    }
  }
}

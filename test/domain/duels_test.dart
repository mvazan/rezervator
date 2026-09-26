import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/duels.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/results.dart';

import '../support/rudna_vrsovice.dart';

MatchPlayerResult player(
  String side,
  int pos,
  List<Map<String, Object?>> lanes, {
  int? total,
  num? sb,
  num? tb,
  String? name,
}) => MatchPlayerResult.fromJson({
  'id': '$side$pos',
  'match_id': 'x',
  'side': side,
  'position': pos,
  'player_name': name ?? '$side $pos',
  'total': total,
  'set_points': sb,
  'team_points': tb,
  'lanes': lanes,
});
Map<String, Object?> lane(int n, int? total, [num? sp]) => {
  'lane': n,
  'fulls': null,
  'spares': null,
  'errors': null,
  'total': total,
  'setPoints': sp,
};

void main() {
  group('the real Rudná A 7 : 1 Vršovice A', () {
    final duels = duelsOf(rudnaPlayers);

    test('six duels in position order, all done', () {
      expect(duels.map((d) => d.position), [1, 2, 3, 4, 5, 6]);
      expect(duels.every((d) => d.state == DuelState.done), isTrue);
    });
    test('differences from the player totals', () {
      expect(duels.map((d) => d.diff), [22, 57, 4, 55, 99, -3]);
    });
    test('a done duel shows the players\' own totals', () {
      expect(duels.map((d) => d.shownHome), [407, 435, 395, 437, 450, 431]);
      expect(duels.map((d) => d.shownAway), [385, 378, 391, 382, 351, 434]);
    });
    test('point winners, and which duels pins decided', () {
      expect(duels.map((d) => d.pointWinner), [
        MatchSide.home,
        MatchSide.home,
        MatchSide.home,
        MatchSide.home,
        MatchSide.home,
        MatchSide.away,
      ]);
      expect(duels.map((d) => d.decidedByPins), [
        true,
        false,
        true,
        false,
        false,
        false,
      ]);
    });
    test('lane winners, and duel 6 has a tied first lane', () {
      expect(duels[0].lanes.map((l) => l.winner), [
        MatchSide.away,
        MatchSide.home,
      ]);
      expect(duels[5].lanes[0].tie, isTrue);
      expect(duels[5].lanes[0].winner, isNull);
      expect(duels[5].lanes[1].winner, MatchSide.away);
    });
    test('the shared bar scale is the biggest difference, at least 50', () {
      expect(diffScale(duels), 99);
      expect(diffScale(const []), 50);
    });
    test('5 duels + 2 for pins = 7, 1 duel + 0 = 1', () {
      final b = matchPointsBreakdown(rudnaResult, rudnaPlayers)!;
      expect([b.duelsHome, b.duelsAway, b.pinsHome, b.pinsAway], [5, 1, 2, 0]);
    });
    test('the TalkBack text of duel 1', () {
      expect(
        duelSemantics(duels[0]),
        '1. souboj: Lucie Mičanová 407, Lukáš Pelánek 385, o 22, bod domácím',
      );
    });
  });

  test('leadLabel points at the leader', () {
    expect(leadLabel(22), '← 22');
    expect(leadLabel(-3), '3 →');
    expect(leadLabel(0), '=');
    expect(leadLabel(null), '');
  });

  group('live', () {
    test('a duel with no lane thrown is waiting, with no difference', () {
      final d = duelsOf([
        player('home', 1, [lane(1, null), lane(2, null)]),
        player('away', 1, [lane(1, null), lane(2, null)]),
      ]).single;
      expect(d.state, DuelState.waiting);
      expect(d.diff, isNull);
      expect(d.shownHome, isNull);
      expect(d.shownAway, isNull);
      expect(duelSemantics(d), endsWith(', čeká'));
    });
    test('the difference counts only lanes both players threw', () {
      final d = duelsOf([
        player('home', 1, [lane(1, 213), lane(2, 150)], total: 363),
        player('away', 1, [lane(1, 216), lane(2, null)], total: 216),
      ]).single;
      expect(d.state, DuelState.playing);
      expect(d.playedLanes, 1);
      expect(d.diff, -3);
      expect(d.pointWinner, isNull);
    });
    test('the shown totals count the same lanes as the difference, and '
        'TalkBack names the leader', () {
      final d = duelsOf([
        player(
          'home',
          1,
          [lane(1, 213), lane(2, 150)],
          total: 363,
          name: 'Lucie Mičanová',
        ),
        player(
          'away',
          1,
          [lane(1, 216), lane(2, null)],
          total: 216,
          name: 'Lukáš Pelánek',
        ),
      ]).single;
      expect(d.shownHome, 213);
      expect(d.shownAway, 216);
      expect(
        duelSemantics(d),
        '1. souboj: Lucie Mičanová 213, Lukáš Pelánek 216, hraje se, '
        'vede Pelánek o 3',
      );
    });
    test('a level duel while playing reads „nerozhodně“', () {
      final d = duelsOf([
        player('home', 1, [lane(1, 200), lane(2, 150)], total: 350),
        player('away', 1, [lane(1, 200), lane(2, null)], total: 200),
      ]).single;
      expect(d.shownHome, 200);
      expect(d.shownAway, 200);
      expect(
        duelSemantics(d),
        '1. souboj: home 1 200, away 1 200, hraje se, nerozhodně',
      );
    });
    test('playing, but no lane both threw: no totals and no leader yet', () {
      final d = duelsOf([
        player('home', 1, [lane(1, 213), lane(2, null)], total: 213),
        player('away', 1, [lane(1, null), lane(2, null)]),
      ]).single;
      expect(d.state, DuelState.playing);
      expect(d.shownHome, isNull);
      expect(d.shownAway, isNull);
      expect(duelSemantics(d), '1. souboj: home 1 –, away 1 –, hraje se');
    });
    test('T120: four lanes, done when all four are thrown', () {
      final d = duelsOf([
        player(
          'home',
          1,
          [for (var i = 1; i <= 4; i++) lane(i, 150, 1)],
          total: 600,
          sb: 4,
          tb: 1,
        ),
        player(
          'away',
          1,
          [for (var i = 1; i <= 4; i++) lane(i, 140, 0)],
          total: 560,
          sb: 0,
          tb: 0,
        ),
      ]).single;
      expect(d.laneCount, 4);
      expect(d.state, DuelState.done);
      expect(d.diff, 40);
      expect(d.decidedByPins, isFalse);
    });
    test('a split point (0.5 each) has no winner', () {
      final d = duelsOf([
        player('home', 1, [lane(1, 200, 0.5)], total: 200, sb: 0.5, tb: 0.5),
        player('away', 1, [lane(1, 200, 0.5)], total: 200, sb: 0.5, tb: 0.5),
      ]).single;
      expect(d.pointWinner, isNull);
      expect(d.pointSplit, isTrue);
      expect(duelSemantics(d), endsWith(', body napůl'));
    });
  });

  group('liveTeamTotals', () {
    test('sums the shown totals: a lane only one side threw never counts', () {
      final totals = liveTeamTotals(
        duelsOf([
          player('home', 1, [lane(1, 213), lane(2, 194)], total: 407),
          player('away', 1, [lane(1, 216), lane(2, 169)], total: 385),
          player('home', 2, [lane(1, 209), lane(2, 226)], total: 435),
          player('away', 2, [lane(1, 194), lane(2, null)], total: 194),
          player('home', 3, [lane(1, null), lane(2, null)]),
          player('away', 3, [lane(1, null), lane(2, null)]),
        ]),
      );
      expect(totals, (home: 407 + 209, away: 385 + 194));
    });
    test('the finished match: the players\' totals', () {
      expect(liveTeamTotals(duelsOf(rudnaPlayers)), (home: 2555, away: 2321));
    });
    test('null while no duel has a shown total', () {
      expect(liveTeamTotals(const []), isNull);
      expect(
        liveTeamTotals(
          duelsOf([
            player('home', 1, [lane(1, 213), lane(2, null)], total: 213),
            player('away', 1, [lane(1, null), lane(2, null)]),
          ]),
        ),
        isNull,
      );
    });
  });

  group('incomplete data', () {
    test('no lanes at all: done once both player totals are known', () {
      final d = duelsOf([
        player('home', 1, const [], total: 400, sb: 0, tb: 1),
        player('away', 1, const [], total: 380, sb: 0, tb: 0),
      ]).single;
      expect(d.laneCount, 0);
      expect(d.state, DuelState.done);
      expect(d.diff, 20);
      expect(d.pointWinner, MatchSide.home);
      expect(d.decidedByPins, isTrue);
    });
    test('a position only one side has is never done, and has no diff', () {
      final d = duelsOf([
        player('home', 1, [lane(1, 200), lane(2, 190)], total: 390),
      ]).single;
      expect(d.away, isNull);
      expect(d.state, DuelState.playing);
      expect(d.diff, isNull);
      // No lane both threw: the card prints „– : –“, and TalkBack agrees.
      expect(d.shownHome, isNull);
      expect(duelSemantics(d), '1. souboj: home 1 –, – –, hraje se');
    });
    test('no result, or a duel point not known yet: no breakdown', () {
      expect(matchPointsBreakdown(null, rudnaPlayers), isNull);
      expect(
        matchPointsBreakdown(rudnaResult, [
          player('home', 1, [lane(1, 200)], total: 200),
          player('away', 1, [lane(1, 190)], total: 190),
        ]),
        isNull,
      );
    });
  });

  test('teamBonusPoints: Body minus the duel points of that side', () {
    expect(teamBonusPoints(7, rudnaPlayers, 'home'), 2);
    expect(teamBonusPoints(1, rudnaPlayers, 'away'), 0);
    expect(teamBonusPoints(null, rudnaPlayers, 'home'), isNull);
  });
}

/// The match detail's „Souboje“ view: a federation match told as its duels —
/// the home and away player of each position, their lanes side by side, who
/// is ahead and by how much, and who took the duel's point. Pure Dart,
/// unit-tested; the scoreboard, the duel cards and the Družstva card only
/// render it.
///
/// Live-safe by construction: a lane counts as thrown only when its `total`
/// is known, and a running difference counts only the lanes BOTH players
/// have thrown, so a late update from one side never shows a false +200.
library;

import 'dart:math' as math;

import 'models.dart';
import 'results.dart';

/// Where a duel stands: no lane thrown yet, some lanes thrown, or every lane
/// of both players thrown.
enum DuelState { waiting, playing, done }

/// The home and away player's line on one lane number.
class LanePair {
  const LanePair({required this.lane, this.home, this.away});

  /// The lane number (1-based).
  final int lane;

  /// The home player's line, or null when that player has no such lane.
  final PlayerLane? home;

  /// The away player's line, or null when that player has no such lane.
  final PlayerLane? away;

  /// Both players threw this lane (both totals non-null).
  bool get played => home?.total != null && away?.total != null;

  /// Higher total when [played]; null on a tie or when not played.
  MatchSide? get winner {
    if (!played) return null;
    return winningSide(home!.total, away!.total);
  }

  /// Played and equal totals.
  bool get tie => played && home!.total == away!.total;
}

/// One position's duel: the home and away player who faced each other.
class Duel {
  const Duel({
    required this.position,
    required this.home,
    required this.away,
    required this.lanes,
    required this.state,
    required this.playedLanes,
    required this.diff,
    required this.shownHome,
    required this.shownAway,
    required this.pointWinner,
    required this.pointSplit,
    required this.decidedByPins,
  });

  /// The position in the lineup (1-based), shared by both players.
  final int position;

  /// The home player, or null when the lineup has no one at [position].
  final MatchPlayerResult? home;

  /// The away player, or null when the lineup has no one at [position].
  final MatchPlayerResult? away;

  /// Lane 1..n, the union of both sides' lane numbers, ascending.
  final List<LanePair> lanes;

  /// Waiting, playing or done — see [duelsOf] for the rules.
  final DuelState state;

  /// How many lanes both players threw.
  final int playedLanes;

  /// How many lanes the duel has ([lanes]' length): 2 for T100, 4 for T120.
  int get laneCount => lanes.length;

  /// home − away. done: player totals; playing: sum over lanes both threw;
  /// waiting: null. Also null when a needed total is missing.
  final int? diff;

  /// The home total every view prints (the card and its TalkBack text).
  /// done: the player's own total; playing: the sum over the lanes both
  /// players threw — the lanes [diff] counts — or null before there is one;
  /// waiting: null.
  final int? shownHome;

  /// The away total every view prints — see [shownHome].
  final int? shownAway;

  /// done only: the side whose teamPoints is 1; null on a split (0.5 each)
  /// or unknown.
  final MatchSide? pointWinner;

  /// done only: teamPoints 0.5 each.
  final bool pointSplit;

  /// done only: equal set points and a pointWinner (pins decided it).
  final bool decidedByPins;
}

/// One Duel per position present in [players], sorted by position.
///
/// A duel is *waiting* while neither player has a thrown lane or a total;
/// *done* once both players are there and every lane pair is played (or,
/// with no lanes at all, both totals are known); *playing* otherwise.
List<Duel> duelsOf(List<MatchPlayerResult> players) {
  final homes = <int, MatchPlayerResult>{};
  final aways = <int, MatchPlayerResult>{};
  for (final p in players) {
    final bySide = p.side == 'home' ? homes : aways;
    bySide.putIfAbsent(p.position, () => p);
  }
  final positions = {...homes.keys, ...aways.keys}.toList()..sort();
  return [
    for (final position in positions)
      _duel(position, homes[position], aways[position]),
  ];
}

/// The duel at [position] between [home] and [away] (either may be missing).
Duel _duel(int position, MatchPlayerResult? home, MatchPlayerResult? away) {
  PlayerLane? laneOf(MatchPlayerResult? p, int lane) {
    for (final l in p?.lanes ?? const <PlayerLane>[]) {
      if (l.lane == lane) return l;
    }
    return null;
  }

  final laneNumbers = {
    for (final l in home?.lanes ?? const <PlayerLane>[]) l.lane,
    for (final l in away?.lanes ?? const <PlayerLane>[]) l.lane,
  }.toList()..sort();
  final lanes = List<LanePair>.unmodifiable([
    for (final n in laneNumbers)
      LanePair(lane: n, home: laneOf(home, n), away: laneOf(away, n)),
  ]);
  final played = lanes.where((l) => l.played).toList();

  bool threwAnything(MatchPlayerResult? p) =>
      p != null && (p.total != null || p.lanes.any((l) => l.total != null));

  final DuelState state;
  if (!threwAnything(home) && !threwAnything(away)) {
    state = DuelState.waiting;
  } else if (home != null &&
      away != null &&
      (lanes.isEmpty
          ? home.total != null && away.total != null
          : played.length == lanes.length)) {
    state = DuelState.done;
  } else {
    state = DuelState.playing;
  }

  // The totals every view prints: a lane only one side has thrown never
  // counts while the duel is played, so it can never show as a lead.
  final (int?, int?) shown = switch (state) {
    DuelState.waiting => (null, null),
    DuelState.playing =>
      played.isEmpty
          ? (null, null)
          : (
              played.fold<int>(0, (sum, l) => sum + l.home!.total!),
              played.fold<int>(0, (sum, l) => sum + l.away!.total!),
            ),
    DuelState.done => (home!.total, away!.total),
  };
  final (shownHome, shownAway) = shown;

  final int? diff = switch (state) {
    DuelState.waiting => null,
    DuelState.playing || DuelState.done =>
      shownHome == null || shownAway == null ? null : shownHome - shownAway,
  };

  final done = state == DuelState.done;
  final homePoint = home?.teamPoints;
  final awayPoint = away?.teamPoints;
  MatchSide? pointWinner;
  if (done && homePoint == 1 && awayPoint != 1) pointWinner = MatchSide.home;
  if (done && awayPoint == 1 && homePoint != 1) pointWinner = MatchSide.away;
  final homeSet = home?.setPoints;
  final awaySet = away?.setPoints;

  return Duel(
    position: position,
    home: home,
    away: away,
    lanes: lanes,
    state: state,
    playedLanes: played.length,
    diff: diff,
    shownHome: shownHome,
    shownAway: shownAway,
    pointWinner: pointWinner,
    pointSplit: done && homePoint == 0.5 && awayPoint == 0.5,
    decidedByPins: pointWinner != null && homeSet != null && homeSet == awaySet,
  );
}

/// max(50, the biggest |diff| among [duels]); 50 when none has a diff.
///
/// The one scale every duel's difference bar shares, so a +4 reads as a
/// sliver next to a +99.
int diffScale(List<Duel> duels) {
  var scale = 50;
  for (final d in duels) {
    final diff = d.diff;
    if (diff != null) scale = math.max(scale, diff.abs());
  }
  return scale;
}

/// '◂ 22' (home leads), '3 ▸' (away leads), '=' (0), '' (null).
///
/// The arrow points at the leader: home sits on the left, away on the right.
String leadLabel(int? diff) {
  if (diff == null) return '';
  if (diff == 0) return '=';
  return diff > 0 ? '◂ $diff' : '${-diff} ▸';
}

/// Duel points per side (sum of teamPoints) and the pin points
/// (teamBonusPoints); null when [result] or a needed value is missing.
///
/// For the scoreboard's „Souboje 5 : 1 · Kuželky 2 : 0“: the duel points and
/// the pin points add up to the match's Body.
({num duelsHome, num duelsAway, num pinsHome, num pinsAway})?
matchPointsBreakdown(MatchResult? result, List<MatchPlayerResult> players) {
  if (result == null) return null;
  final duelsHome = _duelPoints(players, 'home');
  final duelsAway = _duelPoints(players, 'away');
  final pinsHome = teamBonusPoints(result.homePoints, players, 'home');
  final pinsAway = teamBonusPoints(result.awayPoints, players, 'away');
  if (duelsHome == null ||
      duelsAway == null ||
      pinsHome == null ||
      pinsAway == null) {
    return null;
  }
  return (
    duelsHome: duelsHome,
    duelsAway: duelsAway,
    pinsHome: pinsHome,
    pinsAway: pinsAway,
  );
}

/// The duel points [side]'s players won (the sum of their teamPoints); null
/// when the side has no players or any of them has no teamPoints yet.
num? _duelPoints(List<MatchPlayerResult> players, String side) {
  num sum = 0;
  var any = false;
  for (final p in players) {
    if (p.side != side) continue;
    final points = p.teamPoints;
    if (points == null) return null;
    sum += points;
    any = true;
  }
  return any ? sum : null;
}

/// The last word of [name] („Lucie Mičanová“ → „Mičanová“); '–' when
/// there is no name.
String surnameOf(String? name) {
  final trimmed = name?.trim() ?? '';
  return trimmed.isEmpty ? '–' : trimmed.split(RegExp(r'\s+')).last;
}

/// TalkBack text for one duel, e.g.
/// '1. souboj: Lucie Mičanová 407, Lukáš Pelánek 385, o 22, bod domácím'.
///
/// The totals are the shown ones ([Duel.shownHome], [Duel.shownAway]), the
/// same the card prints. Missing names and totals read '–'; the tail says
/// the duel's state: „bod domácím“ / „bod hostům“ / „body napůl“ when
/// done, „čeká“ while waiting, and while playing „hraje se, vede Pelánek
/// o 3“ („hraje se, nerozhodně“ when level, just „hraje se“ before a lane
/// both players threw).
String duelSemantics(Duel duel) {
  final text = StringBuffer(
    '${duel.position}. souboj: '
    '${duel.home?.playerName ?? '–'} ${numLabel(duel.shownHome)}, '
    '${duel.away?.playerName ?? '–'} ${numLabel(duel.shownAway)}',
  );
  final diff = duel.diff;
  switch (duel.state) {
    case DuelState.done:
      if (diff != null && diff != 0) text.write(', o ${diff.abs()}');
      if (duel.pointWinner == MatchSide.home) {
        text.write(', bod domácím');
      } else if (duel.pointWinner == MatchSide.away) {
        text.write(', bod hostům');
      } else if (duel.pointSplit) {
        text.write(', body napůl');
      }
    case DuelState.waiting:
      text.write(', čeká');
    case DuelState.playing:
      text.write(', hraje se');
      if (diff == 0) {
        text.write(', nerozhodně');
      } else if (diff != null) {
        final leader = diff > 0 ? duel.home : duel.away;
        text.write(', vede ${surnameOf(leader?.playerName)} o ${diff.abs()}');
      }
  }
  return text.toString();
}

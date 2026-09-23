/// A match's "Home – Away" title, the leading side's NAME weighted once
/// there's score data (Fix round 1: emphasis moved off the score number and
/// onto the team name it belongs to) — the day dialog, Výsledky and Můj
/// přehled all go through this so the rule can't drift between them. [winner]
/// isn't only the FINAL result: a live, [MatchStatus.inProgress] match with
/// points already on the board shows the side currently ahead the same way
/// — see `displayWinner` (`domain/results.dart`), which callers use to
/// compute it. No winner (no score data yet, a draw, or not a match at all)
/// renders exactly like the plain title always did.
library;

import 'package:flutter/material.dart';

import '../../../domain/models.dart';
import '../../../domain/results.dart';

class MatchTitle extends StatelessWidget {
  const MatchTitle({super.key, required this.slot, this.winner, this.style});

  final PrioritySlot slot;
  final MatchSide? winner;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    if (winner == null || !slot.type.isMatch || slot.homeTeam.isEmpty) {
      return Text(slot.title, style: style);
    }
    final base = style ?? DefaultTextStyle.of(context).style;
    // FIXED weights on both sides, not "add bold" to one relative to base:
    // some text roles this renders under (e.g. titleSmall) are already
    // w700 — `FontWeight.bold` IS w700, so copying it onto just the winner
    // would be a no-op there, and even a genuinely heavier fixed winner
    // weight reads as barely-there next to an already-bold base (w700 vs
    // w800 is one Manrope step). Setting the LOSING side to w400 as well
    // guarantees a real, consistent gap on every base role this is used
    // under. w800 is the heaviest Manrope cut this app actually bundles
    // (pubspec.yaml) — w900 would synthesise/fall back instead of
    // rendering the real font.
    final winnerStyle = base.copyWith(fontWeight: FontWeight.w800);
    final loserStyle = base.copyWith(fontWeight: FontWeight.w400);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: slot.homeTeam,
            style: winner == MatchSide.home ? winnerStyle : loserStyle,
          ),
          TextSpan(text: ' – ', style: base),
          TextSpan(
            text: slot.awayTeam,
            style: winner == MatchSide.away ? winnerStyle : loserStyle,
          ),
        ],
      ),
    );
  }
}

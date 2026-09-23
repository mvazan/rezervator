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
    // A FIXED heavier weight, not "add bold" relative to base: some text
    // roles this renders under (e.g. titleSmall) are already w700 —
    // `FontWeight.bold` IS w700, so copying it on top would be a no-op.
    // w900 guarantees visible contrast whatever the surrounding role's own
    // weight already is. The losing side stays exactly `base`, untouched.
    final winnerStyle = base.copyWith(fontWeight: FontWeight.w900);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: slot.homeTeam,
            style: winner == MatchSide.home ? winnerStyle : base,
          ),
          TextSpan(text: ' – ', style: base),
          TextSpan(
            text: slot.awayTeam,
            style: winner == MatchSide.away ? winnerStyle : base,
          ),
        ],
      ),
    );
  }
}

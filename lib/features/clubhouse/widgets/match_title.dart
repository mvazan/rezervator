/// A match's "Home – Away" title, the winning side's NAME bolded once the
/// match is decided (Fix round 1: emphasis moved off the score number and
/// onto the team name it belongs to) — the day dialog and Výsledky's row
/// both go through this so the rule can't drift between them. No winner (no
/// result yet, a draw, or not a match at all) renders exactly like the plain
/// title always did.
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
    final bold = base.copyWith(fontWeight: FontWeight.bold);
    return Text.rich(TextSpan(children: [
      TextSpan(
        text: slot.homeTeam,
        style: winner == MatchSide.home ? bold : base,
      ),
      TextSpan(text: ' – ', style: base),
      TextSpan(
        text: slot.awayTeam,
        style: winner == MatchSide.away ? bold : base,
      ),
    ]));
  }
}

/// A match's score as "H : A", the winning side bolded (Task 1) — the one
/// place every points display goes through, so the bolding rule (and the
/// draw/no-result fallback) can't drift between the day dialog, Výsledky and
/// the match detail header.
library;

import 'package:flutter/material.dart';

import '../../../domain/results.dart';

class ScoreLabel extends StatelessWidget {
  const ScoreLabel({
    super.key,
    required this.home,
    required this.away,
    this.style,
  });

  final num? home;
  final num? away;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    if (home == null && away == null) return Text('–', style: style);
    final winner = winningSide(home, away);
    TextStyle? weigh(MatchSide side) =>
        winner == side ? style?.copyWith(fontWeight: FontWeight.w800) : style;
    return Text.rich(TextSpan(children: [
      TextSpan(text: numLabel(home), style: weigh(MatchSide.home)),
      TextSpan(text: ' : ', style: style),
      TextSpan(text: numLabel(away), style: weigh(MatchSide.away)),
    ]));
  }
}

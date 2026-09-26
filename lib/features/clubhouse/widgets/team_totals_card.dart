/// The match detail's Družstva card (Souboje, Task 5): the two teams' sums
/// side by side, below the duels — Kuželky, Plné, Dorážka, Chyby and SB, one
/// mirrored row each with the lead between the values („Kuželky ◂ 234“).
///
/// Home is always on the left. Every number is set in tabular figures, and
/// the leader is never told by colour alone: its value is w800 (the other
/// w500, both in full onSurface) and the arrow points at it. For Chyby the
/// side with FEWER errors leads, and its label says so („(méně = lépe)“)
/// instead of printing an arrow.
library;

import 'package:flutter/material.dart';

import '../../../domain/duels.dart';
import '../../../domain/models.dart';
import '../../../domain/results.dart';

/// Digits of one width, so a number doesn't jump when a live value changes.
const _tabular = [FontFeature.tabularFigures()];

/// The Družstva card — see the library comment.
///
/// The card has no margin of its own: the list places it, like the duel
/// cards above it.
class TeamTotalsCard extends StatelessWidget {
  const TeamTotalsCard({super.key, required this.result});

  /// The team-level score whose sums the card shows. Without both pin
  /// totals the card renders nothing.
  final MatchResult result;

  @override
  Widget build(BuildContext context) {
    final homeTotal = result.homeTotal;
    final awayTotal = result.awayTotal;
    if (homeTotal == null || awayTotal == null) return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;

    // A row neither side has a value for says nothing: it is left out.
    bool known(num? home, num? away) => home != null || away != null;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Text('Družstva', style: text.titleSmall),
            ),
            const SizedBox(height: 4),
            _Row(
              key: const Key('team-totals-kuzelky'),
              name: 'Kuželky',
              lead: _lead(homeTotal, awayTotal),
              home: homeTotal,
              away: awayTotal,
              leader: winningSide(homeTotal, awayTotal),
            ),
            if (known(result.homeFulls, result.awayFulls))
              _Row(
                key: const Key('team-totals-plne'),
                name: 'Plné',
                lead: _lead(result.homeFulls, result.awayFulls),
                home: result.homeFulls,
                away: result.awayFulls,
                leader: winningSide(result.homeFulls, result.awayFulls),
              ),
            if (known(result.homeSpares, result.awaySpares))
              _Row(
                key: const Key('team-totals-dorazka'),
                name: 'Dorážka',
                lead: _lead(result.homeSpares, result.awaySpares),
                home: result.homeSpares,
                away: result.awaySpares,
                leader: winningSide(result.homeSpares, result.awaySpares),
              ),
            if (known(result.homeErrors, result.awayErrors))
              _Row(
                key: const Key('team-totals-chyby'),
                name: 'Chyby (méně = lépe)',
                home: result.homeErrors,
                away: result.awayErrors,
                // Fewer errors lead: the arguments are swapped.
                leader: winningSide(result.awayErrors, result.homeErrors),
              ),
            if (known(result.homeSetPoints, result.awaySetPoints))
              _Row(
                key: const Key('team-totals-sb'),
                name: 'SB',
                home: result.homeSetPoints,
                away: result.awaySetPoints,
                leader: winningSide(result.homeSetPoints, result.awaySetPoints),
              ),
          ],
        ),
      ),
    );
  }

  /// [leadLabel] of home − away („◂ 234“, „100 ▸“, „=“); '' when either
  /// side is unknown.
  static String _lead(int? home, int? away) =>
      home == null || away == null ? '' : leadLabel(home - away);
}

/// One mirrored row, at least 44dp tall: the home value on the left, „name
/// lead“ in the middle, the away value on the right. The leader's value is
/// w800, the other w500. The label takes at most half the row, so it stays
/// centred and the values keep room; large text wraps the label and shrinks
/// a value that no longer fits.
class _Row extends StatelessWidget {
  const _Row({
    super.key,
    required this.name,
    required this.home,
    required this.away,
    required this.leader,
    this.lead = '',
  });

  /// „Kuželky“, „Plné“, „Dorážka“, „Chyby (méně = lépe)“ or „SB“.
  final String name;

  /// [leadLabel]'s arrow and difference after [name]; '' prints none.
  final String lead;

  /// The home side's value; null prints „–“.
  final num? home;

  /// The away side's value; null prints „–“.
  final num? away;

  /// The side printed w800; null = neither.
  final MatchSide? leader;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    TextStyle? value(MatchSide side) => text.titleMedium?.copyWith(
      fontSize: 18,
      fontWeight: leader == side ? FontWeight.w800 : FontWeight.w500,
      color: scheme.onSurface,
      fontFeatures: _tabular,
    );

    Widget side(MatchSide side) => Expanded(
      child: Align(
        alignment: side == MatchSide.home
            ? Alignment.centerLeft
            : Alignment.centerRight,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            numLabel(side == MatchSide.home ? home : away),
            style: value(side),
          ),
        ),
      ),
    );

    // One label per row, read without the arrow glyph: „Kuželky 2555 : 2321“.
    return Semantics(
      container: true,
      label: '$name ${pointsLabel(home, away)}',
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: LayoutBuilder(
          builder: (context, constraints) => Row(
            children: [
              side(MatchSide.home),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: constraints.maxWidth / 2,
                  ),
                  child: Text(
                    lead.isEmpty ? name : '$name $lead',
                    textAlign: TextAlign.center,
                    // A wrapped label is only as wide as its longest line,
                    // so the values keep the rest.
                    textWidthBasis: TextWidthBasis.longestLine,
                    style: text.bodyMedium?.copyWith(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: scheme.onSurfaceVariant,
                      fontFeatures: _tabular,
                    ),
                  ),
                ),
              ),
              side(MatchSide.away),
            ],
          ),
        ),
      ),
    );
  }
}

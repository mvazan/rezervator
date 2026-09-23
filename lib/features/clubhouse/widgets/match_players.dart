/// Match detail (Task 4): the two "Domácí"/"Hosté" player sections, one
/// `ExpansionTile` per player, expanding into its own per-lane table.
/// Split out of `match_detail_screen.dart` to keep that file to the
/// header/stats/buttons.
library;

import 'package:flutter/material.dart';

import '../../../domain/models.dart';
import '../../../domain/results.dart';

/// "Domácí — {home team}" / "Hosté — {away team}", or nothing when
/// [players] is empty (the caller shows the shared "no sestavy" message
/// once instead).
class MatchPlayerSection extends StatelessWidget {
  const MatchPlayerSection({super.key, required this.title, required this.players});

  final String title;
  final List<MatchPlayerResult> players;

  @override
  Widget build(BuildContext context) {
    if (players.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(title, style: Theme.of(context).textTheme.titleSmall),
        ),
        for (final player in players) _PlayerTile(player: player),
      ],
    );
  }
}

class _PlayerTile extends StatelessWidget {
  const _PlayerTile({required this.player});

  final MatchPlayerResult player;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExpansionTile(
      title: Text('${player.position}. ${player.playerName}'),
      subtitle: Text(
        'P ${numLabel(player.fulls)} · D ${numLabel(player.spares)} · '
        'Ch ${numLabel(player.errors)}',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if ((player.teamPoints ?? 0) > 0) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'bod',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                numLabel(player.total),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text('SB ${numLabel(player.setPoints)}', style: theme.textTheme.bodySmall),
            ],
          ),
        ],
      ),
      children: player.lanes.isEmpty
          ? const []
          : [_LanesTable(lanes: player.lanes)],
    );
  }
}

class _LanesTable extends StatelessWidget {
  const _LanesTable({required this.lanes});

  final List<PlayerLane> lanes;

  @override
  Widget build(BuildContext context) {
    final headerStyle = Theme.of(
      context,
    ).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.bold);
    Widget cell(String text, {TextStyle? style}) =>
        Expanded(child: Text(text, textAlign: TextAlign.center, style: style));
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        children: [
          Row(
            children: [
              cell('Dráha', style: headerStyle),
              cell('P', style: headerStyle),
              cell('D', style: headerStyle),
              cell('Ch', style: headerStyle),
              cell('Σ', style: headerStyle),
              cell('SB', style: headerStyle),
            ],
          ),
          for (final lane in lanes)
            Row(
              children: [
                cell('${lane.lane}'),
                cell(numLabel(lane.fulls)),
                cell(numLabel(lane.spares)),
                cell(numLabel(lane.errors)),
                cell(numLabel(lane.total)),
                cell(numLabel(lane.setPoints)),
              ],
            ),
        ],
      ),
    );
  }
}

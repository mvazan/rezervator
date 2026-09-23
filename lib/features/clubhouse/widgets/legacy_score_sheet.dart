/// Match detail (Task 4, federation-results-ui): a dense per-pairing score
/// sheet styled like kuzelky.com's old table (team summary + one block per
/// roster position), in the app's own font. Replaces `MatchPlayerSection`'s
/// two ExpansionTile lists.
library;

import 'package:flutter/material.dart';

import '../../../domain/models.dart';
import '../../../domain/results.dart';

/// One pairing block per position (1..N): the home and away player who
/// faced each other, each with a line per lane thrown plus a Celkem total,
/// and the pin difference between them. Above the blocks, a team-column
/// label row, a team summary row and (when there IS a lineup) a column
/// header row, all mirrored for both sides.
///
/// Returns `SizedBox.shrink()` only when there is truly nothing to show
/// ([result] null AND [players] empty). When [result] carries team-level
/// data but [players] is empty (lineup not synced yet), the team summary
/// still renders — Fix round 1: it used to disappear along with the
/// per-player section, silently hiding Plné/Dor./Ch. the header card
/// doesn't show. The caller (`match_detail_screen.dart`) still owns the
/// "Sestavy zatím nejsou k dispozici." message for the missing-lineup case.
class LegacyScoreSheet extends StatelessWidget {
  const LegacyScoreSheet({
    super.key,
    required this.slot,
    required this.result,
    required this.players,
    this.showHeader = true,
  });

  final PrioritySlot slot;
  final MatchResult? result;
  final List<MatchPlayerResult> players;

  /// False on the full-screen page (`LegacyScoreSheetPage`) — the "Zápis" /
  /// "Zvětšit" row belongs to the embedded card only; the full-screen page
  /// already has its own AppBar title, and it has nowhere further to push
  /// to (Fix round 1: was rendering — and pushing — itself again).
  final bool showHeader;

  // Wide enough for a 4-digit total ("1780") or the "Celkem"/"Série" labels
  // at the app's largest text-size setting (1.3×, core/text_size.dart)
  // without wrapping onto a second line (Fix round 1).
  static const _nameWidth = 132.0;
  static const _colWidth = 120.0;
  static const _diffWidth = 64.0;
  static const _sideWidth = _nameWidth + _colWidth * 6;

  MatchPlayerResult? _forSide(String side, int position) {
    for (final p in players) {
      if (p.side == side && p.position == position) return p;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (result == null && players.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);

    final positions = <int>{for (final p in players) p.position}.toList()
      ..sort();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showHeader)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text('Zápis', style: theme.textTheme.titleSmall),
                ),
                IconButton(
                  icon: const Icon(Icons.open_in_full),
                  tooltip: 'Zvětšit',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => LegacyScoreSheetPage(
                        slot: slot,
                        result: result,
                        players: players,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _teamLabelRow(theme),
                _teamSummaryRow(theme),
                if (players.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _columnHeaderRow(theme),
                  for (final (i, pos) in positions.indexed)
                    _pairingBlock(
                      theme,
                      pos,
                      _forSide('home', pos),
                      _forSide('away', pos),
                      tinted: i.isOdd,
                    ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _cell(String text, {TextStyle? style}) => SizedBox(
    width: _colWidth,
    child: Text(
      text,
      textAlign: TextAlign.center,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.visible,
      style: style,
    ),
  );

  Widget _teamLabelSide(ThemeData theme) {
    final style = theme.textTheme.labelSmall?.copyWith(
      fontWeight: FontWeight.bold,
    );
    return SizedBox(
      width: _sideWidth,
      child: Row(
        children: [
          SizedBox(
            width: _nameWidth,
            child: Text('Družstvo', style: style),
          ),
          _cell('Body', style: style),
          _cell('Plné', style: style),
          _cell('Dor.', style: style),
          _cell('Ch.', style: style),
          _cell('Celkem', style: style),
          _cell('Sady', style: style),
        ],
      ),
    );
  }

  /// The team summary's OWN column labels (Fix round 1) — before this, the
  /// summary row's Body/…/Sady cells sat directly under the player column
  /// header's Série/…/Dílčí labels, which don't describe them.
  Widget _teamLabelRow(ThemeData theme) => Row(
    children: [
      _teamLabelSide(theme),
      const SizedBox(width: _diffWidth),
      _teamLabelSide(theme),
    ],
  );

  Widget _teamSummarySide(ThemeData theme, String teamName, bool isHome) {
    final body = isHome ? result?.homePoints : result?.awayPoints;
    final fulls = isHome ? result?.homeFulls : result?.awayFulls;
    final spares = isHome ? result?.homeSpares : result?.awaySpares;
    final errors = isHome ? result?.homeErrors : result?.awayErrors;
    final total = isHome ? result?.homeTotal : result?.awayTotal;
    final setPoints = isHome ? result?.homeSetPoints : result?.awaySetPoints;
    final style = theme.textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w700,
    );
    return SizedBox(
      width: _sideWidth,
      child: Row(
        children: [
          SizedBox(
            width: _nameWidth,
            child: Text(
              teamName,
              style: style,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          _cell(numLabel(body), style: style),
          _cell(numLabel(fulls), style: style),
          _cell(numLabel(spares), style: style),
          _cell(numLabel(errors), style: style),
          _cell(numLabel(total), style: style),
          _cell(numLabel(setPoints), style: style),
        ],
      ),
    );
  }

  Widget _teamSummaryRow(ThemeData theme) {
    final home = result?.homeTotal;
    final away = result?.awayTotal;
    final diff = (home != null && away != null) ? home - away : null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _teamSummarySide(theme, slot.homeTeam, true),
        SizedBox(
          width: _diffWidth,
          child: Center(
            child: Text(
              diff == null ? '' : _signed(diff),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.visible,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        _teamSummarySide(theme, slot.awayTeam, false),
      ],
    );
  }

  Widget _headerSide(ThemeData theme) {
    final style = theme.textTheme.labelSmall?.copyWith(
      fontWeight: FontWeight.bold,
    );
    return SizedBox(
      width: _sideWidth,
      child: Row(
        children: [
          SizedBox(
            width: _nameWidth,
            child: Text('Jméno a příjmení hráče', style: style),
          ),
          _cell('Série', style: style),
          _cell('Plné', style: style),
          _cell('Dor.', style: style),
          _cell('Ch.', style: style),
          _cell('Celkem', style: style),
          _cell('Dílčí', style: style),
        ],
      ),
    );
  }

  Widget _columnHeaderRow(ThemeData theme) {
    final style = theme.textTheme.labelSmall?.copyWith(
      fontWeight: FontWeight.bold,
    );
    return Row(
      children: [
        _headerSide(theme),
        SizedBox(
          width: _diffWidth,
          child: Center(child: Text('Rozdíl', style: style)),
        ),
        _headerSide(theme),
      ],
    );
  }

  Widget _badge(ThemeData theme) => Container(
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
  );

  Widget _playerRow(
    ThemeData theme, {
    required String name,
    required bool showBadge,
    required String seriesLabel,
    required int? fulls,
    required int? spares,
    required int? errors,
    required int? total,
    required num? setPoints,
    bool bold = false,
  }) {
    final style = bold
        ? theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700)
        : theme.textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          SizedBox(
            width: _nameWidth,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    name,
                    style: style,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (showBadge) ...[_badge(theme), const SizedBox(width: 4)],
              ],
            ),
          ),
          _cell(seriesLabel, style: style),
          _cell(numLabel(fulls), style: style),
          _cell(numLabel(spares), style: style),
          _cell(numLabel(errors), style: style),
          _cell(numLabel(total), style: style),
          _cell(numLabel(setPoints), style: style),
        ],
      ),
    );
  }

  Widget _playerMiniBlock(
    ThemeData theme,
    int position,
    MatchPlayerResult player,
  ) {
    final laneCount = player.lanes.length;
    final hasBadge = (player.teamPoints ?? 0) > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, lane) in player.lanes.indexed)
          _playerRow(
            theme,
            name: i == 0 ? '$position. ${player.playerName}' : '',
            showBadge: i == 0 && hasBadge,
            seriesLabel: '${lane.lane}',
            fulls: lane.fulls,
            spares: lane.spares,
            errors: lane.errors,
            total: lane.total,
            setPoints: lane.setPoints,
          ),
        _playerRow(
          theme,
          name: laneCount == 0 ? '$position. ${player.playerName}' : '',
          showBadge: laneCount == 0 && hasBadge,
          seriesLabel: 'Celkem',
          fulls: player.fulls,
          spares: player.spares,
          errors: player.errors,
          total: player.total,
          setPoints: player.setPoints,
          bold: true,
        ),
      ],
    );
  }

  Widget _pairingBlock(
    ThemeData theme,
    int position,
    MatchPlayerResult? home,
    MatchPlayerResult? away, {
    required bool tinted,
  }) {
    final diff = (home?.total != null && away?.total != null)
        ? home!.total! - away!.total!
        : null;
    // A tie (diff == 0) is neutral, not a tertiary "home ahead" tint (Fix
    // round 1 — the old `>= 0` check painted a 0 the same as a real lead).
    final diffColor = diff == null || diff == 0
        ? theme.colorScheme.onSurface
        : diff > 0
        ? theme.colorScheme.tertiary
        : theme.colorScheme.error;
    return Container(
      color: tinted
          ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5)
          : Colors.transparent,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: _sideWidth,
            child: home == null
                ? const SizedBox.shrink()
                : _playerMiniBlock(theme, position, home),
          ),
          SizedBox(
            width: _diffWidth,
            child: Center(
              child: Text(
                diff == null ? '' : _signed(diff),
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.visible,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: diffColor,
                ),
              ),
            ),
          ),
          SizedBox(
            width: _sideWidth,
            child: away == null
                ? const SizedBox.shrink()
                : _playerMiniBlock(theme, position, away),
          ),
        ],
      ),
    );
  }
}

/// "+13" / "-2" / "0" — a signed pin difference; negative values already
/// carry their own minus, so only the positive case needs a prefix.
String _signed(int v) => v > 0 ? '+$v' : '$v';

/// Full-screen "Zápis" route (the "Zvětšit" tap target): the same
/// [LegacyScoreSheet], its own header row suppressed (`showHeader: false`),
/// generously padded, on its own [Scaffold] with a close button. Fix
/// round 1: the body is wrapped in its own vertical scroll view
/// — a big lineup (many pairings, several lanes each) can easily exceed the
/// screen height, and unlike the embedded card (which sits inside
/// `match_detail_screen.dart`'s own `ListView`), this page's `Scaffold` body
/// has no ancestor scroll view of its own to absorb that.
class LegacyScoreSheetPage extends StatelessWidget {
  const LegacyScoreSheetPage({
    super.key,
    required this.slot,
    required this.result,
    required this.players,
  });

  final PrioritySlot slot;
  final MatchResult? result;
  final List<MatchPlayerResult> players;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Zápis'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Zavřít',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: SingleChildScrollView(
          child: LegacyScoreSheet(
            slot: slot,
            result: result,
            players: players,
            showHeader: false,
          ),
        ),
      ),
    );
  }
}

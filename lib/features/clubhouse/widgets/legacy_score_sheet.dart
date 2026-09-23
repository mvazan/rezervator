/// Match detail (Task 4, federation-results-ui): a dense per-pairing score
/// sheet styled like kuzelky.com's old table (team summary + one block per
/// roster position), in the app's own font. Replaces `MatchPlayerSection`'s
/// two ExpansionTile lists.
library;

import 'dart:math' as math;

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
  });

  final PrioritySlot slot;
  final MatchResult? result;
  final List<MatchPlayerResult> players;

  @override
  Widget build(BuildContext context) {
    if (result == null && players.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Row(
            children: [
              Expanded(child: Text('Zápis', style: theme.textTheme.titleSmall)),
              // Nothing to zoom into yet when there's no lineup — just
              // the (already fully visible) team summary row (Fix
              // round 2).
              if (players.isNotEmpty)
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
            child: _ScoreTableBody(
              slot: slot,
              result: result,
              players: players,
            ),
          ),
        ),
      ],
    );
  }
}

/// The actual table — team-column labels, team summary, column header and
/// pairing blocks — shared by the embedded [LegacyScoreSheet] (inside a
/// horizontal [SingleChildScrollView]) and [LegacyScoreSheetPage] (scaled
/// to fit via `_ScaleToFitViewer`, never scrolled). A fixed-size widget by
/// design:
/// every column is a hard-coded width sized for THIS table's own real
/// content at 1.0×, not for arbitrary layout.
///
/// Fix round 2: this table no longer follows the app's accessibility
/// text-size setting (`core/text_size.dart`) — [MediaQuery.withNoTextScaling]
/// pins text scaling off here, the one place both call sites share, so a
/// user's "larger text" choice can't blow the column widths out
/// (that was fix round 1's problem: widening every column enough for 1.3×
/// nearly doubled the table's width). Seeing this table BIGGER is instead
/// what [LegacyScoreSheetPage]'s scale-to-fit view is for.
class _ScoreTableBody extends StatelessWidget {
  const _ScoreTableBody({
    required this.slot,
    required this.result,
    required this.players,
  });

  final PrioritySlot slot;
  final MatchResult? result;
  final List<MatchPlayerResult> players;

  // Measured against the real app font/theme (Manrope via buildTheme, see
  // legacy_score_sheet_test.dart's `widths` group) at 1.0× — this table no
  // longer needs 1.3×/2.0× headroom (see the class doc). Each width is the
  // widest real content that column ever holds, plus a few dp of margin:
  //   _nameWidth: bold team name, e.g. "TJ Slovan Karlovy Vary" (~154dp).
  //   _labelColWidth: the lane/"Celkem" column — bold "Celkem" row label
  //     is its widest content (~52dp), wider than any lane number.
  //   _numColWidth: the 5 plain numeric columns — their own bold "Celkem"
  //     HEADER label (~43dp) is wider than any 4-digit total they hold.
  //   _diffWidth: "Rozdíl" header (~35dp) and a signed diff value.
  static const _nameWidth = 158.0;
  static const _labelColWidth = 58.0;
  static const _numColWidth = 47.0;
  static const _diffWidth = 40.0;
  static const _sideWidth = _nameWidth + _labelColWidth + _numColWidth * 5;

  MatchPlayerResult? _forSide(String side, int position) {
    for (final p in players) {
      if (p.side == side && p.position == position) return p;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final positions = <int>{for (final p in players) p.position}.toList()
      ..sort();

    return MediaQuery.withNoTextScaling(
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
    );
  }

  Widget _numCell(String text, {TextStyle? style}) => SizedBox(
    width: _numColWidth,
    child: Text(
      text,
      textAlign: TextAlign.center,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.visible,
      style: style,
    ),
  );

  Widget _labelCell(String text, {TextStyle? style}) => SizedBox(
    width: _labelColWidth,
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
            child: Text('Družstvo', style: style, maxLines: 1, softWrap: false),
          ),
          _labelCell('Body', style: style),
          _numCell('Plné', style: style),
          _numCell('Dor.', style: style),
          _numCell('Ch.', style: style),
          _numCell('Celkem', style: style),
          _numCell('Sady', style: style),
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
          _labelCell(numLabel(body), style: style),
          _numCell(numLabel(fulls), style: style),
          _numCell(numLabel(spares), style: style),
          _numCell(numLabel(errors), style: style),
          _numCell(numLabel(total), style: style),
          _numCell(numLabel(setPoints), style: style),
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
            child: Text(
              'Jméno a příjmení hráče',
              style: style,
              maxLines: 1,
              softWrap: false,
            ),
          ),
          _labelCell('Série', style: style),
          _numCell('Plné', style: style),
          _numCell('Dor.', style: style),
          _numCell('Ch.', style: style),
          _numCell('Celkem', style: style),
          _numCell('Dílčí', style: style),
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
          child: Center(
            child: Text('Rozdíl', style: style, maxLines: 1, softWrap: false),
          ),
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
          _labelCell(seriesLabel, style: style),
          _numCell(numLabel(fulls), style: style),
          _numCell(numLabel(spares), style: style),
          _numCell(numLabel(errors), style: style),
          _numCell(numLabel(total), style: style),
          _numCell(numLabel(setPoints), style: style),
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

/// Full-screen "Zápis" route (the "Zvětšit" tap target): the same table
/// content as [LegacyScoreSheet] ([_ScoreTableBody]), scaled to fit on
/// open — never scrolled, in either axis — via [_ScaleToFitViewer]. Fix
/// round 2: this replaces fix round 1's vertical [SingleChildScrollView]
/// (added because widening every column for 1.3× text scale nearly doubled
/// the table's width and made a big lineup overflow vertically too). Fix
/// round 3: a plain [FittedBox] (round 2's own fix) shrinks the WHOLE table
/// down to fit a phone screen and caps out at 1.0× on a wide one — on an
/// ordinary phone, where the table is legitimately wider/taller than the
/// screen, that shrinks real body text down to a few px with no way back to
/// a readable size. [_ScaleToFitViewer] keeps the same initial "see it all
/// at once" scale, but lets the user pinch in from there to read the
/// detail and pan around.
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
        child: _ScaleToFitViewer(
          child: _ScoreTableBody(slot: slot, result: result, players: players),
        ),
      ),
    );
  }
}

/// Scales [child] to fit the available space on first layout — same "see
/// the whole table at once" goal a plain [FittedBox] gives — but, unlike
/// [FittedBox], lets the user then pinch past that initial scale to read
/// the detail and pan around. [InteractiveViewer] has no scrollbar chrome
/// of its own — it's a direct-manipulation gesture surface, not a
/// scrollable — so "no scrollbars anywhere on this page" still holds.
///
/// [child] is measured once via [_contentKey] after its first layout (its
/// own [RenderBox.size] is unaffected by [InteractiveViewer]'s pan/zoom
/// [Transform], which only changes how it's painted, not its layout size),
/// against the [LayoutBuilder] constraints this sits in — [minScale] is set
/// to exactly that fit scale, so the page never opens more zoomed-in than
/// "see it all at once", but [maxScale] leaves room to pinch in several
/// times past that for readability.
class _ScaleToFitViewer extends StatefulWidget {
  const _ScaleToFitViewer({required this.child});

  final Widget child;

  @override
  State<_ScaleToFitViewer> createState() => _ScaleToFitViewerState();
}

class _ScaleToFitViewerState extends State<_ScaleToFitViewer> {
  final _contentKey = GlobalKey();
  final _controller = TransformationController();

  /// Never lets a huge lineup shrink to the point of being useless, and is
  /// this state's own fallback before the first real measurement lands.
  static const _minFitScale = 0.15;
  double _minScale = 1.0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _fitToScreen(BoxConstraints constraints) {
    final renderBox =
        _contentKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) return;
    final size = renderBox.size;
    if (size.width <= 0 || size.height <= 0) return;
    // Only a floor, deliberately no ceiling: on a screen wider/taller than
    // the table's own natural size (a desktop window), this scales UP past
    // 1.0 to fill it — the plain `FittedBox` this replaces capped at 1.0
    // and left the table small in the middle of the screen there.
    final fit = math.max(
      math.min(
        constraints.maxWidth / size.width,
        constraints.maxHeight / size.height,
      ),
      _minFitScale,
    );
    if ((fit - _minScale).abs() < 0.001) return;
    setState(() {
      _minScale = fit;
      _controller.value = Matrix4.diagonal3Values(fit, fit, 1.0);
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Deferred to right after this frame's own layout — `renderBox`
        // above needs `child`'s size, which isn't known during `build`.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _fitToScreen(constraints);
        });
        return InteractiveViewer(
          transformationController: _controller,
          constrained: false,
          minScale: _minScale,
          maxScale: math.max(_minScale * 4, 3.0),
          child: KeyedSubtree(key: _contentKey, child: widget.child),
        );
      },
    );
  }
}

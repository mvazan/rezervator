/// Match detail (Task 4, federation-results-ui): a dense per-pairing score
/// sheet, styled as a 1:1 replica of kuzelky.com's own `table#tabzap`
/// (colours, sizes, weights, widths, row heights — see
/// `.superpowers/sdd/legacy-sheet-styles-brief.md`), except the typeface
/// (kept as the app's own Manrope, never the reference site's). Replaces
/// `MatchPlayerSection`'s two ExpansionTile lists.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme.dart' show appFontFamily;
import '../../../domain/models.dart';
import '../../../domain/results.dart';

// kuzelky.com's own fixed sheet colours (measured via getComputedStyle on a
// real match page) — a literal replica, not app theming. Never route these
// through app_theme/SurfaceColors or adapt them to dark mode: the
// reference sheet is always light, black-on-colour (Fix round 4).
const _kBorder = Color(0xFF111111);
const _kHeaderGrey = Color(0xFFCCCCCC);
const _kBodyYellow = Color(0xFFFDFDEC);
const _kStatsPurple = Color(0xFFF4E4FC);
const _kDruzstvoBlue = Color(0xFFADD8E6);
const _kNameCellGrey = Color(0xFFF0F0F0);
const _kLaneStatsGreen = Color(0xFFEEFFEC);
const _kRegCellBlue = Color(0xFFCDE9FF);
const _kPositiveGreen = Color(0xFF008000);
const _kNegativeRed = Color(0xFFFF0000);
const _kCelkemTotalRed = Color(0xFF8B0000);
const _kBlack = Color(0xFF000000);
const _kWhite = Color(0xFFFFFFFF);

/// One pairing block per position (1..N): the home and away player who
/// faced each other, each with a line per lane thrown plus a Celkem total,
/// and the pin difference between them. Above the blocks, a team summary
/// row and two column-header rows, mirrored for both sides.
///
/// Returns `SizedBox.shrink()` only when there is truly nothing to show
/// ([result] null AND [players] empty). When [result] carries team-level
/// data but [players] is empty (lineup not synced yet), the team summary
/// still renders — the caller (`match_detail_screen.dart`) still owns the
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

/// The actual table — a 1:1 replica of kuzelky.com's own `table#tabzap`
/// grid, shared by the embedded [LegacyScoreSheet] (inside a horizontal
/// [SingleChildScrollView]) and [LegacyScoreSheetPage] (scaled to fit via
/// `_ScaleToFitViewer`, never scrolled). Every column and row is a
/// hard-coded dp value copied from the reference site, not derived from
/// the app's theme — see `.superpowers/sdd/legacy-sheet-styles-brief.md`.
///
/// Built from plain bordered [Container]s (not [Table], which has no
/// rowspan) — the player name, "Družstvo" (team points) and "Rozdíl"
/// cells each span several rows by being ONE tall [Container] rather than
/// several stacked ones, which is what actually reproduces the reference
/// site's rowspan cells here (no internal seam for that cell, since it's
/// a single shape). Fix round 2: this table no longer follows the app's
/// accessibility text-size setting (`core/text_size.dart`) —
/// [MediaQuery.withNoTextScaling] pins text scaling off here, the one
/// place both call sites share.
class _ScoreTableBody extends StatelessWidget {
  const _ScoreTableBody({
    required this.slot,
    required this.result,
    required this.players,
  });

  final PrioritySlot slot;
  final MatchResult? result;
  final List<MatchPlayerResult> players;

  // Column widths (dp), copied 1:1 from kuzelky.com's own table (home and
  // away differ by a dp or two on a few columns — the reference site's own
  // layout, not a rounding choice made here).
  static const _nameWidthHome = 144.0;
  static const _nameWidthAway = 143.0;
  static const _serieWidth = 42.0;
  static const _plneWidth = 55.0;
  static const _dorWidth = 46.0;
  static const _chWidthHome = 33.0;
  static const _chWidthAway = 30.0;
  static const _celkemColWidth = 58.0;
  static const _dilciWidth = 31.0;
  static const _druzstvoWidthHome = 51.0;
  static const _druzstvoWidthAway = 52.0;
  static const _rozdilWidth = 46.0;

  static const _sideWidthHome =
      _nameWidthHome +
      _serieWidth +
      _plneWidth +
      _dorWidth +
      _chWidthHome +
      _celkemColWidth +
      _dilciWidth +
      _druzstvoWidthHome;
  static const _sideWidthAway =
      _nameWidthAway +
      _serieWidth +
      _plneWidth +
      _dorWidth +
      _chWidthAway +
      _celkemColWidth +
      _dilciWidth +
      _druzstvoWidthAway;

  /// The table's total natural width (dp) — ≈963, matching the reference
  /// site. Used for the full-width separator row between pairing blocks.
  static const totalWidth = _sideWidthHome + _rozdilWidth + _sideWidthAway;

  // Row heights (dp), also copied 1:1.
  static const _teamRowHeight = 43.0;
  static const _headerRowHeight = 23.0;
  static const _laneRowHeight = 23.0;
  static const _celkemRowHeight = 31.0;
  static const _separatorHeight = 9.0;

  MatchPlayerResult? _forSide(String side, int position) {
    for (final p in players) {
      if (p.side == side && p.position == position) return p;
    }
    return null;
  }

  /// Team-level "Družstvo" column (Fix round 4): the total match/team
  /// points this side's players individually earned — summed from each
  /// [MatchPlayerResult.teamPoints], not a separate stat `MatchResult`
  /// carries on its own.
  num _teamPointsSum(String side) {
    num sum = 0;
    for (final p in players) {
      if (p.side == side) sum += p.teamPoints ?? 0;
    }
    return sum;
  }

  @override
  Widget build(BuildContext context) {
    final positions = <int>{for (final p in players) p.position}.toList()
      ..sort();

    return MediaQuery.withNoTextScaling(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _teamSummaryRow(),
          if (players.isNotEmpty) ...[
            _headerRows(),
            for (final (i, pos) in positions.indexed) ...[
              _pairingBlock(pos, _forSide('home', pos), _forSide('away', pos)),
              if (i != positions.length - 1) _separatorRow(),
            ],
          ],
        ],
      ),
    );
  }

  // ---- low-level cell ----

  Color _diffColor(int? diff) {
    if (diff == null || diff == 0) return _kBlack;
    return diff > 0 ? _kPositiveGreen : _kNegativeRed;
  }

  Widget _cell({
    required double width,
    required double height,
    required Color bg,
    required String text,
    required double fontSize,
    required FontWeight weight,
    Color color = _kBlack,
    TextAlign align = TextAlign.center,
    int maxLines = 1,
  }) {
    return Container(
      width: width,
      height: height,
      padding: const EdgeInsets.all(4),
      alignment: align == TextAlign.left
          ? Alignment.centerLeft
          : Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: _kBorder, width: 1),
      ),
      child: Text(
        text,
        textAlign: align,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFamily: appFontFamily,
          fontSize: fontSize,
          fontWeight: weight,
          color: color,
          height: 1.0,
        ),
      ),
    );
  }

  // ---- row 0: team summary ----

  Widget _teamSummarySide(String teamName, bool isHome) {
    final body = isHome ? result?.homePoints : result?.awayPoints;
    final fulls = isHome ? result?.homeFulls : result?.awayFulls;
    final spares = isHome ? result?.homeSpares : result?.awaySpares;
    final errors = isHome ? result?.homeErrors : result?.awayErrors;
    final total = isHome ? result?.homeTotal : result?.awayTotal;
    final setPoints = isHome ? result?.homeSetPoints : result?.awaySetPoints;
    final nameWidth = isHome ? _nameWidthHome : _nameWidthAway;
    final chWidth = isHome ? _chWidthHome : _chWidthAway;
    final druzstvoWidth = isHome ? _druzstvoWidthHome : _druzstvoWidthAway;

    return Row(
      children: [
        _cell(
          width: nameWidth,
          height: _teamRowHeight,
          bg: _kHeaderGrey,
          text: teamName,
          fontSize: 16,
          weight: FontWeight.w700,
          maxLines: 2,
        ),
        _cell(
          width: _serieWidth,
          height: _teamRowHeight,
          bg: _kBodyYellow,
          text: numLabel(body),
          fontSize: 24,
          weight: FontWeight.w700,
        ),
        _cell(
          width: _plneWidth,
          height: _teamRowHeight,
          bg: _kStatsPurple,
          text: numLabel(fulls),
          fontSize: 20,
          weight: FontWeight.w400,
        ),
        _cell(
          width: _dorWidth,
          height: _teamRowHeight,
          bg: _kStatsPurple,
          text: numLabel(spares),
          fontSize: 20,
          weight: FontWeight.w400,
        ),
        _cell(
          width: chWidth,
          height: _teamRowHeight,
          bg: _kStatsPurple,
          text: numLabel(errors),
          fontSize: 20,
          weight: FontWeight.w400,
        ),
        _cell(
          width: _celkemColWidth,
          height: _teamRowHeight,
          bg: _kStatsPurple,
          text: numLabel(total),
          fontSize: 20,
          weight: FontWeight.w700,
        ),
        _cell(
          width: _dilciWidth,
          height: _teamRowHeight,
          bg: _kStatsPurple,
          text: numLabel(setPoints),
          fontSize: 20,
          weight: FontWeight.w400,
        ),
        _cell(
          width: druzstvoWidth,
          height: _teamRowHeight,
          bg: _kDruzstvoBlue,
          text: numLabel(_teamPointsSum(isHome ? 'home' : 'away')),
          fontSize: 20,
          weight: FontWeight.w700,
        ),
      ],
    );
  }

  Widget _teamSummaryRow() {
    final home = result?.homeTotal;
    final away = result?.awayTotal;
    final diff = (home != null && away != null) ? home - away : null;
    return Row(
      children: [
        _teamSummarySide(slot.homeTeam, true),
        _cell(
          width: _rozdilWidth,
          height: _teamRowHeight,
          bg: _kBodyYellow,
          text: diff == null ? '' : _signed(diff),
          fontSize: 20,
          weight: FontWeight.w700,
          color: _diffColor(diff),
        ),
        _teamSummarySide(slot.awayTeam, false),
      ],
    );
  }

  // ---- rows 1–2: column headers ----

  Widget _headerCell(
    double width,
    double height,
    String text, {
    TextAlign align = TextAlign.center,
  }) => _cell(
    width: width,
    height: height,
    bg: _kHeaderGrey,
    text: text,
    fontSize: 10,
    weight: FontWeight.w400,
    align: align,
    maxLines: 2,
  );

  Widget _headerColumn(bool isHome) {
    final nameWidth = isHome ? _nameWidthHome : _nameWidthAway;
    final chWidth = isHome ? _chWidthHome : _chWidthAway;
    final druzstvoWidth = isHome ? _druzstvoWidthHome : _druzstvoWidthAway;
    final vykonWidth =
        _plneWidth + _dorWidth + chWidth + _celkemColWidth + _dilciWidth;

    return Row(
      children: [
        Column(
          children: [
            _headerCell(
              nameWidth,
              _headerRowHeight,
              'Jméno a příjmení hráče',
              align: TextAlign.left,
            ),
            _headerCell(
              nameWidth,
              _headerRowHeight,
              'Registrační číslo',
              align: TextAlign.left,
            ),
          ],
        ),
        _headerCell(_serieWidth, _headerRowHeight * 2, 'Série hodů'),
        Column(
          children: [
            _headerCell(vykonWidth, _headerRowHeight, 'Výkon'),
            Row(
              children: [
                _headerCell(_plneWidth, _headerRowHeight, 'Plné'),
                _headerCell(_dorWidth, _headerRowHeight, 'Dor.'),
                _headerCell(chWidth, _headerRowHeight, 'Ch.'),
                _headerCell(_celkemColWidth, _headerRowHeight, 'Celkem'),
                _headerCell(_dilciWidth, _headerRowHeight, 'Dílčí'),
              ],
            ),
          ],
        ),
        Column(
          children: [
            _headerCell(druzstvoWidth, _headerRowHeight, 'Body'),
            _headerCell(druzstvoWidth, _headerRowHeight, 'Družstvo'),
          ],
        ),
      ],
    );
  }

  Widget _headerRows() {
    return Row(
      children: [
        _headerColumn(true),
        _headerCell(_rozdilWidth, _headerRowHeight * 2, 'Rozdíl'),
        _headerColumn(false),
      ],
    );
  }

  // ---- pairing blocks ----

  Widget _pairingSide(int position, MatchPlayerResult? player, bool isHome) {
    final nameWidth = isHome ? _nameWidthHome : _nameWidthAway;
    final chWidth = isHome ? _chWidthHome : _chWidthAway;
    final druzstvoWidth = isHome ? _druzstvoWidthHome : _druzstvoWidthAway;

    if (player == null) {
      // Ragged data (a position only the other side fielded): a single
      // blank cell keeps this side from collapsing to zero width, without
      // crashing or fabricating a player (spec carried over from the
      // original task).
      final width =
          nameWidth +
          _serieWidth +
          _plneWidth +
          _dorWidth +
          chWidth +
          _celkemColWidth +
          _dilciWidth +
          druzstvoWidth;
      return _cell(
        width: width,
        height: _celkemRowHeight,
        bg: _kWhite,
        text: '',
        fontSize: 10,
        weight: FontWeight.w400,
      );
    }

    final laneCount = player.lanes.length;
    // A live match with no lane data yet: the "registrační číslo" slot
    // (which we never have real data for) shows the player's name instead
    // of going fully blank, so the identity isn't lost entirely (Fix
    // round 4 design call — the reference site always has lanes by the
    // time a sheet exists).
    final hasLanes = laneCount > 0;
    final blockHeight = laneCount * _laneRowHeight + _celkemRowHeight;
    final nameText = '$position. ${player.playerName}';

    Widget laneRow(PlayerLane lane) => Row(
      children: [
        _cell(
          width: _serieWidth,
          height: _laneRowHeight,
          bg: _kBodyYellow,
          text: '${lane.lane}',
          fontSize: 10,
          weight: FontWeight.w400,
        ),
        _cell(
          width: _plneWidth,
          height: _laneRowHeight,
          bg: _kLaneStatsGreen,
          text: numLabel(lane.fulls),
          fontSize: 10,
          weight: FontWeight.w400,
        ),
        _cell(
          width: _dorWidth,
          height: _laneRowHeight,
          bg: _kLaneStatsGreen,
          text: numLabel(lane.spares),
          fontSize: 10,
          weight: FontWeight.w400,
        ),
        _cell(
          width: chWidth,
          height: _laneRowHeight,
          bg: _kLaneStatsGreen,
          text: numLabel(lane.errors),
          fontSize: 10,
          weight: FontWeight.w400,
        ),
        _cell(
          width: _celkemColWidth,
          height: _laneRowHeight,
          bg: _kStatsPurple,
          text: numLabel(lane.total),
          fontSize: 10,
          weight: FontWeight.w400,
        ),
        _cell(
          width: _dilciWidth,
          height: _laneRowHeight,
          bg: _kStatsPurple,
          text: numLabel(lane.setPoints),
          fontSize: 10,
          weight: FontWeight.w400,
        ),
      ],
    );

    final celkemRow = Row(
      children: [
        _cell(
          width: _serieWidth,
          height: _celkemRowHeight,
          bg: _kStatsPurple,
          text: 'Celkem',
          fontSize: 10,
          weight: FontWeight.w700,
        ),
        _cell(
          width: _plneWidth,
          height: _celkemRowHeight,
          bg: _kStatsPurple,
          text: numLabel(player.fulls),
          fontSize: 10,
          weight: FontWeight.w700,
        ),
        _cell(
          width: _dorWidth,
          height: _celkemRowHeight,
          bg: _kStatsPurple,
          text: numLabel(player.spares),
          fontSize: 10,
          weight: FontWeight.w700,
        ),
        _cell(
          width: chWidth,
          height: _celkemRowHeight,
          bg: _kStatsPurple,
          text: numLabel(player.errors),
          fontSize: 10,
          weight: FontWeight.w700,
        ),
        _cell(
          width: _celkemColWidth,
          height: _celkemRowHeight,
          bg: _kRegCellBlue,
          text: numLabel(player.total),
          fontSize: 16,
          weight: FontWeight.w700,
          color: _kCelkemTotalRed,
        ),
        _cell(
          width: _dilciWidth,
          height: _celkemRowHeight,
          bg: _kRegCellBlue,
          text: numLabel(player.setPoints),
          fontSize: 10,
          weight: FontWeight.w400,
        ),
      ],
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            if (hasLanes)
              _cell(
                width: nameWidth,
                height: laneCount * _laneRowHeight,
                bg: _kNameCellGrey,
                text: nameText,
                fontSize: 16,
                weight: FontWeight.w700,
                align: TextAlign.left,
                maxLines: 2,
              ),
            _cell(
              width: nameWidth,
              height: _celkemRowHeight,
              bg: _kRegCellBlue,
              text: hasLanes ? '' : nameText,
              fontSize: 16,
              weight: FontWeight.w700,
              align: TextAlign.left,
              maxLines: hasLanes ? 1 : 2,
            ),
          ],
        ),
        Column(
          children: [for (final lane in player.lanes) laneRow(lane), celkemRow],
        ),
        _cell(
          width: druzstvoWidth,
          height: blockHeight,
          bg: _kDruzstvoBlue,
          text: numLabel(player.teamPoints),
          fontSize: 20,
          weight: FontWeight.w700,
        ),
      ],
    );
  }

  Widget _pairingBlock(
    int position,
    MatchPlayerResult? home,
    MatchPlayerResult? away,
  ) {
    final diff = (home?.total != null && away?.total != null)
        ? home!.total! - away!.total!
        : null;
    final homeLanes = home?.lanes.length ?? 0;
    final awayLanes = away?.lanes.length ?? 0;
    final blockHeight =
        math.max(homeLanes, awayLanes) * _laneRowHeight + _celkemRowHeight;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _pairingSide(position, home, true),
        _cell(
          width: _rozdilWidth,
          height: blockHeight,
          bg: _kBodyYellow,
          text: diff == null ? '' : _signed(diff),
          fontSize: 16,
          weight: FontWeight.w400,
          color: _diffColor(diff),
        ),
        _pairingSide(position, away, false),
      ],
    );
  }

  Widget _separatorRow() => _cell(
    width: totalWidth,
    height: _separatorHeight,
    bg: _kWhite,
    text: '',
    fontSize: 10,
    weight: FontWeight.w400,
  );
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

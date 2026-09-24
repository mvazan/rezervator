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

// Every text role this table ever renders, as ONE shared constant each —
// used both to actually draw a cell and, in [_ColumnMetrics.compute], to
// MEASURE how wide that cell's content needs to be. Using the exact same
// `TextStyle` object for both is what keeps the measurement honest (Fix
// round 5): a mismatched style there was exactly how round 4 shipped
// columns real Manrope ellipsized into ("22…" instead of "2280").
const _s10w400 = TextStyle(
  fontFamily: appFontFamily,
  fontSize: 10,
  fontWeight: FontWeight.w400,
  height: 1.0,
  letterSpacing: 0,
);
const _s10w700 = TextStyle(
  fontFamily: appFontFamily,
  fontSize: 10,
  fontWeight: FontWeight.w700,
  height: 1.0,
  letterSpacing: 0,
);
const _s16w400 = TextStyle(
  fontFamily: appFontFamily,
  fontSize: 16,
  fontWeight: FontWeight.w400,
  height: 1.0,
  letterSpacing: 0,
);
const _s16w700 = TextStyle(
  fontFamily: appFontFamily,
  fontSize: 16,
  fontWeight: FontWeight.w700,
  height: 1.0,
  letterSpacing: 0,
);
const _s20w400 = TextStyle(
  fontFamily: appFontFamily,
  fontSize: 20,
  fontWeight: FontWeight.w400,
  height: 1.0,
  letterSpacing: 0,
);
const _s20w700 = TextStyle(
  fontFamily: appFontFamily,
  fontSize: 20,
  fontWeight: FontWeight.w700,
  height: 1.0,
  letterSpacing: 0,
);
const _s24w700 = TextStyle(
  fontFamily: appFontFamily,
  fontSize: 24,
  fontWeight: FontWeight.w700,
  height: 1.0,
  letterSpacing: 0,
);

/// "+13" / "-2" / "0" — a signed pin difference; negative values already
/// carry their own minus, so only the positive case needs a prefix.
String _signed(int v) => v > 0 ? '+$v' : '$v';

/// The team-row "Družstvo" value: the points [side] got for the higher pin
/// total (2 / 0, 1 / 1 on a tie) — kuzelky prints its Body ([sidePoints])
/// minus the duel points its players won. Null (printed '–') until Body and
/// every player's [MatchPlayerResult.teamPoints] of that side are known.
num? _teamBonusPoints(
  num? sidePoints,
  List<MatchPlayerResult> players,
  String side,
) {
  if (sidePoints == null) return null;
  num duels = 0;
  var any = false;
  for (final p in players) {
    if (p.side != side) continue;
    final points = p.teamPoints;
    if (points == null) return null;
    duels += points;
    any = true;
  }
  return any ? sidePoints - duels : null;
}

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

/// Every column's width, computed once per render from the table's actual
/// content (Fix round 5) — kuzelky uses `table-layout: auto`, so its
/// columns grow to fit whatever they hold; the brief's own widths are
/// MINIMUMS, not fixed sizes. A column's width is `max(brief minimum,
/// widest content that column ever holds + 9dp)` — 9dp because [_cell]'s
/// own padding (4+4) plus its 1px border account for exactly that much
/// beyond a glyph run's raw measured width. Mirror columns (the same
/// column on the home and away side) share ONE width — the wider side's
/// requirement — so the table stays visually symmetric, the same way a
/// real HTML `<col>` would if both sides sat in the same `<colgroup>`.
class _ColumnMetrics {
  const _ColumnMetrics({
    required this.nameWidth,
    required this.serieWidth,
    required this.plneWidth,
    required this.dorWidth,
    required this.chWidth,
    required this.celkemColWidth,
    required this.dilciWidth,
    required this.druzstvoWidth,
    required this.rozdilWidth,
  });

  final double nameWidth;
  final double serieWidth;
  final double plneWidth;
  final double dorWidth;
  final double chWidth;
  final double celkemColWidth;
  final double dilciWidth;
  final double druzstvoWidth;
  final double rozdilWidth;

  double get sideWidth =>
      nameWidth +
      serieWidth +
      plneWidth +
      dorWidth +
      chWidth +
      celkemColWidth +
      dilciWidth +
      druzstvoWidth;

  double get totalWidth => sideWidth * 2 + rozdilWidth;

  /// [_cell]'s own horizontal padding (4+4) + its 1px border.
  static const _cellChrome = 9.0;

  static double _measure(String text, TextStyle style) {
    if (text.isEmpty) return 0;
    // Deliberately NO `maxLines` here: combined with an unconstrained
    // (infinite) layout width, it measures something other than the
    // text's true natural single-line width — the discrepancy this
    // caused (a real string this app renders came back ~4.5dp too
    // narrow) is exactly what made round 4's own ellipsis bug possible
    // despite an earlier, similar-looking width check (Fix round 5). A
    // single line with no explicit newline never needs to wrap anyway
    // when given infinite width, so `maxLines` adds nothing here.
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
      textWidthBasis: TextWidthBasis.longestLine,
    )..layout();
    return painter.width;
  }

  static double _widest(Iterable<(String, TextStyle)> cells, double min) {
    var widest = min;
    for (final (text, style) in cells) {
      final needed = _measure(text, style) + _cellChrome;
      if (needed > widest) widest = needed;
    }
    // Rounded UP to a whole px: every cell edge then lands on an integer
    // device pixel (at the common 1.0 pixel ratio), which is what keeps
    // the 1px/2px border grid crisp instead of anti-aliased/blurred across
    // 2 pixels at a fractional boundary (Fix round 5).
    return widest.ceilToDouble();
  }

  factory _ColumnMetrics.compute({
    required PrioritySlot slot,
    required MatchResult? result,
    required List<MatchPlayerResult> players,
  }) {
    final positions = <int>{for (final p in players) p.position}.toList();
    MatchPlayerResult? forSide(String side, int position) {
      for (final p in players) {
        if (p.side == side && p.position == position) return p;
      }
      return null;
    }

    final nameWidth = _widest([
      ('Jméno a příjmení hráče', _s10w400),
      ('Registrační číslo', _s10w400),
      (slot.homeTeam, _s16w700),
      (slot.awayTeam, _s16w700),
      for (final p in players) (p.playerName, _s16w700),
    ], 144.0);

    // Deliberately EXCLUDES "Série hodů" — it's the one header allowed to
    // wrap onto its own 2-row-tall cell (Fix round 5, item 3), so it must
    // not force this column wide enough for a single line.
    final serieWidth = _widest([
      (numLabel(result?.homePoints), _s24w700),
      (numLabel(result?.awayPoints), _s24w700),
      ('Celkem', _s10w700),
      for (final p in players)
        for (final lane in p.lanes) ('${lane.lane}', _s10w400),
    ], 42.0);

    final plneWidth = _widest([
      ('Plné', _s10w400),
      (numLabel(result?.homeFulls), _s20w400),
      (numLabel(result?.awayFulls), _s20w400),
      for (final p in players) (numLabel(p.fulls), _s10w700),
      for (final p in players)
        for (final lane in p.lanes) (numLabel(lane.fulls), _s10w400),
    ], 55.0);

    final dorWidth = _widest([
      ('Dor.', _s10w400),
      (numLabel(result?.homeSpares), _s20w400),
      (numLabel(result?.awaySpares), _s20w400),
      for (final p in players) (numLabel(p.spares), _s10w700),
      for (final p in players)
        for (final lane in p.lanes) (numLabel(lane.spares), _s10w400),
    ], 46.0);

    final chWidth = _widest([
      ('Ch.', _s10w400),
      (numLabel(result?.homeErrors), _s20w400),
      (numLabel(result?.awayErrors), _s20w400),
      for (final p in players) (numLabel(p.errors), _s10w700),
      for (final p in players)
        for (final lane in p.lanes) (numLabel(lane.errors), _s10w400),
    ], 33.0);

    final celkemColWidth = _widest([
      ('Celkem', _s10w400),
      (numLabel(result?.homeTotal), _s20w700),
      (numLabel(result?.awayTotal), _s20w700),
      for (final p in players) (numLabel(p.total), _s16w700),
      for (final p in players)
        for (final lane in p.lanes) (numLabel(lane.total), _s10w400),
    ], 58.0);

    final dilciWidth = _widest([
      ('Dílčí', _s10w400),
      (numLabel(result?.homeSetPoints), _s20w400),
      (numLabel(result?.awaySetPoints), _s20w400),
      for (final p in players) (numLabel(p.setPoints), _s10w400),
      for (final p in players)
        for (final lane in p.lanes) (numLabel(lane.setPoints), _s10w400),
    ], 31.0);

    final druzstvoWidth = _widest([
      ('Body', _s10w400),
      ('Družstvo', _s10w400),
      (
        numLabel(_teamBonusPoints(result?.homePoints, players, 'home')),
        _s20w700,
      ),
      (
        numLabel(_teamBonusPoints(result?.awayPoints, players, 'away')),
        _s20w700,
      ),
      for (final p in players) (numLabel(p.teamPoints), _s20w700),
    ], 51.0);

    final rozdilCells = <(String, TextStyle)>[('Rozdíl', _s10w400)];
    final home = result?.homeTotal;
    final away = result?.awayTotal;
    if (home != null && away != null) {
      rozdilCells.add((_signed(home - away), _s20w700));
    }
    for (final pos in positions) {
      final h = forSide('home', pos);
      final a = forSide('away', pos);
      if (h?.total != null && a?.total != null) {
        rozdilCells.add((_signed(h!.total! - a!.total!), _s16w400));
      }
    }
    final rozdilWidth = _widest(rozdilCells, 46.0);

    return _ColumnMetrics(
      nameWidth: nameWidth,
      serieWidth: serieWidth,
      plneWidth: plneWidth,
      dorWidth: dorWidth,
      chWidth: chWidth,
      celkemColWidth: celkemColWidth,
      dilciWidth: dilciWidth,
      druzstvoWidth: druzstvoWidth,
      rozdilWidth: rozdilWidth,
    );
  }
}

/// The actual table — a 1:1 replica of kuzelky.com's own `table#tabzap`
/// grid, shared by the embedded [LegacyScoreSheet] (inside a horizontal
/// [SingleChildScrollView]) and [LegacyScoreSheetPage] (scaled to fit via
/// `_ScaleToFitViewer`, never scrolled). Row heights are hard-coded dp
/// values copied from the reference site; column widths are computed per
/// render by [_ColumnMetrics] (Fix round 5 — see its own doc comment).
///
/// Built from plain [Container]s (not [Table], which has no rowspan) — the
/// player name, "Družstvo" (team points) and "Rozdíl" cells each span
/// several rows by being ONE tall [Container] rather than several stacked
/// ones. Fix round 5: every cell paints only its RIGHT and BOTTOM 1px
/// border — kuzelky's own grid is a 2px OUTER frame with 1px collapsed
/// seams inside, the opposite of "every cell draws all 4 sides" (which
/// doubles every internal seam to 2px and leaves the outer frame at only
/// 1px). The 2px outer frame itself comes from the `Container` this
/// widget returns, via `foregroundDecoration` — see [build]. Fix round 2:
/// this table no longer follows the app's accessibility text-size setting
/// (`core/text_size.dart`) — [build] pins text scaling off here, the one
/// place both call sites share, and the platform's Bold text setting too:
/// [Text] would render every cell bolder than [_ColumnMetrics] measured it.
class _ScoreTableBody extends StatelessWidget {
  const _ScoreTableBody({
    required this.slot,
    required this.result,
    required this.players,
  });

  final PrioritySlot slot;
  final MatchResult? result;
  final List<MatchPlayerResult> players;

  // Row heights (dp), copied 1:1 from kuzelky.com's own table.
  static const _teamRowHeight = 43.0;
  static const _headerRowHeight = 23.0;
  static const _laneRowHeight = 23.0;
  static const _celkemRowHeight = 31.0;
  static const _separatorHeight = 9.0;

  /// The outer 2px border frame's own [padding] (`fromLTRB(2, 2, 1, 1)`),
  /// added to a content size to get this widget's actual rendered size.
  static const _frameWidth = 3.0; // left 2 + right 1
  static const _frameHeight = 3.0; // top 2 + bottom 1

  MatchPlayerResult? _forSide(String side, int position) {
    for (final p in players) {
      if (p.side == side && p.position == position) return p;
    }
    return null;
  }

  /// This table's real rendered size, computed WITHOUT building it —
  /// [_ColumnMetrics.compute] and the row-height arithmetic below are both
  /// pure functions of [slot]/[result]/[players], so [LegacyScoreSheetPage]
  /// can know the exact size to scale-to-fit synchronously, on the very
  /// first frame (Fix round 5, item 7 — no more measure-then-correct
  /// post-frame callback).
  static Size naturalSize({
    required PrioritySlot slot,
    required MatchResult? result,
    required List<MatchPlayerResult> players,
  }) {
    final metrics = _ColumnMetrics.compute(
      slot: slot,
      result: result,
      players: players,
    );
    var height = _teamRowHeight;
    if (players.isNotEmpty) {
      height += _headerRowHeight * 2;
      final positions = <int>{for (final p in players) p.position}.toList()
        ..sort();
      for (final (i, pos) in positions.indexed) {
        int laneCountFor(String side) {
          for (final p in players) {
            if (p.side == side && p.position == pos) return p.lanes.length;
          }
          return 0;
        }

        final laneRowCount = math.max(
          laneCountFor('home'),
          laneCountFor('away'),
        );
        height += laneRowCount * _laneRowHeight + _celkemRowHeight;
        if (i != positions.length - 1) height += _separatorHeight;
      }
    }
    return Size(metrics.totalWidth + _frameWidth, height + _frameHeight);
  }

  @override
  Widget build(BuildContext context) {
    final metrics = _ColumnMetrics.compute(
      slot: slot,
      result: result,
      players: players,
    );
    final positions = <int>{for (final p in players) p.position}.toList()
      ..sort();

    return MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.noScaling, boldText: false),
      child: Container(
        // The 2px OUTER frame (Fix round 5) — every cell only paints its
        // own right/bottom 1px edge, so this is the table's only top/left
        // border and its only "thick" edge anywhere. `foregroundDecoration`
        // paints on top of the padded content rather than behind it, which
        // is what keeps the border crisp at the very outer boundary.
        padding: const EdgeInsets.fromLTRB(2, 2, 1, 1),
        foregroundDecoration: const BoxDecoration(
          border: Border.fromBorderSide(BorderSide(color: _kBorder, width: 2)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _teamSummaryRow(metrics),
            if (players.isNotEmpty) ...[
              _headerRows(metrics),
              for (final (i, pos) in positions.indexed) ...[
                _pairingBlock(
                  metrics,
                  _forSide('home', pos),
                  _forSide('away', pos),
                ),
                if (i != positions.length - 1) _separatorRow(metrics),
              ],
            ],
          ],
        ),
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
    required TextStyle style,
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
        border: const Border(
          right: BorderSide(color: _kBorder, width: 1),
          bottom: BorderSide(color: _kBorder, width: 1),
        ),
      ),
      child: Text(
        text,
        textAlign: align,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: style.copyWith(color: color),
      ),
    );
  }

  // ---- row 0: team summary ----

  Widget _teamSummarySide(_ColumnMetrics m, String teamName, bool isHome) {
    final body = isHome ? result?.homePoints : result?.awayPoints;
    final fulls = isHome ? result?.homeFulls : result?.awayFulls;
    final spares = isHome ? result?.homeSpares : result?.awaySpares;
    final errors = isHome ? result?.homeErrors : result?.awayErrors;
    final total = isHome ? result?.homeTotal : result?.awayTotal;
    final setPoints = isHome ? result?.homeSetPoints : result?.awaySetPoints;

    return Row(
      children: [
        _cell(
          width: m.nameWidth,
          height: _teamRowHeight,
          bg: _kHeaderGrey,
          text: teamName,
          style: _s16w700,
          maxLines: 2,
        ),
        _cell(
          width: m.serieWidth,
          height: _teamRowHeight,
          bg: _kBodyYellow,
          text: numLabel(body),
          style: _s24w700,
        ),
        _cell(
          width: m.plneWidth,
          height: _teamRowHeight,
          bg: _kStatsPurple,
          text: numLabel(fulls),
          style: _s20w400,
        ),
        _cell(
          width: m.dorWidth,
          height: _teamRowHeight,
          bg: _kStatsPurple,
          text: numLabel(spares),
          style: _s20w400,
        ),
        _cell(
          width: m.chWidth,
          height: _teamRowHeight,
          bg: _kStatsPurple,
          text: numLabel(errors),
          style: _s20w400,
        ),
        _cell(
          width: m.celkemColWidth,
          height: _teamRowHeight,
          bg: _kStatsPurple,
          text: numLabel(total),
          style: _s20w700,
        ),
        _cell(
          width: m.dilciWidth,
          height: _teamRowHeight,
          bg: _kStatsPurple,
          text: numLabel(setPoints),
          style: _s20w400,
        ),
        _cell(
          width: m.druzstvoWidth,
          height: _teamRowHeight,
          bg: _kDruzstvoBlue,
          text: numLabel(
            _teamBonusPoints(body, players, isHome ? 'home' : 'away'),
          ),
          style: _s20w700,
        ),
      ],
    );
  }

  Widget _teamSummaryRow(_ColumnMetrics m) {
    final home = result?.homeTotal;
    final away = result?.awayTotal;
    final diff = (home != null && away != null) ? home - away : null;
    return Row(
      children: [
        _teamSummarySide(m, slot.homeTeam, true),
        _cell(
          width: m.rozdilWidth,
          height: _teamRowHeight,
          bg: _kBodyYellow,
          text: diff == null ? '' : _signed(diff),
          style: _s20w700,
          color: _diffColor(diff),
        ),
        _teamSummarySide(m, slot.awayTeam, false),
      ],
    );
  }

  // ---- rows 1–2: column headers ----

  Widget _headerCell(
    double width,
    double height,
    String text, {
    TextAlign align = TextAlign.center,
    int maxLines = 1,
  }) => _cell(
    width: width,
    height: height,
    bg: _kHeaderGrey,
    text: text,
    style: _s10w400,
    align: align,
    maxLines: maxLines,
  );

  Widget _headerColumn(_ColumnMetrics m) {
    final vykonWidth =
        m.plneWidth + m.dorWidth + m.chWidth + m.celkemColWidth + m.dilciWidth;

    return Row(
      children: [
        Column(
          children: [
            _headerCell(
              m.nameWidth,
              _headerRowHeight,
              'Jméno a příjmení hráče',
              align: TextAlign.left,
            ),
            _headerCell(
              m.nameWidth,
              _headerRowHeight,
              'Registrační číslo',
              align: TextAlign.left,
            ),
          ],
        ),
        // The one header allowed to wrap (Fix round 5, item 3) — its own
        // width never has to fit "Série hodů" on a single line.
        _headerCell(
          m.serieWidth,
          _headerRowHeight * 2,
          'Série hodů',
          maxLines: 2,
        ),
        Column(
          children: [
            _headerCell(vykonWidth, _headerRowHeight, 'Výkon'),
            Row(
              children: [
                _headerCell(m.plneWidth, _headerRowHeight, 'Plné'),
                _headerCell(m.dorWidth, _headerRowHeight, 'Dor.'),
                _headerCell(m.chWidth, _headerRowHeight, 'Ch.'),
                _headerCell(m.celkemColWidth, _headerRowHeight, 'Celkem'),
                _headerCell(m.dilciWidth, _headerRowHeight, 'Dílčí'),
              ],
            ),
          ],
        ),
        Column(
          children: [
            _headerCell(m.druzstvoWidth, _headerRowHeight, 'Body'),
            _headerCell(m.druzstvoWidth, _headerRowHeight, 'Družstvo'),
          ],
        ),
      ],
    );
  }

  Widget _headerRows(_ColumnMetrics m) {
    return Row(
      children: [
        _headerColumn(m),
        _headerCell(m.rozdilWidth, _headerRowHeight * 2, 'Rozdíl'),
        _headerColumn(m),
      ],
    );
  }

  // ---- pairing blocks ----

  Widget _pairingSide(
    _ColumnMetrics m,
    MatchPlayerResult? player,
    int laneRowCount,
    double blockHeight,
  ) {
    if (player == null) {
      // Ragged data (a position only the other side fielded): one blank
      // bordered cell spanning the FULL block height — matching the other
      // side's height, so there's no unpainted/unbordered gap below it
      // (Fix round 5, item 5's same reasoning applied to a wholly missing
      // side, not just an uneven lane count).
      final width =
          m.nameWidth +
          m.serieWidth +
          m.plneWidth +
          m.dorWidth +
          m.chWidth +
          m.celkemColWidth +
          m.dilciWidth +
          m.druzstvoWidth;
      return _cell(
        width: width,
        height: blockHeight,
        bg: _kWhite,
        text: '',
        style: _s10w400,
      );
    }

    final realLaneCount = player.lanes.length;
    final hasLaneRows = laneRowCount > 0;
    final nameText = player.playerName; // no "N. " prefix (Fix round 5).

    Widget laneRow(PlayerLane? lane) {
      // A filler row when this side threw fewer lanes than the other side
      // at this position — styled exactly like a real lane row, just
      // blank, so the shorter side's column is still fully painted and
      // bordered up to the taller side's height (Fix round 5, item 5).
      return Row(
        children: [
          _cell(
            width: m.serieWidth,
            height: _laneRowHeight,
            bg: _kBodyYellow,
            text: lane == null ? '' : '${lane.lane}',
            style: _s10w400,
          ),
          _cell(
            width: m.plneWidth,
            height: _laneRowHeight,
            bg: _kLaneStatsGreen,
            text: lane == null ? '' : numLabel(lane.fulls),
            style: _s10w400,
          ),
          _cell(
            width: m.dorWidth,
            height: _laneRowHeight,
            bg: _kLaneStatsGreen,
            text: lane == null ? '' : numLabel(lane.spares),
            style: _s10w400,
          ),
          _cell(
            width: m.chWidth,
            height: _laneRowHeight,
            bg: _kLaneStatsGreen,
            text: lane == null ? '' : numLabel(lane.errors),
            style: _s10w400,
          ),
          _cell(
            width: m.celkemColWidth,
            height: _laneRowHeight,
            bg: _kStatsPurple,
            text: lane == null ? '' : numLabel(lane.total),
            style: _s10w400,
          ),
          _cell(
            width: m.dilciWidth,
            height: _laneRowHeight,
            bg: _kStatsPurple,
            text: lane == null ? '' : numLabel(lane.setPoints),
            style: _s10w400,
          ),
        ],
      );
    }

    final celkemRow = Row(
      children: [
        _cell(
          width: m.serieWidth,
          height: _celkemRowHeight,
          bg: _kStatsPurple,
          text: 'Celkem',
          style: _s10w700,
        ),
        _cell(
          width: m.plneWidth,
          height: _celkemRowHeight,
          bg: _kStatsPurple,
          text: numLabel(player.fulls),
          style: _s10w700,
        ),
        _cell(
          width: m.dorWidth,
          height: _celkemRowHeight,
          bg: _kStatsPurple,
          text: numLabel(player.spares),
          style: _s10w700,
        ),
        _cell(
          width: m.chWidth,
          height: _celkemRowHeight,
          bg: _kStatsPurple,
          text: numLabel(player.errors),
          style: _s10w700,
        ),
        _cell(
          width: m.celkemColWidth,
          height: _celkemRowHeight,
          bg: _kRegCellBlue,
          text: numLabel(player.total),
          style: _s16w700,
          color: _kCelkemTotalRed,
        ),
        _cell(
          width: m.dilciWidth,
          height: _celkemRowHeight,
          bg: _kRegCellBlue,
          text: numLabel(player.setPoints),
          style: _s10w400,
        ),
      ],
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            if (hasLaneRows)
              _cell(
                width: m.nameWidth,
                height: laneRowCount * _laneRowHeight,
                bg: _kNameCellGrey,
                text: nameText,
                style: _s16w700,
                align: TextAlign.left,
                maxLines: 2,
              ),
            _cell(
              width: m.nameWidth,
              // A player with zero lane rows at all (nothing to pad to
              // either) puts their name straight into this cell instead —
              // one line only, so a 31px-tall row can actually fit it
              // without clipping (Fix round 5, item 6).
              height: _celkemRowHeight,
              bg: _kRegCellBlue,
              text: hasLaneRows ? '' : nameText,
              style: _s16w700,
              align: TextAlign.left,
              maxLines: 1,
            ),
          ],
        ),
        Column(
          children: [
            for (var i = 0; i < laneRowCount; i++)
              laneRow(i < realLaneCount ? player.lanes[i] : null),
            celkemRow,
          ],
        ),
        _cell(
          width: m.druzstvoWidth,
          height: blockHeight,
          bg: _kDruzstvoBlue,
          text: numLabel(player.teamPoints),
          style: _s20w700,
        ),
      ],
    );
  }

  Widget _pairingBlock(
    _ColumnMetrics m,
    MatchPlayerResult? home,
    MatchPlayerResult? away,
  ) {
    final diff = (home?.total != null && away?.total != null)
        ? home!.total! - away!.total!
        : null;
    final homeLanes = home?.lanes.length ?? 0;
    final awayLanes = away?.lanes.length ?? 0;
    final laneRowCount = math.max(homeLanes, awayLanes);
    final blockHeight = laneRowCount * _laneRowHeight + _celkemRowHeight;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _pairingSide(m, home, laneRowCount, blockHeight),
        _cell(
          width: m.rozdilWidth,
          height: blockHeight,
          bg: _kBodyYellow,
          text: diff == null ? '' : _signed(diff),
          style: _s16w400,
          color: _diffColor(diff),
        ),
        _pairingSide(m, away, laneRowCount, blockHeight),
      ],
    );
  }

  Widget _separatorRow(_ColumnMetrics m) => _cell(
    width: m.totalWidth,
    height: _separatorHeight,
    bg: _kWhite,
    text: '',
    style: _s10w400,
  );
}

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
    final naturalSize = _ScoreTableBody.naturalSize(
      slot: slot,
      result: result,
      players: players,
    );
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
          naturalSize: naturalSize,
          child: _ScoreTableBody(slot: slot, result: result, players: players),
        ),
      ),
    );
  }
}

/// Scales [child] to fit the available space — same "see the whole table
/// at once" goal a plain [FittedBox] gives — but, unlike [FittedBox], lets
/// the user then pinch past that initial scale to read the detail and pan
/// around. [InteractiveViewer] has no scrollbar chrome of its own — it's a
/// direct-manipulation gesture surface, not a scrollable — so "no
/// scrollbars anywhere on this page" still holds.
///
/// Fix round 5: the fit scale is computed straight from [naturalSize] —
/// [child]'s real size, known up front by [_ScoreTableBody.naturalSize]
/// without building anything — so the very first frame already renders at
/// the right scale. Round 3's approach (measure the built child via a
/// [GlobalKey] in a post-frame callback, then correct) always painted one
/// wrong-scale frame first.
class _ScaleToFitViewer extends StatefulWidget {
  const _ScaleToFitViewer({required this.naturalSize, required this.child});

  final Size naturalSize;
  final Widget child;

  @override
  State<_ScaleToFitViewer> createState() => _ScaleToFitViewerState();
}

class _ScaleToFitViewerState extends State<_ScaleToFitViewer> {
  final _controller = TransformationController();

  /// Never lets a huge lineup shrink to the point of being useless.
  static const _minFitScale = 0.15;
  double _minScale = 1.0;
  bool _initialized = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Only a floor, deliberately no ceiling: on a screen wider/taller
        // than the table's own natural size (a desktop window), this
        // scales UP past 1.0 to fill it — the plain `FittedBox` this
        // replaces capped at 1.0 and left the table small in the middle
        // of the screen there.
        final fit = math.max(
          math.min(
            constraints.maxWidth / widget.naturalSize.width,
            constraints.maxHeight / widget.naturalSize.height,
          ),
          _minFitScale,
        );
        // Applied once, synchronously, on this very first build — never
        // re-applied on a later resize, so it can't fight a pinch the
        // user has already made.
        if (!_initialized) {
          _initialized = true;
          _minScale = fit;
          _controller.value = Matrix4.diagonal3Values(fit, fit, 1.0);
        }
        return InteractiveViewer(
          transformationController: _controller,
          constrained: false,
          minScale: _minScale,
          maxScale: math.max(_minScale * 4, 3.0),
          child: widget.child,
        );
      },
    );
  }
}

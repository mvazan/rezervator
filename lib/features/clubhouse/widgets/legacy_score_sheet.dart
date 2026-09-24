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
              geometry: _SheetGeometry.natural(
                slot: slot,
                result: result,
                players: players,
              ),
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

  /// The narrowest name column the full-screen page may wrap names into
  /// (never below a single word): the widest single word of any player or
  /// team name in 16/w700, and each name-column header ("Jméno a příjmení
  /// hráče", "Registrační číslo") at the width it needs on 2 lines — plus
  /// [_cellChrome], rounded up like every other column.
  static double compactNameWidth({
    required PrioritySlot slot,
    required List<MatchPlayerResult> players,
  }) {
    List<String> words(String text) =>
        text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();

    double widestWord(String text, TextStyle style) {
      var widest = 0.0;
      for (final word in words(text)) {
        widest = math.max(widest, _measure(word, style));
      }
      return widest;
    }

    // The best split of [text] into two lines — what its wrapped cell
    // needs to stay within 2 lines.
    double twoLineWidth(String text, TextStyle style) {
      final all = words(text);
      if (all.length < 2) return _measure(text, style);
      var best = double.infinity;
      for (var i = 1; i < all.length; i++) {
        best = math.min(
          best,
          math.max(
            _measure(all.sublist(0, i).join(' '), style),
            _measure(all.sublist(i).join(' '), style),
          ),
        );
      }
      return best;
    }

    var widest = math.max(
      widestWord(slot.homeTeam, _s16w700),
      widestWord(slot.awayTeam, _s16w700),
    );
    if (players.isNotEmpty) {
      widest = math.max(
        widest,
        twoLineWidth('Jméno a příjmení hráče', _s10w400),
      );
      widest = math.max(widest, twoLineWidth('Registrační číslo', _s10w400));
    }
    for (final p in players) {
      widest = math.max(widest, widestWord(p.playerName, _s16w700));
    }
    return (widest + _cellChrome).ceilToDouble();
  }

  /// The height [text] takes when wrapped at [maxWidth] — every line at
  /// [style]'s real line height, no line limit.
  static double wrappedHeight(String text, TextStyle style, double maxWidth) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout(maxWidth: math.max(0, maxWidth));
    final height = painter.height;
    painter.dispose();
    return height;
  }

  /// One line of [style], as the table lays it out.
  static double lineHeight(TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: ' ', style: style),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout();
    final height = painter.preferredLineHeight;
    painter.dispose();
    return height;
  }

  /// These metrics with the (mirrored) name column at [width] instead.
  _ColumnMetrics withNameWidth(double width) => _ColumnMetrics(
    nameWidth: width,
    serieWidth: serieWidth,
    plneWidth: plneWidth,
    dorWidth: dorWidth,
    chWidth: chWidth,
    celkemColWidth: celkemColWidth,
    dilciWidth: dilciWidth,
    druzstvoWidth: druzstvoWidth,
    rozdilWidth: rozdilWidth,
  );

  /// Every column widened by the same [factor] — kuzelky's proportions kept.
  _ColumnMetrics scaled(double factor) => _ColumnMetrics(
    nameWidth: nameWidth * factor,
    serieWidth: serieWidth * factor,
    plneWidth: plneWidth * factor,
    dorWidth: dorWidth * factor,
    chWidth: chWidth * factor,
    celkemColWidth: celkemColWidth * factor,
    dilciWidth: dilciWidth * factor,
    druzstvoWidth: druzstvoWidth * factor,
    rozdilWidth: rozdilWidth * factor,
  );
}

/// Every size [_ScoreTableBody] renders at: its column widths, its row
/// heights and how many lines a name cell may use.
///
/// [_SheetGeometry.natural] is kuzelky's own table — the embedded sheet,
/// which scrolls sideways. [_SheetGeometry.fill] is the full-screen page's:
/// the same table stretched so that, scaled uniformly, it covers a body
/// area exactly — 100% width AND 100% height, in portrait and landscape.
class _SheetGeometry {
  const _SheetGeometry._({
    required this.columns,
    required this.rowScale,
    required this.wrapNames,
  });

  // Row heights (dp), copied 1:1 from kuzelky.com's own table.
  static const _teamRowHeight = 43.0;
  static const _headerRowHeight = 23.0;
  static const _laneRowHeight = 23.0;
  static const _celkemRowHeight = 31.0;
  static const _separatorHeight = 9.0;

  /// The outer 2px border frame's own padding (`fromLTRB(2, 2, 1, 1)`),
  /// added to a content size to get the table's actual rendered size.
  static const _frameWidth = 3.0; // left 2 + right 1
  static const _frameHeight = 3.0; // top 2 + bottom 1

  final _ColumnMetrics columns;

  /// The one factor every row except the 9dp separators is stretched by:
  /// team, header, lane and Celkem rows alike (1.0 = kuzelky's own).
  final double rowScale;

  /// Whether names may wrap onto as many lines as their cell's height
  /// holds (the full-screen page) or keep the embedded sheet's fixed line
  /// limits.
  final bool wrapNames;

  factory _SheetGeometry.natural({
    required PrioritySlot slot,
    required MatchResult? result,
    required List<MatchPlayerResult> players,
  }) => _SheetGeometry._(
    columns: _ColumnMetrics.compute(
      slot: slot,
      result: result,
      players: players,
    ),
    rowScale: 1.0,
    wrapNames: false,
  );

  /// The geometry that fills [area] exactly once scaled by one uniform
  /// factor `s`, with the biggest `s` (= the biggest text) this table
  /// allows:
  ///
  /// 1. The name columns are the only ones that may narrow — from their
  ///    natural single-line width down to [_ColumnMetrics.compactNameWidth]
  ///    — with names (and the name-column headers) wrapping instead. A
  ///    narrower name column needs taller rows wherever a name now takes
  ///    more lines: [minRowScale].
  /// 2. For every whole-dp name width `n` in that range the table's
  ///    smallest unscaled size is `(w(n), h(n))` and it fits [area] at
  ///    `s(n) = min(W / w(n), H / h(n))`. `W / w(n)` falls as `n` grows and
  ///    `H / h(n)` never does, so the best `n` sits where the two cross —
  ///    found by bisection, not by trying every width.
  /// 3. The dimension with room left over is then stretched, unscaled, to
  ///    exactly `(W / s, H / s)`: extra width goes to every column in
  ///    proportion to its width, extra height to every row but the 9dp
  ///    separators through the one common [rowScale]. Text sizes stay; only
  ///    cells grow.
  factory _SheetGeometry.fill({
    required PrioritySlot slot,
    required MatchResult? result,
    required List<MatchPlayerResult> players,
    required Size area,
  }) {
    final natural = _ColumnMetrics.compute(
      slot: slot,
      result: result,
      players: players,
    );
    final laneRows = _laneRowCounts(players);
    final baseRowsHeight = _rowsHeight(laneRows, players.isNotEmpty);
    final fixedHeight =
        _separatorHeight * math.max(0, laneRows.length - 1) + _frameHeight;
    final otherWidth = natural.totalWidth - 2 * natural.nameWidth + _frameWidth;

    // The smallest common row factor at which every name, team name and
    // name-column header wrapped at [nameWidth] fits its cell unclipped.
    double minRowScale(double nameWidth) {
      final textWidth = nameWidth - _ColumnMetrics._cellChrome;
      var scale = 1.0;
      void fit(String text, TextStyle style, double baseCellHeight) {
        final needed =
            _ColumnMetrics.wrappedHeight(text, style, textWidth) +
            _ColumnMetrics._cellChrome;
        scale = math.max(scale, needed / baseCellHeight);
      }

      fit(slot.homeTeam, _s16w700, _teamRowHeight);
      fit(slot.awayTeam, _s16w700, _teamRowHeight);
      if (players.isNotEmpty) {
        fit('Jméno a příjmení hráče', _s10w400, _headerRowHeight);
        fit('Registrační číslo', _s10w400, _headerRowHeight);
      }
      for (final p in players) {
        final laneRowCount = laneRows[p.position] ?? 0;
        fit(
          p.playerName,
          _s16w700,
          laneRowCount >= 2 ? laneRowCount * _laneRowHeight : _celkemRowHeight,
        );
      }
      return scale;
    }

    double widthAt(double nameWidth) => 2 * nameWidth + otherWidth;
    double heightAt(double rowScale) => rowScale * baseRowsHeight + fixedHeight;
    double widthFit(double n) => area.width / widthAt(n);
    double heightFit(double n) => area.height / heightAt(minRowScale(n));
    // Whether the height, not the width, is what caps the scale at [n].
    bool heightBound(double n) => heightFit(n) < widthFit(n);
    double scaleAt(double n) => math.min(widthFit(n), heightFit(n));

    var lo = math.min(
      _ColumnMetrics.compactNameWidth(slot: slot, players: players),
      natural.nameWidth,
    );
    var hi = natural.nameWidth;
    final double nameWidth;
    if (!heightBound(lo)) {
      // Width-bound even fully wrapped: the narrowest column wins.
      nameWidth = lo;
    } else if (heightBound(hi)) {
      // Height-bound even on single lines: nothing to gain by wrapping.
      nameWidth = hi;
    } else {
      // heightBound(lo) && !heightBound(hi): bisect to adjacent widths.
      while (hi - lo > 1) {
        final mid = ((lo + hi) / 2).floorToDouble();
        if (heightBound(mid)) {
          lo = mid;
        } else {
          hi = mid;
        }
      }
      nameWidth = scaleAt(lo) > scaleAt(hi) ? lo : hi;
    }

    final scale = scaleAt(nameWidth);
    final fillWidth = area.width / scale;
    final fillHeight = area.height / scale;
    final widthFactor =
        (fillWidth - _frameWidth) / (widthAt(nameWidth) - _frameWidth);
    // Never below what the wrapped names need (rounding aside).
    final rowScale = math.max(
      minRowScale(nameWidth),
      (fillHeight - fixedHeight) / baseRowsHeight,
    );
    return _SheetGeometry._(
      columns: natural.withNameWidth(nameWidth).scaled(widthFactor),
      rowScale: rowScale,
      wrapNames: true,
    );
  }

  /// Per position (1..N): how many lane rows its pairing block has — the
  /// side that threw more lanes decides.
  static Map<int, int> _laneRowCounts(List<MatchPlayerResult> players) {
    final counts = <int, int>{};
    for (final p in players) {
      counts[p.position] = math.max(counts[p.position] ?? 0, p.lanes.length);
    }
    return counts;
  }

  /// The unscaled sum of every stretchable row (all but the separators).
  static double _rowsHeight(Map<int, int> laneRows, bool hasPlayers) {
    var height = _teamRowHeight;
    if (!hasPlayers) return height;
    height += _headerRowHeight * 2;
    for (final laneRowCount in laneRows.values) {
      height += laneRowCount * _laneRowHeight + _celkemRowHeight;
    }
    return height;
  }

  double get teamRowHeight => _teamRowHeight * rowScale;
  double get headerRowHeight => _headerRowHeight * rowScale;
  double get laneRowHeight => _laneRowHeight * rowScale;
  double get celkemRowHeight => _celkemRowHeight * rowScale;
  double get separatorHeight => _separatorHeight;

  /// How many lines of [style] a cell [cellHeight] tall holds (at least 1).
  static int _linesFitting(double cellHeight, TextStyle style) => math.max(
    1,
    // A hair of slack: a row stretched to exactly `lines × lineHeight +
    // chrome` must not lose its last line to float rounding.
    ((cellHeight - _ColumnMetrics._cellChrome + 1e-6) /
            _ColumnMetrics.lineHeight(style))
        .floor(),
  );

  /// The team-row name cell.
  int get teamNameMaxLines =>
      wrapNames ? _linesFitting(teamRowHeight, _s16w700) : 2;

  /// The "Jméno a příjmení hráče" / "Registrační číslo" header cells.
  int get nameHeaderMaxLines =>
      wrapNames ? _linesFitting(headerRowHeight, _s10w400) : 1;

  /// A player's name spanning [laneRowCount] (≥ 2) lane rows.
  int laneNameMaxLines(int laneRowCount) =>
      wrapNames ? _linesFitting(laneRowCount * laneRowHeight, _s16w700) : 2;

  /// A player's name in the Celkem row (fewer than 2 lane rows).
  int get celkemNameMaxLines =>
      wrapNames ? _linesFitting(celkemRowHeight, _s16w700) : 1;
}

/// The actual table — a 1:1 replica of kuzelky.com's own `table#tabzap`
/// grid, shared by the embedded [LegacyScoreSheet] (inside a horizontal
/// [SingleChildScrollView]) and [LegacyScoreSheetPage] (stretched and
/// scaled to fill the screen via [_FillViewer], never scrolled). Every
/// size comes from its [geometry]: row heights are the reference site's
/// own dp values (stretched by one common factor full screen); column
/// widths are computed per render by [_ColumnMetrics] (Fix round 5 — see
/// its own doc comment).
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
    required this.geometry,
  });

  final PrioritySlot slot;
  final MatchResult? result;
  final List<MatchPlayerResult> players;

  /// Every column width, row height and name line limit this table renders
  /// at — kuzelky's own ([_SheetGeometry.natural]) or the full-screen
  /// page's stretched one ([_SheetGeometry.fill]).
  final _SheetGeometry geometry;

  double get _teamRowHeight => geometry.teamRowHeight;
  double get _headerRowHeight => geometry.headerRowHeight;
  double get _laneRowHeight => geometry.laneRowHeight;
  double get _celkemRowHeight => geometry.celkemRowHeight;
  double get _separatorHeight => geometry.separatorHeight;

  MatchPlayerResult? _forSide(String side, int position) {
    for (final p in players) {
      if (p.side == side && p.position == position) return p;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final metrics = geometry.columns;
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
          maxLines: geometry.teamNameMaxLines,
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
              maxLines: geometry.nameHeaderMaxLines,
            ),
            _headerCell(
              m.nameWidth,
              _headerRowHeight,
              'Registrační číslo',
              align: TextAlign.left,
              maxLines: geometry.nameHeaderMaxLines,
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
    // A lone 23px lane row can't hold the 16px name — it goes into the Celkem
    // row then, the same as with no lane rows at all.
    final nameInLaneRows = laneRowCount >= 2;
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
            if (laneRowCount > 0)
              _cell(
                width: m.nameWidth,
                height: laneRowCount * _laneRowHeight,
                bg: _kNameCellGrey,
                text: nameInLaneRows ? nameText : '',
                style: _s16w700,
                align: TextAlign.left,
                maxLines: geometry.laneNameMaxLines(laneRowCount),
              ),
            _cell(
              width: m.nameWidth,
              // A player with fewer than two lane rows puts their name
              // straight into this cell instead — one line only in the
              // embedded sheet, so a 31px-tall row can actually fit it
              // without clipping (Fix round 5, item 6); as many as its
              // stretched height holds full screen.
              height: _celkemRowHeight,
              bg: _kRegCellBlue,
              text: nameInLaneRows ? '' : nameText,
              style: _s16w700,
              align: TextAlign.left,
              maxLines: geometry.celkemNameMaxLines,
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
/// content as [LegacyScoreSheet] ([_ScoreTableBody]), never scrolled in
/// either axis, filling the whole body area — below the AppBar, inside the
/// safe area, with no padding — 100% width AND 100% height, portrait or
/// landscape (see [_FillViewer]). Fix round 2 replaced fix round 1's
/// vertical [SingleChildScrollView]; fix round 3 let the user pinch in past
/// the initial "see it all at once" view to read the detail and pan around.
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
      body: SafeArea(
        child: _FillViewer(slot: slot, result: result, players: players),
      ),
    );
  }
}

/// Lays the table out to fill the available area exactly
/// ([_SheetGeometry.fill]: rows taller, names wrapped where that gives
/// bigger text), scales it uniformly onto that area, and puts it under an
/// [InteractiveViewer] opening at that fit (scale 1.0) with pinch-zoom up to
/// 4×. [InteractiveViewer] has no scrollbar chrome of its own — it's a
/// direct-manipulation gesture surface, not a scrollable — so "no
/// scrollbars anywhere on this page" still holds.
///
/// The layout is a pure, synchronous function of the data and the area —
/// the very first frame is already right, no post-frame correction. A new
/// area (rotation, window resize) is laid out afresh and resets any pinch
/// made against the old one.
class _FillViewer extends StatefulWidget {
  const _FillViewer({
    required this.slot,
    required this.result,
    required this.players,
  });

  final PrioritySlot slot;
  final MatchResult? result;
  final List<MatchPlayerResult> players;

  @override
  State<_FillViewer> createState() => _FillViewerState();
}

class _FillViewerState extends State<_FillViewer> {
  final _controller = TransformationController();

  /// The area the current fit (and any pinch on top of it) belongs to.
  Size? _area;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final area = constraints.biggest;
        if (!area.isFinite || area.isEmpty) return const SizedBox.shrink();
        if (_area != null && _area != area) {
          _controller.value = Matrix4.identity();
        }
        _area = area;
        final geometry = _SheetGeometry.fill(
          slot: widget.slot,
          result: widget.result,
          players: widget.players,
          area: area,
        );
        return SizedBox.fromSize(
          size: area,
          child: InteractiveViewer(
            transformationController: _controller,
            minScale: 1.0,
            maxScale: 4.0,
            // The geometry already has [area]'s aspect ratio, so this
            // uniform scale covers it edge to edge.
            child: FittedBox(
              child: _ScoreTableBody(
                slot: widget.slot,
                result: widget.result,
                players: widget.players,
                geometry: geometry,
              ),
            ),
          ),
        );
      },
    );
  }
}

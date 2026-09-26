/// The match detail's duel card (Souboje, Task 4): one position's duel told
/// at a glance — the two players, their totals with the „bod“ next to the
/// winner's, the lead and a difference bar on the match's shared scale, and
/// every lane side by side. A tap opens the per-lane table (Plné, Dor., Ch.,
/// Celkem) and a sentence that says how the point was won.
///
/// Live-safe like the domain under it: while a duel is being played its
/// totals, lead and bar count only the lanes BOTH players have thrown, a
/// lane one of them hasn't finished reads „– : –“, and nothing is styled as
/// won until the duel is done. A duel nobody has started is a slim „čeká“
/// card.
///
/// Home is always on the left. Every number is set in tabular figures, and a
/// winner is never told by colour alone: the weight of the total, the „bod“
/// pill, the side the bar grows to and the side of a lane's dot say it too.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../domain/duels.dart';
import '../../../domain/results.dart';

/// Digits of one width, so a number doesn't jump when a live value changes.
const _tabular = [FontFeature.tabularFigures()];

/// One duel of a match — see the library comment.
///
/// The card has no margin of its own: the list places it (12dp from the
/// edges, 8dp apart).
class DuelCard extends StatelessWidget {
  const DuelCard({
    super.key,
    required this.duel,
    required this.scale,
    required this.expanded,
    required this.onTap,
    required this.homeColor,
    required this.awayColor,
  });

  /// The duel to show.
  final Duel duel;

  /// The [diffScale] of the whole match: the difference that fills half the
  /// bar, shared by every card so a +4 reads as a sliver next to a +99.
  final int scale;

  /// Whether the per-lane table is open. A waiting duel ignores it.
  final bool expanded;

  /// Toggles [expanded] in the parent. Called on every tap, a waiting card's
  /// too (harmless: it never opens).
  final VoidCallback onTap;

  /// The home side's colour: its stripe, bar, lane dots and pill.
  final Color homeColor;

  /// The away side's colour: its stripe, bar, lane dots and pill.
  final Color awayColor;

  @override
  Widget build(BuildContext context) {
    final waiting = duel.state == DuelState.waiting;
    final winner = duel.state == DuelState.done ? duel.pointWinner : null;
    return Semantics(
      container: true,
      label: duelSemantics(duel),
      button: true,
      expanded: waiting ? null : expanded,
      onTap: onTap,
      excludeSemantics: true,
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: waiting
              ? _WaitingBody(duel: duel)
              : Stack(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      child: _DuelBody(
                        duel: duel,
                        scale: scale,
                        expanded: expanded,
                        homeColor: homeColor,
                        awayColor: awayColor,
                      ),
                    ),
                    // The winner's outer edge: left for home, right for away.
                    if (winner != null)
                      Positioned(
                        top: 0,
                        bottom: 0,
                        left: winner == MatchSide.home ? 0 : null,
                        right: winner == MatchSide.away ? 0 : null,
                        width: 4,
                        child: ColoredBox(
                          key: Key('duel-${duel.position}-stripe'),
                          color: winner == MatchSide.home
                              ? homeColor
                              : awayColor,
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// A duel nobody has started: „home name  čeká  away name“, at least 56dp.
class _WaitingBody extends StatelessWidget {
  const _WaitingBody({required this.duel});

  final Duel duel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final name = text.bodyLarge?.copyWith(
      fontSize: 15,
      fontWeight: FontWeight.w500,
      color: scheme.onSurface,
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                duel.home?.playerName ?? '–',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: name,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                'čeká',
                style: text.bodyMedium?.copyWith(
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            Expanded(
              child: Text(
                duel.away?.playerName ?? '–',
                textAlign: TextAlign.end,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: name,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A duel being played or done: names, totals, bar, lanes, the verdict line
/// and, when [expanded], the lane table.
class _DuelBody extends StatelessWidget {
  const _DuelBody({
    required this.duel,
    required this.scale,
    required this.expanded,
    required this.homeColor,
    required this.awayColor,
  });

  final Duel duel;
  final int scale;
  final bool expanded;
  final Color homeColor;
  final Color awayColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final done = duel.state == DuelState.done;
    final small = text.bodySmall?.copyWith(
      fontSize: 12,
      fontWeight: FontWeight.w400,
      color: scheme.onSurfaceVariant,
      fontFeatures: _tabular,
    );
    final sentence = _sentence(duel);
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Names(duel: duel),
        const SizedBox(height: 6),
        _Totals(duel: duel, homeColor: homeColor, awayColor: awayColor),
        if (!done && duel.laneCount > 0)
          Text(
            'po ${duel.playedLanes} ze ${duel.laneCount} drah',
            textAlign: TextAlign.center,
            style: small,
          ),
        const SizedBox(height: 10),
        _DiffBar(
          position: duel.position,
          diff: duel.diff,
          scale: scale,
          homeColor: homeColor,
          awayColor: awayColor,
          // While the duel is played the bar is only provisional: half
          // strength (the foundation's stand-in for hatching).
          faded: !done,
        ),
        if (duel.lanes.isNotEmpty) ...[
          const SizedBox(height: 12),
          _Lanes(duel: duel, homeColor: homeColor, awayColor: awayColor),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: done
                  ? Text(
                      'SB ${numLabel(duel.home?.setPoints)} : '
                      '${numLabel(duel.away?.setPoints)}'
                      '${duel.decidedByPins ? ' · rozhodly kuželky' : ''}',
                      style: small,
                    )
                  : const SizedBox.shrink(),
            ),
            Icon(
              expanded ? Icons.expand_less : Icons.expand_more,
              size: 20,
              color: scheme.onSurfaceVariant,
            ),
          ],
        ),
        AnimatedSize(
          duration: reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          child: !expanded
              ? const SizedBox(width: double.infinity)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 8),
                    _LaneTable(duel: duel),
                    if (sentence != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        sentence,
                        textAlign: TextAlign.center,
                        style: text.bodyMedium?.copyWith(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: scheme.onSurface,
                          fontFeatures: _tabular,
                        ),
                      ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  /// „SB 1 : 1 → rozhodly kuželky 407 : 385 → bod Mičanová“ when pins
  /// decided, „SB 2 : 0 → bod Strnad“ otherwise, „SB 0,5 : 0,5 → body
  /// napůl“ on a split. Null until the duel is done, or when its point is
  /// unknown.
  static String? _sentence(Duel duel) {
    if (duel.state != DuelState.done) return null;
    final sb =
        'SB ${numLabel(duel.home?.setPoints)} : '
        '${numLabel(duel.away?.setPoints)}';
    if (duel.pointSplit) return '$sb → body napůl';
    final winner = duel.pointWinner;
    if (winner == null) return null;
    final surname = surnameOf(
      (winner == MatchSide.home ? duel.home : duel.away)?.playerName,
    );
    final pins = duel.decidedByPins
        ? ' → rozhodly kuželky ${numLabel(duel.home?.total)} : '
              '${numLabel(duel.away?.total)}'
        : '';
    return '$sb$pins → bod $surname';
  }
}

/// „Lucie Mičanová  (1)  Lukáš Pelánek“: both names up to 2 lines around the
/// position in a 24dp circle.
class _Names extends StatelessWidget {
  const _Names({required this.duel});

  final Duel duel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final name = text.bodyLarge?.copyWith(
      fontSize: 15,
      fontWeight: FontWeight.w500,
      color: scheme.onSurface,
    );
    return Row(
      children: [
        Expanded(
          child: Text(
            duel.home?.playerName ?? '–',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: name,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              shape: BoxShape.circle,
            ),
            child: SizedBox.square(
              dimension: 24,
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '${duel.position}',
                    style: text.labelMedium?.copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                      fontFeatures: _tabular,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: Text(
            duel.away?.playerName ?? '–',
            textAlign: TextAlign.end,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: name,
          ),
        ),
      ],
    );
  }
}

/// „407 [bod]   ◂ 22   385“: the totals at 32dp around the lead. Done: the
/// point winner's total is w800 with a „bod“ pill beside it (a split: „½“ on
/// both). Played: both w500, no pill, and the totals are the duel's shown
/// ones ([Duel.shownHome], [Duel.shownAway]): only the lanes both players
/// threw, so they agree with the lead.
class _Totals extends StatelessWidget {
  const _Totals({
    required this.duel,
    required this.homeColor,
    required this.awayColor,
  });

  final Duel duel;
  final Color homeColor;
  final Color awayColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final done = duel.state == DuelState.done;
    final winner = done ? duel.pointWinner : null;
    final split = done && duel.pointSplit;
    final homeTotal = numLabel(duel.shownHome);
    final awayTotal = numLabel(duel.shownAway);

    TextStyle? totalStyle(MatchSide side) => text.displaySmall?.copyWith(
      fontSize: 32,
      height: 1.1,
      fontWeight: winner == side ? FontWeight.w800 : FontWeight.w500,
      color: scheme.onSurface,
      fontFeatures: _tabular,
    );

    Widget? pill(MatchSide side) {
      final color = side == MatchSide.home ? homeColor : awayColor;
      if (winner == side) return _PointPill(label: 'bod', color: color);
      if (split) return _PointPill(label: '½', color: color);
      return null;
    }

    final homePill = pill(MatchSide.home);
    final awayPill = pill(MatchSide.away);

    return Row(
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(homeTotal, style: totalStyle(MatchSide.home)),
                  if (homePill != null) ...[const SizedBox(width: 6), homePill],
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            leadLabel(duel.diff),
            style: text.labelLarge?.copyWith(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
              fontFeatures: _tabular,
            ),
          ),
        ),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (awayPill != null) ...[awayPill, const SizedBox(width: 6)],
                  Text(awayTotal, style: totalStyle(MatchSide.away)),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// „bod“ (or „½“) on the side's colour at 16 %, the text in onSurface.
class _PointPill extends StatelessWidget {
  const _PointPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: color.withValues(alpha: 0.16),
        shape: const StadiumBorder(),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(
          label,
          style: text.labelMedium?.copyWith(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: scheme.onSurface,
            fontFeatures: _tabular,
          ),
        ),
      ),
    );
  }
}

/// The 6dp difference bar: a track with a 1dp tick in the centre, and a fill
/// that grows from the centre towards the leader, `|diff| / scale` of the
/// half, in the leader's colour ([faded] = half strength).
class _DiffBar extends StatelessWidget {
  const _DiffBar({
    required this.position,
    required this.diff,
    required this.scale,
    required this.homeColor,
    required this.awayColor,
    required this.faded,
  });

  final int position;
  final int? diff;
  final int scale;
  final Color homeColor;
  final Color awayColor;
  final bool faded;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final diff = this.diff ?? 0;
    final share = diff == 0
        ? 0.0
        : math.min(diff.abs() / math.max(scale, 1), 1.0);
    final homeLeads = diff > 0;
    final color = homeLeads ? homeColor : awayColor;
    return SizedBox(
      key: Key('duel-$position-bar'),
      height: 6,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final half = constraints.maxWidth / 2;
            final width = share * half;
            return Stack(
              children: [
                Positioned.fill(
                  child: ColoredBox(color: scheme.surfaceContainerHighest),
                ),
                if (width > 0)
                  Positioned(
                    key: Key('duel-$position-bar-fill'),
                    top: 0,
                    bottom: 0,
                    left: homeLeads ? half - width : half,
                    width: width,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: faded
                            ? color.withValues(alpha: color.a * 0.5)
                            : color,
                      ),
                    ),
                  ),
                Positioned(
                  top: 0,
                  bottom: 0,
                  left: half - 0.5,
                  width: 1,
                  child: ColoredBox(color: scheme.outline),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// One entry per lane, two to a row: T100 side by side, T120 in a 2×2 grid.
class _Lanes extends StatelessWidget {
  const _Lanes({
    required this.duel,
    required this.homeColor,
    required this.awayColor,
  });

  final Duel duel;
  final Color homeColor;
  final Color awayColor;

  @override
  Widget build(BuildContext context) {
    final lanes = duel.lanes;
    Widget entry(int i) => Padding(
      padding: EdgeInsets.fromLTRB(4, i < 2 ? 0 : 6, 4, 0),
      child: i < lanes.length
          ? _LaneEntry(
              position: duel.position,
              lane: lanes[i],
              homeColor: homeColor,
              awayColor: awayColor,
            )
          : const SizedBox.shrink(),
    );
    // A table, so the columns line up (T120) and every lane shrinks by the
    // same factor when they don't fit.
    return _FitWidth(
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          for (var i = 0; i < lanes.length; i += 2)
            TableRow(children: [entry(i), entry(i + 1)]),
        ],
      ),
    );
  }
}

/// „Dr. 1  213 : 216•“: the lane winner's number w800 with a 6dp dot on its
/// outer side; a tie „215 = 215“; a lane not thrown by both „– : –“ in a
/// dashed frame. Centred in its cell.
class _LaneEntry extends StatelessWidget {
  const _LaneEntry({
    required this.position,
    required this.lane,
    required this.homeColor,
    required this.awayColor,
  });

  final int position;
  final LanePair lane;
  final Color homeColor;
  final Color awayColor;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final base = text.bodyLarge?.copyWith(
      fontSize: 16,
      fontWeight: FontWeight.w500,
      color: scheme.onSurface,
      fontFeatures: _tabular,
    );
    final label = Text(
      'Dr. ${lane.lane}',
      style: base?.copyWith(
        fontWeight: FontWeight.w400,
        color: scheme.onSurfaceVariant,
      ),
    );

    final Widget score;
    if (!lane.played) {
      score = CustomPaint(
        painter: _DashedOutlinePainter(color: scheme.outlineVariant, radius: 4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          child: Text(
            '– : –',
            style: base?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      );
    } else {
      final winner = lane.winner;
      TextStyle? number(MatchSide side) => base?.copyWith(
        fontWeight: winner == side ? FontWeight.w800 : FontWeight.w500,
      );
      Widget dot(MatchSide side) => SizedBox.square(
        key: winner == side
            ? Key('duel-$position-lane-${lane.lane}-dot')
            : null,
        dimension: 6,
        child: winner == side
            ? DecoratedBox(
                decoration: BoxDecoration(
                  color: side == MatchSide.home ? homeColor : awayColor,
                  shape: BoxShape.circle,
                ),
              )
            : null,
      );
      score = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          dot(MatchSide.home),
          const SizedBox(width: 4),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '${lane.home!.total}',
                  style: number(MatchSide.home),
                ),
                TextSpan(text: lane.tie ? ' = ' : ' : '),
                TextSpan(
                  text: '${lane.away!.total}',
                  style: number(MatchSide.away),
                ),
              ],
            ),
            style: base,
          ),
          const SizedBox(width: 4),
          dot(MatchSide.away),
        ],
      );
    }

    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [label, const SizedBox(width: 8), score],
      ),
    );
  }
}

/// The expanded table, mirrored around the lane column:
/// `Plné Dor. Ch. Celkem | Dr. n | Celkem Ch. Dor. Plné`, one row per lane
/// and a Celkem row from the players' own sums. 14dp; the Celkem column and
/// row w700.
///
/// Its columns take their natural width and share what is left evenly; the
/// column heads are 11dp, so on a 360dp phone at text scale 1.0 it fits
/// without shrinking. Larger text shrinks the whole table as one piece.
class _LaneTable extends StatelessWidget {
  const _LaneTable({required this.duel});

  final Duel duel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final value = text.bodyMedium?.copyWith(
      fontSize: 14,
      fontWeight: FontWeight.w500,
      color: scheme.onSurface,
      fontFeatures: _tabular,
    );
    final bold = value?.copyWith(fontWeight: FontWeight.w700);
    final caption = text.labelSmall?.copyWith(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      color: scheme.onSurfaceVariant,
      fontFeatures: _tabular,
    );
    final head = caption?.copyWith(fontSize: 11);

    Widget cell(String s, TextStyle? style) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
      child: Text(s, textAlign: TextAlign.center, style: style),
    );

    /// One side's four values, home in reading order and away mirrored.
    List<String> side(
      int? fulls,
      int? spares,
      int? errors,
      int? total, {
      required bool mirrored,
    }) {
      final values = [
        numLabel(fulls),
        numLabel(spares),
        numLabel(errors),
        numLabel(total),
      ];
      return mirrored ? values.reversed.toList() : values;
    }

    TableRow row(
      List<String> home,
      String middle,
      List<String> away, {
      required bool sum,
    }) => TableRow(
      decoration: sum
          ? BoxDecoration(
              border: Border(top: BorderSide(color: scheme.outlineVariant)),
            )
          : null,
      children: [
        for (final (i, s) in home.indexed)
          cell(s, sum || i == 3 ? bold : value),
        cell(middle, caption),
        for (final (i, s) in away.indexed)
          cell(s, sum || i == 0 ? bold : value),
      ],
    );

    final home = duel.home;
    final away = duel.away;
    const headers = ['Plné', 'Dor.', 'Ch.', 'Celkem'];
    return _FitWidth(
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          TableRow(
            children: [
              for (final h in headers) cell(h, head),
              cell('', head),
              for (final h in headers.reversed) cell(h, head),
            ],
          ),
          for (final lane in duel.lanes)
            row(
              side(
                lane.home?.fulls,
                lane.home?.spares,
                lane.home?.errors,
                lane.home?.total,
                mirrored: false,
              ),
              'Dr. ${lane.lane}',
              side(
                lane.away?.fulls,
                lane.away?.spares,
                lane.away?.errors,
                lane.away?.total,
                mirrored: true,
              ),
              sum: false,
            ),
          row(
            side(
              home?.fulls,
              home?.spares,
              home?.errors,
              home?.total,
              mirrored: false,
            ),
            'Celkem',
            side(
              away?.fulls,
              away?.spares,
              away?.errors,
              away?.total,
              mirrored: true,
            ),
            sum: true,
          ),
        ],
      ),
    );
  }
}

/// Lays [child] out at least as wide as the space it gets, and shrinks it as
/// one piece when it needs more (large text, a narrow phone), so all of its
/// cells keep one size.
class _FitWidth extends StatelessWidget {
  const _FitWidth({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => FittedBox(
      fit: BoxFit.scaleDown,
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: constraints.maxWidth),
        child: child,
      ),
    ),
  );
}

/// A dashed 1dp rounded outline, the frame of a lane not thrown yet.
class _DashedOutlinePainter extends CustomPainter {
  const _DashedOutlinePainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  static const _dash = 3.0;
  static const _gap = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final outline = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(0.5),
          Radius.circular(radius),
        ),
      );
    for (final metric in outline.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += _dash + _gap) {
        canvas.drawPath(
          metric.extractPath(d, math.min(d + _dash, metric.length)),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_DashedOutlinePainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}

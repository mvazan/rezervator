/// The match detail's scoreboard (Souboje, Task 3): who won and how the
/// score came about. The date and a status chip; the team names around a big
/// score (each over its own score when a name needs more than 2 lines); the
/// pin totals with the lead between them. Both views of the match detail
/// share it, so the score never jumps when the view switches. The line that
/// adds the score up („Souboje 5 : 1 · Kuželky 2 : 0 · SB 8,5 : 3,5“) is
/// [MatchPointsSummary], at the very end of the detail.
///
/// Every number is set in tabular figures, so live values don't jump as
/// they change, and a winner is never told by colour alone: the name's
/// weight, the bar's side and the sign of the lead say it too.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../domain/duels.dart';
import '../../../domain/models.dart';
import '../../../domain/results.dart';

/// Digits of one width, so a number doesn't jump when a live value changes.
const _tabular = [FontFeature.tabularFigures()];

/// The scoreboard at the top of the match detail — see the library comment.
class MatchScoreboard extends StatelessWidget {
  const MatchScoreboard({
    super.key,
    required this.slot,
    required this.result,
    required this.players,
    required this.now,
    this.onVenueTap,
  });

  /// The match: its date and start, the teams and the venue.
  final PrioritySlot slot;

  /// The team-level score; null before the match was first fetched.
  final MatchResult? result;

  /// Both lineups, one row per player; empty until the lineups are out.
  final List<MatchPlayerResult> players;

  /// The current time: whether the match is live, and the freshness in the
  /// „Živě“ chip.
  final DateTime now;

  /// Null = the venue is plain text (no known venue page).
  final VoidCallback? onVenueTap;

  /// The chip's word for a match that is not live.
  static String _statusLabel(MatchStatus status) => switch (status) {
    MatchStatus.scheduled => 'Naplánováno',
    MatchStatus.preparation => 'Příprava',
    // In progress per the last fetch, but past isLive's window: a stale
    // row, not a live match.
    MatchStatus.inProgress => 'Probíhá',
    MatchStatus.finished => 'Dokončeno',
    MatchStatus.forfeit => 'Kontumace',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final result = this.result;
    final status = result?.status;
    final live = isLive(slot, result, now);
    // Not final yet: live, or in progress per the last fetch (a stale row
    // past isLive's window is no final score either).
    final running = live || status == MatchStatus.inProgress;
    final forfeit = status == MatchStatus.forfeit;
    final duels = duelsOf(players);
    // While the match runs the pins count only the lanes both players of a
    // duel threw — the result's totals already count a lane one side has
    // finished, which would show a false lead.
    final liveTotals = running ? liveTeamTotals(duels) : null;
    final homeTotal = running ? liveTotals?.home : result?.homeTotal;
    final awayTotal = running ? liveTotals?.away : result?.awayTotal;
    final note = forfeit
        ? 'Zápas skončil kontumací – souboje se nehrály.'
        : players.isEmpty
        ? 'Sestavy zatím nejsou k dispozici.'
        : null;

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _TopLine(
              date: '${dayFull(slot.date)} · ${slot.startsAt.display()}',
              chip: result == null
                  ? null
                  : live
                  ? 'Živě · ${freshnessLabel(result.fetchedAt, now)}'
                  : _statusLabel(result.status),
              live: live,
            ),
            const SizedBox(height: 12),
            _ScoreLine(slot: slot, result: result, running: running),
            if (note != null) ...[
              const SizedBox(height: 8),
              Text(note, textAlign: TextAlign.center, style: text.bodySmall),
            ],
            if (homeTotal != null && awayTotal != null) ...[
              const SizedBox(height: 12),
              _PinsLine(
                homeTotal: homeTotal,
                awayTotal: awayTotal,
                running: running,
              ),
            ],
            _Footer(
              format: formatLabel(
                result?.matchType ?? '',
                result?.discipline ?? '',
              ),
              venue: slot.venue ?? '',
              onVenueTap: onVenueTap,
            ),
          ],
        ),
      ),
    );
  }
}

/// „Souboje 5 : 1 · Kuželky 2 : 0 · SB 8,5 : 3,5“: how the score adds up,
/// one line at the very end of the match detail (a decided match), or
/// „Souboje 1 : 0 · 2 rozehrané“ while it runs. Nothing before any duel has
/// started.
class MatchPointsSummary extends StatelessWidget {
  const MatchPointsSummary({
    super.key,
    required this.slot,
    required this.result,
    required this.players,
    required this.now,
  });

  final PrioritySlot slot;
  final MatchResult? result;
  final List<MatchPlayerResult> players;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final result = this.result;
    final status = result?.status;
    // Not final yet: live, or in progress per the last fetch.
    final running = isLive(slot, result, now) || status == MatchStatus.inProgress;
    final decided =
        status == MatchStatus.finished || status == MatchStatus.forfeit;
    // Only a decided match adds up: until every duel is done its players'
    // teamPoints are incomplete.
    final line = decided
        ? _decidedExplanation(matchPointsBreakdown(result, players), result!)
        : running
        ? _runningExplanation(duelsOf(players))
        : null;
    if (line == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Text(
        line,
        textAlign: TextAlign.center,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontSize: 13,
          fontWeight: FontWeight.w400,
          color: theme.colorScheme.onSurfaceVariant,
          fontFeatures: _tabular,
        ),
      ),
    );
  }

  /// „Souboje 5 : 1 · Kuželky 2 : 0 · SB 8,5 : 3,5“ for a decided match;
  /// null when [breakdown] is. SB is left out when the result has none.
  static String? _decidedExplanation(
    ({num duelsHome, num duelsAway, num pinsHome, num pinsAway})? breakdown,
    MatchResult result,
  ) {
    if (breakdown == null) return null;
    final hasSetPoints =
        result.homeSetPoints != null || result.awaySetPoints != null;
    return [
      'Souboje ${numLabel(breakdown.duelsHome)} : '
          '${numLabel(breakdown.duelsAway)}',
      'Kuželky ${numLabel(breakdown.pinsHome)} : '
          '${numLabel(breakdown.pinsAway)}',
      if (hasSetPoints)
        'SB ${pointsLabel(result.homeSetPoints, result.awaySetPoints)}',
    ].join(' · ');
  }

  /// „Souboje 1 : 0 · 2 rozehrané“ while the match runs, from the duels
  /// themselves: [matchPointsBreakdown] stays null until every duel is done.
  /// The points are those of the done duels; the count is the duels being
  /// played. Null while no duel has started.
  static String? _runningExplanation(List<Duel> duels) {
    num home = 0;
    num away = 0;
    var done = 0;
    var playing = 0;
    for (final duel in duels) {
      switch (duel.state) {
        case DuelState.done:
          done++;
          home += duel.home?.teamPoints ?? 0;
          away += duel.away?.teamPoints ?? 0;
        case DuelState.playing:
          playing++;
        case DuelState.waiting:
          break;
      }
    }
    if (done == 0 && playing == 0) return null;
    return [
      'Souboje ${numLabel(home)} : ${numLabel(away)}',
      if (playing > 0) _inPlay(playing),
    ].join(' · ');
  }

  /// „1 rozehraný“, „2 rozehrané“ … „4 rozehrané“, „5 rozehraných“ (and
  /// „0 rozehraných“): the adjective agrees with the count.
  static String _inPlay(int count) => switch (count) {
    1 => '1 rozehraný',
    2 || 3 || 4 => '$count rozehrané',
    _ => '$count rozehraných',
  };
}

/// The date and start on the left, the status chip on the right (it drops
/// under the date when the two don't fit on one line).
class _TopLine extends StatelessWidget {
  const _TopLine({required this.date, required this.chip, required this.live});

  /// „středa 16. 9. · 17:30“.
  final String date;

  /// The chip's text; null = no chip (nothing fetched yet).
  final String? chip;

  /// A live chip sits on errorContainer, so it stands out, with an 8dp dot
  /// before its text (an icon: Manrope has no „●“).
  final bool live;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final chip = this.chip;
    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 4,
      children: [
        Text(
          date,
          style: text.bodySmall?.copyWith(
            fontWeight: FontWeight.w400,
            fontFeatures: _tabular,
          ),
        ),
        if (chip != null)
          _Pill(
            label: chip,
            leading: live
                ? Icon(Icons.circle, size: 8, color: scheme.onErrorContainer)
                : null,
            fill: live ? scheme.errorContainer : scheme.surfaceContainerHighest,
            style: text.labelMedium?.copyWith(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: live ? scheme.onErrorContainer : scheme.onSurface,
              fontFeatures: _tabular,
            ),
          ),
      ],
    );
  }
}

/// „TJ Sokol Rudná A  7 : 1  TJ Sokol Vršovice A“: the names around the
/// score, home always on the left. The winner's name is w800 and the
/// loser's w400; with no winner (a tie, or no points yet) both are w500.
///
/// When a name would need more than 2 lines beside the score (a long club
/// name, large text on a narrow phone), the line stacks instead: the home
/// name with its score at the right, the away name under it with its own —
/// the scores 36dp, the winner's w800 and the loser's w400.
class _ScoreLine extends StatelessWidget {
  const _ScoreLine({
    required this.slot,
    required this.result,
    required this.running,
  });

  final PrioritySlot slot;
  final MatchResult? result;

  /// Not final yet: „průběžně“ goes under a score that is on the board.
  final bool running;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final home = result?.homePoints;
    final away = result?.awayPoints;
    final winner = winningSide(home, away);

    TextStyle? nameStyle(MatchSide side) => text.bodyLarge?.copyWith(
      fontSize: 16,
      color: scheme.onSurface,
      fontWeight: winner == null
          ? FontWeight.w500
          : winner == side
          ? FontWeight.w800
          : FontWeight.w400,
    );

    final digits = text.displaySmall?.copyWith(
      fontSize: 44,
      fontWeight: FontWeight.w800,
      height: 1.1,
      color: scheme.onSurface,
      fontFeatures: _tabular,
    );
    final colon = digits?.copyWith(fontSize: 32, fontWeight: FontWeight.w500);
    final noPoints = home == null && away == null;
    final showProgress = running && !noPoints;
    final progress = text.labelSmall?.copyWith(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      color: scheme.onSurfaceVariant,
    );

    final score = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // One label for the three pieces, read as „7 : 1“.
        Semantics(
          label: pointsLabel(home, away),
          excludeSemantics: true,
          child: noPoints
              ? Text('–', style: digits)
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(numLabel(home), style: digits),
                    Text(' : ', style: colon),
                    Text(numLabel(away), style: digits),
                  ],
                ),
        ),
        if (showProgress) Text('průběžně', style: progress),
      ],
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // Side by side the score takes its natural width, at most half the
        // line (it shrinks to fit that), and the names share the rest.
        final naturalScore = noPoints
            ? _textWidth(context, '–', digits)
            : math.max(
                _textWidth(context, numLabel(home), digits) +
                    _textWidth(context, ' : ', colon) +
                    _textWidth(context, numLabel(away), digits),
                showProgress ? _textWidth(context, 'průběžně', progress) : 0.0,
              );
        final nameWidth = (width - 24 - math.min(naturalScore, width / 2)) / 2;
        final sideBySide =
            nameWidth > 0 &&
            _fitsTwoLines(
              context,
              slot.homeTeam,
              nameStyle(MatchSide.home),
              nameWidth,
            ) &&
            _fitsTwoLines(
              context,
              slot.awayTeam,
              nameStyle(MatchSide.away),
              nameWidth,
            );

        if (sideBySide) {
          return Row(
            children: [
              Expanded(
                child: Text(
                  slot.homeTeam,
                  textAlign: TextAlign.end,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: nameStyle(MatchSide.home),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: width / 2),
                  child: FittedBox(fit: BoxFit.scaleDown, child: score),
                ),
              ),
              Expanded(
                child: Text(
                  slot.awayTeam,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: nameStyle(MatchSide.away),
                ),
              ),
            ],
          );
        }

        // Stacked: one row per team, its score at the right.
        Widget row(MatchSide side, String name, num? points) => MergeSemantics(
          child: Row(
            children: [
              Expanded(
                child: Text(
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: nameStyle(side),
                ),
              ),
              const SizedBox(width: 12),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: width / 2),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    numLabel(points),
                    style: digits?.copyWith(
                      fontSize: 36,
                      // No winner (a tie, no points yet): both stay w800,
                      // as the side-by-side score is.
                      fontWeight: winner != null && winner != side
                          ? FontWeight.w400
                          : FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
        return Column(
          key: const Key('scoreboard-stacked'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            row(MatchSide.home, slot.homeTeam, home),
            const SizedBox(height: 4),
            row(MatchSide.away, slot.awayTeam, away),
            if (showProgress)
              Align(
                alignment: Alignment.centerRight,
                child: Text('průběžně', style: progress),
              ),
          ],
        );
      },
    );
  }
}

/// A painter for [text] in [style] as a [Text] in [context] would lay it
/// out: the ambient default style (and bold text) merged in, the text
/// scaler, the direction and the locale. The caller disposes it.
TextPainter _painter(
  BuildContext context,
  String text,
  TextStyle? style, {
  int? maxLines,
}) {
  var resolved = DefaultTextStyle.of(context).style.merge(style);
  if (MediaQuery.boldTextOf(context)) {
    resolved = resolved.merge(const TextStyle(fontWeight: FontWeight.bold));
  }
  return TextPainter(
    text: TextSpan(text: text, style: resolved),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    locale: Localizations.maybeLocaleOf(context),
    maxLines: maxLines,
  );
}

/// The width of [text] in [style] on one line.
double _textWidth(BuildContext context, String text, TextStyle? style) {
  final painter = _painter(context, text, style)..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

/// Whether [text] in [style] fits [width] in at most 2 lines.
bool _fitsTwoLines(
  BuildContext context,
  String text,
  TextStyle? style,
  double width,
) {
  final painter = _painter(context, text, style, maxLines: 2)
    ..layout(maxWidth: width);
  final fits = !painter.didExceedMaxLines;
  painter.dispose();
  return fits;
}

/// „2555  +234  2321“: the pin totals and, between them, the lead with its
/// sign (+ home, - guests). While the match runs the pill is hollow
/// and reads „Kuželky zatím +87“, and the totals are [liveTeamTotals].
class _PinsLine extends StatelessWidget {
  const _PinsLine({
    required this.homeTotal,
    required this.awayTotal,
    required this.running,
  });

  final int homeTotal;
  final int awayTotal;

  /// Not final yet: the lead is only „zatím“.
  final bool running;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final total = text.titleLarge?.copyWith(
      fontSize: 22,
      fontWeight: FontWeight.w700,
      color: scheme.onSurface,
      fontFeatures: _tabular,
    );
    final lead = leadLabel(homeTotal - awayTotal);
    // Centred as one piece, and shrunk as one when large text makes it
    // wider than the card.
    return Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$homeTotal', style: total),
            const SizedBox(width: 12),
            _Pill(
              label: running ? 'Kuželky zatím $lead' : lead,
              // Hollow while running: no fill, a 1dp outline.
              fill: running ? null : scheme.secondaryContainer,
              border: running ? BorderSide(color: scheme.outline) : null,
              style: text.titleSmall?.copyWith(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: running ? scheme.onSurface : scheme.onSecondaryContainer,
                fontFeatures: _tabular,
              ),
            ),
            const SizedBox(width: 12),
            Text('$awayTotal', style: total),
          ],
        ),
      ),
    );
  }
}

/// A rounded pill: the status chip, the pin lead and „+2 kuž.“.
class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.style,
    this.fill,
    this.border,
    this.leading,
  });

  final String label;
  final TextStyle? style;
  final Color? fill;

  /// An outline instead of (or on top of) the fill.
  final BorderSide? border;

  /// Before [label], 4dp apart: the live chip's dot.
  final Widget? leading;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: ShapeDecoration(
      color: fill,
      shape: StadiumBorder(side: border ?? BorderSide.none),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: leading == null
          ? Text(label, style: style)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                leading!,
                const SizedBox(width: 4),
                Flexible(child: Text(label, style: style)),
              ],
            ),
    ),
  );
}

/// „6 hráčů · 100 HS · TJ Sokol Rudná“: the format, then the venue — a link
/// with a chevron when [onVenueTap] is set. Nothing when both are empty.
class _Footer extends StatelessWidget {
  const _Footer({
    required this.format,
    required this.venue,
    required this.onVenueTap,
  });

  /// [formatLabel]'s „6 hráčů · 100 HS“, or '' when unknown.
  final String format;

  /// The venue's name, or '' when the slot has none.
  final String venue;

  final VoidCallback? onVenueTap;

  @override
  Widget build(BuildContext context) {
    if (format.isEmpty && venue.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
      fontWeight: FontWeight.w400,
      color: scheme.onSurfaceVariant,
      fontFeatures: _tabular,
    );
    final onVenueTap = this.onVenueTap;
    final Widget line;
    if (onVenueTap == null || venue.isEmpty) {
      line = Text(
        [format, venue].where((s) => s.isNotEmpty).join(' · '),
        textAlign: TextAlign.center,
        style: style,
      );
    } else {
      line = Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (format.isNotEmpty)
            Flexible(child: Text('$format · ', style: style)),
          Flexible(
            child: InkWell(
              onTap: onVenueTap,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        venue,
                        overflow: TextOverflow.ellipsis,
                        style: style,
                      ),
                    ),
                    Icon(
                      Icons.chevron_right,
                      size: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    }
    return Padding(padding: const EdgeInsets.only(top: 8), child: line);
  }
}

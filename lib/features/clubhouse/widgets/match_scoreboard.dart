/// The match detail's scoreboard (Souboje, Task 3): who won and how the
/// score came about. The date and a status chip; the team names around a
/// big score (each over its own score when a name needs more than 2
/// lines); the pin totals with the lead between them; a last line with the
/// format (a team icon and the players a side fields, the throws), the
/// venue, how old the score is („⟳ 22 h“) and the match's page on the site
/// („ČKA“). Every layout of the match detail shares it, so the score never
/// jumps.
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
import 'lead_color.dart';

/// Digits of one width, so a number doesn't jump when a live value changes.
const _tabular = [FontFeature.tabularFigures()];

/// The scoreboard at the top of the match detail — see the library comment.
class MatchScoreboard extends StatelessWidget {
  const MatchScoreboard({
    super.key,
    required this.slot,
    required this.result,
    required this.players,
    this.playersLoading = false,
    required this.now,
    this.onVenueTap,
    this.onSiteTap,
    this.homeColor,
    this.awayColor,
    this.video,
    this.showFreshness = true,
  });

  /// The match: its date and start, the teams and the venue.
  final PrioritySlot slot;

  /// The team-level score; null before the match was first fetched.
  final MatchResult? result;

  /// Both lineups, one row per player; empty until the lineups are out.
  final List<MatchPlayerResult> players;

  /// The lineups are still being read: no „not available“ note yet.
  final bool playersLoading;

  /// The current time: whether the match is live, and the freshness in the
  /// „Živě“ chip.
  final DateTime now;

  /// Null = the venue is plain text (no known venue page).
  final VoidCallback? onVenueTap;

  /// Opens the match's page on the site (vysledky.kuzelky.cz), as „ČKA“
  /// after the venue; null = the match has no page there.
  final VoidCallback? onSiteTap;

  /// The sides' colours the pin lead is printed in; null = green and red.
  final Color? homeColor;
  final Color? awayColor;

  /// The video button (live / recording), when it stands where the status
  /// chip would be; null = the chip.
  final Widget? video;

  /// „⟳ 22 h“ in the last line, before „ČKA“; off where the caller shows
  /// it itself (the kiosk's live view has it in its own row).
  final bool showFreshness;

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
        : players.isEmpty && !playersLoading
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
              date: slot.timeKnown
                  ? '${dayFull(slot.date)} · ${slot.startsAt.display()}'
                  : dayFull(slot.date),
              chip: result == null
                  ? null
                  : live
                  ? 'Živě'
                  : _statusLabel(result.status),
              live: live,
              action: video,
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
                homeColor: homeColor,
                awayColor: awayColor,
              ),
            ],
            _Footer(
              format: formatParts(
                result?.matchType ?? '',
                result?.discipline ?? '',
              ),
              venue: slot.venue ?? '',
              onVenueTap: onVenueTap,
              age: result == null || !showFreshness
                  ? null
                  : ageLabel(result.fetchedAt, now),
              onSiteTap: onSiteTap,
            ),
          ],
        ),
      ),
    );
  }
}

/// The date and start on the left, the status chip (or the video button)
/// on the right; the chip drops under the date when the two don't fit on
/// one line.
class _TopLine extends StatelessWidget {
  const _TopLine({
    required this.date,
    required this.chip,
    required this.live,
    this.action,
  });

  /// „středa 16. 9. · 17:30“.
  final String date;

  /// The chip's text; null = no chip (nothing fetched yet).
  final String? chip;

  /// A live chip sits on errorContainer, so it stands out, with an 8dp dot
  /// before its text (an icon: Manrope has no „●“).
  final bool live;

  /// Stands instead of the chip when set: the video button.
  final Widget? action;

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
        if (action != null)
          action!
        else if (chip != null)
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
            // Name and score sit on ONE baseline (a centred row put the small
            // name above the big digit's foot); a two-line name keeps its
            // first line on it.
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
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
/// sign (+ home, - guests), in that side's colour, without a frame — live
/// and final alike — and the totals are [liveTeamTotals].
class _PinsLine extends StatelessWidget {
  const _PinsLine({
    required this.homeTotal,
    required this.awayTotal,
    this.homeColor,
    this.awayColor,
  });

  final Color? homeColor;
  final Color? awayColor;
  final int homeTotal;
  final int awayTotal;

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
            // Just the signed difference in its side's colour — no frame,
            // no words: it is the same „+94“ live and final.
            Text(
              lead,
              style: text.titleMedium?.copyWith(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color:
                    leadColor(
                      context,
                      lead,
                      homeColor: homeColor,
                      awayColor: awayColor,
                    ) ??
                    scheme.onSurface,
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

/// A rounded pill: the status chip.
class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.style,
    this.fill,
    this.leading,
  });

  final String label;
  final TextStyle? style;
  final Color? fill;

  /// Before [label], 4dp apart: the live chip's dot.
  final Widget? leading;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: ShapeDecoration(
      color: fill,
      shape: const StadiumBorder(),
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

/// „👥 6 · 120 HS · TJ Sokol Rudná › · ⟳ 22 h · ČKA ↗“: the players a side
/// fields (the team icon is Klubovna's) and the throws, the venue — a link
/// with a chevron when [onVenueTap] is set — how old the score is, and the
/// match's page on the site. Whatever is unknown is left out; nothing at all
/// when everything is. A Wrap: at a large text size the pieces flow onto a
/// second line instead of overflowing.
class _Footer extends StatelessWidget {
  const _Footer({
    required this.format,
    required this.venue,
    required this.onVenueTap,
    required this.age,
    required this.onSiteTap,
  });

  /// [formatParts] of the match; either half may be null.
  final ({int? players, String? throws}) format;

  /// The venue's name, or '' when the slot has none.
  final String venue;

  final VoidCallback? onVenueTap;

  /// [ageLabel] of the score; null = not shown.
  final String? age;

  final VoidCallback? onSiteTap;

  @override
  Widget build(BuildContext context) {
    final onVenueTap = this.onVenueTap;
    final onSiteTap = this.onSiteTap;
    final players = format.players;
    final throws = format.throws;
    final age = this.age;
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
      fontWeight: FontWeight.w400,
      color: scheme.onSurfaceVariant,
      fontFeatures: _tabular,
    );

    /// [label] after or before an [icon], 14dp, in the line's colour.
    Widget withIcon(IconData icon, String label, {bool iconFirst = true}) {
      final glyph = Icon(icon, size: 14, color: scheme.onSurfaceVariant);
      final text = Flexible(
        child: Text(label, overflow: TextOverflow.ellipsis, style: style),
      );
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: iconFirst
            ? [glyph, const SizedBox(width: 3), text]
            : [text, glyph],
      );
    }

    /// A tappable [child]; 4dp of padding keeps the tap target off the
    /// text's edge.
    Widget link(Widget child, VoidCallback onTap) => InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: child,
      ),
    );

    final pieces = <Widget>[
      if (players != null)
        Semantics(
          label:
              '$players ${players == 1
                  ? 'hráč'
                  : players <= 4
                  ? 'hráči'
                  : 'hráčů'}',
          excludeSemantics: true,
          child: withIcon(Icons.groups, '$players'),
        ),
      if (throws != null) Text(throws, style: style),
      if (venue.isNotEmpty)
        if (onVenueTap == null)
          Text(venue, style: style)
        else
          link(
            withIcon(Icons.chevron_right, venue, iconFirst: false),
            onVenueTap,
          ),
      if (age != null)
        Semantics(
          container: true,
          label: 'výsledky z webu: $age',
          excludeSemantics: true,
          child: withIcon(Icons.refresh, age),
        ),
      if (onSiteTap != null)
        link(withIcon(Icons.open_in_new, 'ČKA', iconFirst: false), onSiteTap),
    ];
    if (pieces.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (var i = 0; i < pieces.length; i++) ...[
            if (i > 0) Text(' · ', style: style),
            pieces[i],
          ],
        ],
      ),
    );
  }
}

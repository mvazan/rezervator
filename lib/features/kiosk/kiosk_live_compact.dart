/// The kiosk's denser ways to draw a match being played (Správa → Kiosk →
/// Zobrazení aktuálního zápasu): the whole match without scrolling.
///
/// - [KioskLiveCompact]: the score, then one block per duel — the two
///   names, the totals and the lead; a tap opens that duel as the match
///   detail's full card with its lane table, one duel at a time.
/// - [KioskLiveTable]: the score, then every duel a single table row; a tap
///   opens the lanes under the row, one at a time.
///
/// No date, live chip, format line or difference bar: on the wall the
/// score and the totals are what is read from across the room.
library;

import 'package:flutter/material.dart';

import '../../domain/duels.dart';
import '../../domain/models.dart';
import '../../domain/results.dart';
import '../../domain/palette.dart';
import '../clubhouse/widgets/duel_card.dart';
import '../clubhouse/widgets/lead_color.dart';

const _tabular = [FontFeature.tabularFigures()];

/// The score of the match: the teams around the points, „průběžně“, and
/// the pins with their lead.
class KioskLiveScore extends StatelessWidget {
  const KioskLiveScore({
    super.key,
    required this.slot,
    required this.result,
    required this.duels,
  });

  final PrioritySlot slot;
  final MatchResult? result;
  final List<Duel> duels;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final live = liveTeamTotals(duels);
    final pinsHome = live?.home ?? result?.homeTotal;
    final pinsAway = live?.away ?? result?.awayTotal;
    final lead = pinsHome == null || pinsAway == null
        ? ''
        : leadLabel(pinsHome - pinsAway);
    TextStyle team = const TextStyle(fontSize: 17, fontWeight: FontWeight.w600);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  slot.homeTeam,
                  textAlign: TextAlign.right,
                  maxLines: 2,
                  style: team,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  pointsLabel(result?.homePoints ?? 0, result?.awayPoints ?? 0),
                  style: const TextStyle(
                    fontSize: 40,
                    fontWeight: FontWeight.w800,
                    fontFeatures: _tabular,
                  ),
                ),
              ),
              Expanded(child: Text(slot.awayTeam, maxLines: 2, style: team)),
            ],
          ),
          if (pinsHome != null && pinsAway != null)
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '$pinsHome  '),
                  TextSpan(
                    text: lead == ':' ? '' : lead,
                    style: TextStyle(color: leadColor(context, lead)),
                  ),
                  TextSpan(text: '  $pinsAway'),
                ],
              ),
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                fontFeatures: _tabular,
              ),
            ),
        ],
      ),
    );
  }
}

/// The lanes of one duel on one line: „1. 62 : 68 · 2. 59 : 60 · …“, the
/// lane winner's total in bold.
class _Lanes extends StatelessWidget {
  const _Lanes({required this.duel});

  final Duel duel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final spans = <InlineSpan>[];
    for (final l in duel.lanes) {
      final h = l.home?.total;
      final a = l.away?.total;
      if (spans.isNotEmpty) {
        spans.add(
          TextSpan(
            text: '   ',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        );
      }
      spans
        ..add(
          TextSpan(
            text: '${l.lane}. ',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        )
        ..add(
          TextSpan(
            text: h?.toString() ?? '–',
            style: TextStyle(
              fontWeight: h != null && a != null && h > a
                  ? FontWeight.w800
                  : FontWeight.w400,
            ),
          ),
        )
        ..add(const TextSpan(text: ' : '))
        ..add(
          TextSpan(
            text: a?.toString() ?? '–',
            style: TextStyle(
              fontWeight: h != null && a != null && a > h
                  ? FontWeight.w800
                  : FontWeight.w400,
            ),
          ),
        );
    }
    return Text.rich(
      TextSpan(children: spans),
      style: const TextStyle(fontSize: 15, fontFeatures: _tabular),
    );
  }
}

/// The compact view: a block per duel, one opened to its lanes at a time.
class KioskLiveCompact extends StatefulWidget {
  const KioskLiveCompact({
    super.key,
    required this.slot,
    required this.result,
    required this.duels,
    this.onOpenZapis,
  });

  /// A tap on the score; null when there is no Zápis to show.
  final VoidCallback? onOpenZapis;

  final PrioritySlot slot;
  final MatchResult? result;
  final List<Duel> duels;

  @override
  State<KioskLiveCompact> createState() => _KioskLiveCompactState();
}

class _KioskLiveCompactState extends State<KioskLiveCompact> {
  int? _open;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // The score stays put; the duels scroll under it if they must.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          onTap: widget.onOpenZapis,
          child: KioskLiveScore(
            slot: widget.slot,
            result: widget.result,
            duels: widget.duels,
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final duel in widget.duels) ...[
                  const SizedBox(height: 6),
                  _compactDuel(context, scheme, duel),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _compactDuel(BuildContext context, ColorScheme scheme, Duel duel) {
    final waiting = duel.state == DuelState.waiting;
    final open = _open == duel.position;
    // The one opened duel is the match detail's full card with its lane
    // table (Plné, Dor., Ch., Celkem); a tap folds it back.
    if (open) {
      final scale = diffScale(widget.duels);
      return DuelCard(
        duel: duel,
        scale: scale,
        expanded: true,
        onTap: () => setState(() => _open = null),
        homeColor: homeSideColor,
        awayColor: awaySideColor,
        showSetPoints: setPointsMatter(widget.result?.discipline),
      );
    }
    final lead = leadLabel(duel.diff);
    final done = duel.state == DuelState.done;
    TextStyle total(bool winner) => TextStyle(
      fontSize: 26,
      fontWeight: done && winner ? FontWeight.w800 : FontWeight.w400,
      fontFeatures: _tabular,
    );
    final homeWins = (duel.diff ?? 0) > 0;
    final awayWins = (duel.diff ?? 0) < 0;
    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        side: BorderSide(
          color: duel.state == DuelState.playing
              ? scheme.primary
              : scheme.outlineVariant,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: waiting
            ? null
            : () => setState(() => _open = open ? null : duel.position),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      duel.home?.playerName ?? '–',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      duel.away?.playerName ?? '–',
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  Text(
                    duel.shownHome?.toString() ?? '–',
                    style: total(homeWins),
                  ),
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          waiting ? 'čeká' : (lead == ':' ? '0' : lead),
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: waiting
                                ? scheme.onSurfaceVariant
                                : leadColor(context, lead),
                          ),
                        ),
                        if (!waiting)
                          Icon(
                            Icons.expand_more,
                            size: 20,
                            color: scheme.onSurfaceVariant,
                          ),
                      ],
                    ),
                  ),
                  Text(
                    duel.shownAway?.toString() ?? '–',
                    style: total(awayWins),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The table view: every duel one row — names, totals, lead — and one
/// opened to its lanes at a time.
class KioskLiveTable extends StatefulWidget {
  const KioskLiveTable({
    super.key,
    required this.slot,
    required this.result,
    required this.duels,
    this.onOpenZapis,
  });

  /// A tap on the score; null when there is no Zápis to show.
  final VoidCallback? onOpenZapis;

  final PrioritySlot slot;
  final MatchResult? result;
  final List<Duel> duels;

  @override
  State<KioskLiveTable> createState() => _KioskLiveTableState();
}

class _KioskLiveTableState extends State<KioskLiveTable> {
  int? _open;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // The score stays put; the rows scroll under it if they must.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          onTap: widget.onOpenZapis,
          child: KioskLiveScore(
            slot: widget.slot,
            result: widget.result,
            duels: widget.duels,
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < widget.duels.length; i++)
                  _row(context, scheme, widget.duels[i], i.isOdd),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, ColorScheme scheme, Duel duel, bool odd) {
    final waiting = duel.state == DuelState.waiting;
    final open = _open == duel.position;
    final lead = leadLabel(duel.diff);
    final done = duel.state == DuelState.done;
    final homeWins = (duel.diff ?? 0) > 0;
    final awayWins = (duel.diff ?? 0) < 0;
    TextStyle total(bool winner) => TextStyle(
      fontSize: 18,
      fontWeight: done && winner ? FontWeight.w800 : FontWeight.w500,
      fontFeatures: _tabular,
    );
    String surname(MatchPlayerResult? p) => surnameOf(p?.playerName);
    return Material(
      color: odd
          ? scheme.surfaceContainerHighest.withValues(alpha: 0.4)
          : Colors.transparent,
      child: InkWell(
        onTap: waiting
            ? null
            : () => setState(() => _open = open ? null : duel.position),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Column(
            children: [
              Row(
                children: [
                  if (duel.state == DuelState.playing)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(Icons.circle, size: 8, color: scheme.error),
                    ),
                  Expanded(
                    flex: 3,
                    child: Text(
                      surname(duel.home),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15),
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(
                      duel.shownHome?.toString() ?? '–',
                      textAlign: TextAlign.right,
                      style: total(homeWins),
                    ),
                  ),
                  SizedBox(
                    width: 52,
                    child: Text(
                      waiting ? '–' : (lead == ':' ? '0' : lead),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color:
                            leadColor(context, lead) ?? scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(
                      duel.shownAway?.toString() ?? '–',
                      style: total(awayWins),
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(
                      surname(duel.away),
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15),
                    ),
                  ),
                ],
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                alignment: Alignment.topCenter,
                child: open
                    ? Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: _Lanes(duel: duel),
                      )
                    : const SizedBox(width: double.infinity),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

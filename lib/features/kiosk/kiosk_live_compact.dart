/// The kiosk's denser ways to draw a match being played (Správa → Kiosk →
/// Zobrazení aktuálního zápasu): the whole match without scrolling.
///
/// - [KioskLiveCompact]: the score, then one block per duel — the two
///   names, the totals and the lead; a tap opens that duel as the match
///   detail's full card with its lane table.
/// - [KioskLiveTable]: the score, then every duel a single table row; a tap
///   opens it as the same full card.
///
/// Several duels may be open while they fit; see [_FifoOpen].
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

/// Several duels may be open at once, as long as they all fit: when the
/// list would have to scroll, the duel opened first folds back (first in,
/// first out) until it fits again or one duel is left open.
mixin _FifoOpen<T extends StatefulWidget> on State<T> {
  final opened = <int>[];
  final scroll = ScrollController();

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  void toggle(int position) {
    setState(() {
      if (!opened.remove(position)) opened.add(position);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _fit());
  }

  void _fit() {
    if (!mounted || !scroll.hasClients || opened.length < 2) return;
    if (scroll.position.maxScrollExtent <= 0) return;
    setState(() => opened.removeAt(0));
    WidgetsBinding.instance.addPostFrameCallback((_) => _fit());
  }

  /// The full card of an open duel — the match detail's, with its lane
  /// table; a tap folds it.
  Widget openCard(Duel duel, List<Duel> duels, MatchResult? result) => DuelCard(
    duel: duel,
    scale: diffScale(duels),
    expanded: true,
    onTap: () => toggle(duel.position),
    homeColor: homeSideColor,
    awayColor: awaySideColor,
    showSetPoints: setPointsMatter(result?.discipline),
  );
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

class _KioskLiveCompactState extends State<KioskLiveCompact> with _FifoOpen {
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
            controller: scroll,
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
    if (opened.contains(duel.position)) {
      return openCard(duel, widget.duels, widget.result);
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
        onTap: waiting ? null : () => toggle(duel.position),
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

class _KioskLiveTableState extends State<KioskLiveTable> with _FifoOpen {
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
            controller: scroll,
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
    if (opened.contains(duel.position)) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: openCard(duel, widget.duels, widget.result),
      );
    }
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
        onTap: waiting ? null : () => toggle(duel.position),
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
            ],
          ),
        ),
      ),
    );
  }
}

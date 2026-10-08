/// The denser ways to draw a match's duels, shared by the kiosk's live
/// match (Správa → Kiosk → Zobrazení aktuálního zápasu) and the app's match
/// detail (Můj profil → Detail zápasu): the whole match fitted to the
/// screen, no scrolling while it is not needed.
///
/// - [DuelsCompact]: one block per duel — the two names, the totals and the
///   lead; a tap opens that duel as the match detail's full card with its
///   lane table.
/// - [DuelsTable]: every duel a single table row; a tap opens it as the
///   same full card.
/// - [MatchScoreLine]: the score the kiosk pins above either (the app pins
///   its own scoreboard instead).
///
/// Several duels may be open while they fit; see [_FifoOpen].
///
/// No date, live chip, format line or difference bar: on the wall the
/// score and the totals are what is read from across the room.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../domain/duels.dart';
import '../../../domain/models.dart';
import '../../../domain/palette.dart';
import '../../../domain/results.dart';
import 'duel_card.dart';
import 'lead_color.dart';

const _tabular = [FontFeature.tabularFigures()];

/// How long a duel takes to open or fold.
const _expandDuration = Duration(milliseconds: 260);

/// The score of the match: the teams around the points, and the pins with
/// their lead.
class MatchScoreLine extends StatelessWidget {
  const MatchScoreLine({
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
    const team = TextStyle(fontSize: 17, fontWeight: FontWeight.w600);
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
  Timer? _settle;

  @override
  void dispose() {
    _settle?.cancel();
    scroll.dispose();
    super.dispose();
  }

  void toggle(int position) {
    setState(() {
      if (!opened.remove(position)) opened.add(position);
    });
    _fitWhenSettled();
  }

  /// Measures once the opening has animated to its full height — again on
  /// every change of the list's height (a card still growing, a live score
  /// adding a lane), so the check runs after the last one.
  void _fitWhenSettled() {
    _settle?.cancel();
    _settle = Timer(_expandDuration + const Duration(milliseconds: 60), _fit);
  }

  void _fit() {
    if (!mounted || !scroll.hasClients || opened.length < 2) return;
    if (scroll.position.maxScrollExtent <= 0) return;
    setState(() => opened.removeAt(0));
    _fitWhenSettled();
  }

  /// [scrollView] watched for its height: whenever it would have to
  /// scroll, the fit is checked once it settles.
  Widget fitting(Widget scrollView) =>
      NotificationListener<ScrollMetricsNotification>(
        onNotification: (n) {
          if (n.metrics.maxScrollExtent > 0) _fitWhenSettled();
          return false;
        },
        child: scrollView,
      );

  /// [closed] or [open] by [isOpen], the change animated: the height grows
  /// or shrinks while the two cross-fade.
  Widget animatedDuel({
    required bool isOpen,
    required Widget closed,
    required Widget open,
  }) => AnimatedCrossFade(
    duration: _expandDuration,
    sizeCurve: Curves.easeInOutCubic,
    crossFadeState: isOpen
        ? CrossFadeState.showSecond
        : CrossFadeState.showFirst,
    firstChild: closed,
    secondChild: open,
  );

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

/// What a closed duel looks like in one of the fitted lists: [duel] at
/// [index], [toggle] opens it.
typedef _ClosedDuelBuilder =
    Widget Function(BuildContext context, Duel duel, int index, VoidCallback toggle);

/// The frame both fitted lists share: [header] pinned on top, the duels
/// under it in a list that scrolls only if it must — and folds open duels
/// until it need not ([_FifoOpen]). With [onRefresh] the list pulls to
/// refresh, like the match detail's own.
class _FittedDuels extends StatefulWidget {
  const _FittedDuels({
    required this.duels,
    required this.result,
    required this.header,
    required this.closed,
    this.gapBeforeEach = 0,
    this.gapAfterHeader = 0,
    this.openPadding = EdgeInsets.zero,
    required this.onRefresh,
  });

  final List<Duel> duels;
  final MatchResult? result;
  final Widget? header;
  final _ClosedDuelBuilder closed;

  /// Space above every duel ([DuelsCompact]), and between the header and
  /// the first row ([DuelsTable]).
  final double gapBeforeEach;
  final double gapAfterHeader;

  /// Around an open card, when the closed rows have none of their own.
  final EdgeInsets openPadding;
  final Future<void> Function()? onRefresh;

  @override
  State<_FittedDuels> createState() => _FittedDuelsState();
}

class _FittedDuelsState extends State<_FittedDuels> with _FifoOpen {
  @override
  Widget build(BuildContext context) {
    Widget list = SingleChildScrollView(
      controller: scroll,
      physics: widget.onRefresh == null
          ? null
          : const AlwaysScrollableScrollPhysics(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.gapAfterHeader > 0)
            SizedBox(height: widget.gapAfterHeader),
          for (var i = 0; i < widget.duels.length; i++) ...[
            if (widget.gapBeforeEach > 0)
              SizedBox(height: widget.gapBeforeEach),
            animatedDuel(
              isOpen: opened.contains(widget.duels[i].position),
              closed: widget.closed(
                context,
                widget.duels[i],
                i,
                () => toggle(widget.duels[i].position),
              ),
              open: Padding(
                padding: widget.openPadding,
                child: openCard(widget.duels[i], widget.duels, widget.result),
              ),
            ),
          ],
        ],
      ),
    );
    if (widget.onRefresh case final refresh?) {
      list = RefreshIndicator(onRefresh: refresh, child: list);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ?widget.header,
        Expanded(child: fitting(list)),
      ],
    );
  }
}

/// The compact view: a block per duel, the open ones as full cards.
class DuelsCompact extends StatelessWidget {
  const DuelsCompact({
    super.key,
    required this.duels,
    required this.result,
    this.header,
    this.onRefresh,
  });

  final List<Duel> duels;
  final MatchResult? result;

  /// Pinned above the duels: the kiosk's [MatchScoreLine], the app's
  /// scoreboard and buttons.
  final Widget? header;

  /// Pull to refresh on the duels, when the caller has a refresh.
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) => _FittedDuels(
    duels: duels,
    result: result,
    header: header,
    gapBeforeEach: 6,
    onRefresh: onRefresh,
    closed: (context, duel, _, toggle) => _CompactDuel(duel: duel, onTap: toggle),
  );
}

class _CompactDuel extends StatelessWidget {
  const _CompactDuel({required this.duel, required this.onTap});

  final Duel duel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final waiting = duel.state == DuelState.waiting;
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
        // A duel nobody has started has nothing to open.
        onTap: waiting ? null : onTap,
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

/// The table view: every duel one row — names, totals, lead — the open
/// ones as full cards.
class DuelsTable extends StatelessWidget {
  const DuelsTable({
    super.key,
    required this.duels,
    required this.result,
    this.header,
    this.onRefresh,
  });

  final List<Duel> duels;
  final MatchResult? result;

  /// Pinned above the rows; see [DuelsCompact.header].
  final Widget? header;

  /// Pull to refresh on the rows, when the caller has a refresh.
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) => _FittedDuels(
    duels: duels,
    result: result,
    header: header,
    gapAfterHeader: header == null ? 0 : 8,
    openPadding: const EdgeInsets.symmetric(vertical: 4),
    onRefresh: onRefresh,
    closed: (context, duel, index, toggle) =>
        _TableRow(duel: duel, odd: index.isOdd, onTap: toggle),
  );
}

class _TableRow extends StatelessWidget {
  const _TableRow({
    required this.duel,
    required this.odd,
    required this.onTap,
  });

  final Duel duel;
  final bool odd;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final waiting = duel.state == DuelState.waiting;
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
        onTap: waiting ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
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
                    color: leadColor(context, lead) ?? scheme.onSurfaceVariant,
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
        ),
      ),
    );
  }
}

/// The kiosk's „Zápis“: one match's score sheet ([ZapisPage]) in a modal. A
/// tap anywhere counts as touching the kiosk (the shell's idle timer is
/// outside this route), and the idle reset closes it. With paging on
/// (0079) the modal pages through the matches: a bar above the sheet with
/// ‹ › in time, the two teams — a tap lists that team's matches — and a ×.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/kiosk_panel.dart';
import '../../domain/models.dart';
import '../../domain/results.dart';
import '../clubhouse/widgets/zapis_page.dart';

/// A match's ▶: the label of its button and what it does.
typedef KioskZapisPlay = ({String label, VoidCallback onPlay});

/// Opens [slot]'s Zápis in a modal covering [percent] of the screen, fading
/// in (no slide); a tap outside closes it. At 100 % there is no outside, so
/// a close button appears. [onTouch] is the shell's „somebody touched the
/// kiosk“. [playFor] gives the match shown its ▶ — one with a video — a
/// button that closes the Zápis and opens the stream („Sledovat živě“,
/// „Přehrát záznam“); null = none. [paging] (0079) adds the bar that pages
/// through the matches, with a × at any size.
Future<void> showKioskZapis(
  BuildContext context, {
  required PrioritySlot slot,
  required Brightness brightness,
  required int percent,
  required VoidCallback onTouch,
  KioskZapisPlay? Function(PrioritySlot match)? playFor,
  bool paging = false,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Zavřít',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 250),
    transitionBuilder: (context, animation, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: child,
    ),
    pageBuilder: (context, _, _) {
      final size = MediaQuery.sizeOf(context);
      final full = percent >= 100;
      return Listener(
        onPointerDown: (_) => onTouch(),
        onPointerSignal: (_) => onTouch(),
        onPointerPanZoomStart: (_) => onTouch(),
        behavior: HitTestBehavior.translucent,
        child: Theme(
          data: buildTheme(brightness),
          child: Center(
            child: SizedBox(
              width: size.width * percent / 100,
              height: size.height * percent / 100,
              child: Material(
                clipBehavior: Clip.antiAlias,
                borderRadius: BorderRadius.circular(full ? 0 : 16),
                elevation: 8,
                child: _KioskZapis(
                  slot: slot,
                  full: full,
                  playFor: playFor,
                  paging: paging,
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _KioskZapis extends ConsumerStatefulWidget {
  const _KioskZapis({
    required this.slot,
    required this.full,
    required this.playFor,
    required this.paging,
  });

  final PrioritySlot slot;
  final bool full;
  final KioskZapisPlay? Function(PrioritySlot match)? playFor;
  final bool paging;

  @override
  ConsumerState<_KioskZapis> createState() => _KioskZapisState();
}

class _KioskZapisState extends ConsumerState<_KioskZapis> {
  late PrioritySlot _slot = widget.slot;

  /// The team whose matches are listed over the sheet; null = none.
  String? _listFor;

  void _show(PrioritySlot match) => setState(() {
    _slot = match;
    _listFor = null;
  });

  void _toggleList(String team) =>
      setState(() => _listFor = _listFor == team ? null : team);

  @override
  Widget build(BuildContext context) {
    final play = widget.playFor?.call(_slot);
    final sheet = ZapisPage(
      key: ValueKey(_slot.id),
      slot: _slot,
      // With the bar, its × closes at any size.
      closeButton: widget.full && !widget.paging,
      withRegnums: true,
      // The shell hides the bars for the kiosk's whole stay.
      hideSystemBars: false,
    );
    if (!widget.paging) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // A strip of its own above the sheet: the sheet fills its box
          // edge to edge, a button over it would hide the away team's
          // totals.
          if (play != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: SafeArea(
                bottom: false,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: _PlayButton(play: play),
                ),
              ),
            ),
          Expanded(child: sheet),
        ],
      );
    }

    final results =
        ref.watch(matchResultsProvider).value ?? const <String, MatchResult>{};
    final matches = kioskZapisMatches(
      ref.watch(prioritySlotsProvider),
      results,
    );
    final at = matches.indexWhere((m) => m.id == _slot.id);
    // A match not on the list (no score any more) still has neighbours:
    // the last one before it and the first one after it.
    final before = at >= 0
        ? at
        : matches.where((m) => _order(m, _slot) < 0).length;
    final previous = before > 0 ? matches[before - 1] : null;
    final afterAt = at >= 0 ? at + 1 : before;
    final next = afterAt < matches.length ? matches[afterAt] : null;
    final listed = _listFor;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SafeArea(
          bottom: false,
          child: _Bar(
            slot: _slot,
            previous: previous,
            next: next,
            listed: listed,
            play: play,
            onShow: _show,
            onTeam: _toggleList,
          ),
        ),
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              sheet,
              if (listed != null) ...[
                // A tap beside the list closes it.
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _listFor = null),
                  child: const ColoredBox(color: Colors.black26),
                ),
                Align(
                  alignment: listed == _slot.awayTeam
                      ? Alignment.topRight
                      : Alignment.topLeft,
                  child: _TeamMatches(
                    team: listed,
                    matches: kioskTeamMatches(matches, listed),
                    results: results,
                    shown: _slot,
                    onShow: _show,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// [a] before [b] in the list's order: day, start, title.
  static int _order(PrioritySlot a, PrioritySlot b) {
    final byDay = a.date.compareTo(b.date);
    if (byDay != 0) return byDay;
    return a.startsAt.compareTo(b.startsAt);
  }
}

/// The paging bar: ‹, the home team, the day, the away team, ›, the ▶ and
/// the ×. The teams are buttons that list their matches.
class _Bar extends StatelessWidget {
  const _Bar({
    required this.slot,
    required this.previous,
    required this.next,
    required this.listed,
    required this.play,
    required this.onShow,
    required this.onTeam,
  });

  final PrioritySlot slot;
  final PrioritySlot? previous;
  final PrioritySlot? next;
  final String? listed;
  final KioskZapisPlay? play;
  final void Function(PrioritySlot match) onShow;
  final void Function(String team) onTeam;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget team(String name) => Flexible(
      child: OutlinedButton(
        onPressed: () => onTeam(name),
        style: OutlinedButton.styleFrom(
          backgroundColor: listed == name ? scheme.secondaryContainer : null,
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(
              listed == name ? Icons.arrow_drop_up : Icons.arrow_drop_down,
            ),
          ],
        ),
      ),
    );
    final previous = this.previous;
    final next = this.next;
    final play = this.play;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
      child: Row(
        children: [
          IconButton(
            iconSize: 32,
            tooltip: 'Předchozí zápas',
            onPressed: previous == null ? null : () => onShow(previous),
            icon: const Icon(Icons.chevron_left),
          ),
          team(slot.homeTeam),
          Expanded(
            child: Text(
              dayFull(slot.date),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
          team(slot.awayTeam),
          IconButton(
            iconSize: 32,
            tooltip: 'Další zápas',
            onPressed: next == null ? null : () => onShow(next),
            icon: const Icon(Icons.chevron_right),
          ),
          if (play != null) ...[
            const SizedBox(width: 4),
            _PlayButton(play: play),
          ],
          IconButton(
            iconSize: 28,
            tooltip: 'Zavřít',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}

/// [team]'s matches with a score, chronological — the one shown picked
/// out and scrolled into view; a tap shows that one.
class _TeamMatches extends StatefulWidget {
  const _TeamMatches({
    required this.team,
    required this.matches,
    required this.results,
    required this.shown,
    required this.onShow,
  });

  final String team;
  final List<PrioritySlot> matches;
  final Map<String, MatchResult> results;
  final PrioritySlot shown;
  final void Function(PrioritySlot match) onShow;

  @override
  State<_TeamMatches> createState() => _TeamMatchesState();
}

class _TeamMatchesState extends State<_TeamMatches> {
  static const _rowHeight = 64.0;

  // The shown match in view, a row of the earlier ones above it.
  late final _scroll = ScrollController(
    initialScrollOffset: () {
      final at = widget.matches.indexWhere((m) => m.id == widget.shown.id);
      return at > 0 ? (at - 1) * _rowHeight : 0.0;
    }(),
  );

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final team = widget.team;
    final matches = widget.matches;
    final results = widget.results;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Material(
        key: const Key('kiosk-zapis-team-matches'),
        elevation: 6,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 420,
            maxHeight: MediaQuery.sizeOf(context).height * 0.6,
          ),
          child: ListView.builder(
            shrinkWrap: true,
            itemExtent: _rowHeight,
            controller: _scroll,
            itemCount: matches.length,
            itemBuilder: (context, i) {
              final m = matches[i];
              final home = m.homeTeam == team;
              final r = results[m.id];
              // The score from [team]'s side: its points first.
              final score = home
                  ? pointsLabel(r?.homePoints, r?.awayPoints)
                  : pointsLabel(r?.awayPoints, r?.homePoints);
              return ListTile(
                selected: m.id == widget.shown.id,
                title: Text(
                  home ? m.awayTeam : m.homeTeam,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${dayLabel(m.date)} · ${home ? 'doma' : 'venku'}',
                ),
                trailing: Text(
                  score,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                onTap: () => widget.onShow(m),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.play});

  final KioskZapisPlay play;

  @override
  Widget build(BuildContext context) => FilledButton.tonalIcon(
    onPressed: () {
      Navigator.of(context).pop();
      play.onPlay();
    },
    icon: const Icon(Icons.play_arrow),
    label: Text(play.label),
  );
}

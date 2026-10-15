/// The kiosk's „Zápis“: one match's score sheet ([ZapisPage]) in a modal. A
/// tap anywhere counts as touching the kiosk (the shell's idle timer is
/// outside this route), and the idle reset closes it. With paging (0079)
/// the modal pages through the matches with a score, one of two ways
/// ([KioskZapisNav]): a bar above the sheet — ‹ ›, the teams (a tap lists
/// that team's matches), the day, a × — or ‹ › beside the modal (floating
/// over the sheet at full screen) with a tap on a team's name in the sheet
/// for its matches. A swipe across the sheet pages like the arrows.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../core/ui.dart';
import '../../core/widgets/shown_names.dart';
import '../../data/providers.dart';
import '../../domain/kiosk_panel.dart';
import '../../domain/models.dart';
import '../../domain/results.dart';
import '../clubhouse/widgets/zapis_page.dart';
import 'kiosk_info_panel.dart' show KioskBreathingIcon;

/// A match's ▶: the label of its button and what it does.
typedef KioskZapisPlay = ({String label, VoidCallback onPlay});

/// Opens [slot]'s Zápis in a modal covering [percent] of the screen, fading
/// in (no slide); a tap outside closes it. [onTouch] is the shell's
/// „somebody touched the kiosk“. [playFor] gives the match shown its ▶ — one
/// with a video — a button that closes the Zápis and opens the stream
/// („Sledovat živě“, „Přehrát záznam“); null = none. [nav] (0079): how the
/// Zápis pages through the matches; [KioskZapisNav.off] = the bare sheet,
/// with a × only at 100 %, where there is no outside to tap.
Future<void> showKioskZapis(
  BuildContext context, {
  required PrioritySlot slot,
  required Brightness brightness,
  required int percent,
  required VoidCallback onTouch,
  KioskZapisPlay? Function(PrioritySlot match)? playFor,
  KioskZapisNav nav = KioskZapisNav.off,
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
    pageBuilder: (context, _, _) => Listener(
      onPointerDown: (_) => onTouch(),
      onPointerSignal: (_) => onTouch(),
      onPointerPanZoomStart: (_) => onTouch(),
      behavior: HitTestBehavior.translucent,
      child: Theme(
        data: buildTheme(brightness),
        child: _KioskZapis(
          slot: slot,
          percent: percent,
          playFor: playFor,
          nav: nav,
        ),
      ),
    ),
  );
}

class _KioskZapis extends ConsumerStatefulWidget {
  const _KioskZapis({
    required this.slot,
    required this.percent,
    required this.playFor,
    required this.nav,
  });

  final PrioritySlot slot;
  final int percent;
  final KioskZapisPlay? Function(PrioritySlot match)? playFor;
  final KioskZapisNav nav;

  @override
  ConsumerState<_KioskZapis> createState() => _KioskZapisState();
}

class _KioskZapisState extends ConsumerState<_KioskZapis> {
  late PrioritySlot _slot = widget.slot;

  /// The team whose matches are listed over the sheet; null = none.
  String? _listFor;

  /// The arrows over the sheet and the ×, beside the arrows: a tap on the
  /// sheet hides them, another brings them back ([KioskZapisNav.sides]).
  bool _controls = true;

  void _show(PrioritySlot match) => setState(() {
    _slot = match;
    _listFor = null;
  });

  void _toggleList(String team) =>
      setState(() => _listFor = _listFor == team ? null : team);

  /// A side arrow's width beside the modal, and its gap to the modal's
  /// edge; with less room than both, the arrows float over the sheet as at
  /// full screen.
  static const _sideRoom = 56.0;
  static const _sideGap = 4.0;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final full = widget.percent >= 100;
    final box = Size(
      size.width * widget.percent / 100,
      size.height * widget.percent / 100,
    );
    Widget modal(Widget child) => Center(
      child: SizedBox.fromSize(
        size: box,
        child: Material(
          clipBehavior: Clip.antiAlias,
          borderRadius: BorderRadius.circular(full ? 0 : 16),
          elevation: 8,
          child: child,
        ),
      ),
    );
    final play = widget.playFor?.call(_slot);

    if (widget.nav == KioskZapisNav.off) {
      return modal(
        Column(
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
            Expanded(
              child: ZapisPage(
                key: ValueKey(_slot.id),
                slot: _slot,
                closeButton: full,
                withRegnums: true,
                // The shell hides the bars for the kiosk's whole stay.
                hideSystemBars: false,
              ),
            ),
          ],
        ),
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
    void page(int direction) {
      final to = direction > 0 ? next : previous;
      if (to != null) _show(to);
    }

    final sheet = ZapisPage(
      key: ValueKey(_slot.id),
      slot: _slot,
      withRegnums: true,
      hideSystemBars: false,
      // The bar lists a team from its button; beside, from its name.
      onTeam: widget.nav == KioskZapisNav.sides ? _toggleList : null,
      onSwipe: page,
    );
    final listed = _listFor;
    final list = <Widget>[
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
    ];

    if (widget.nav == KioskZapisNav.bar) {
      return modal(
        Column(
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
              child: Stack(fit: StackFit.expand, children: [sheet, ...list]),
            ),
          ],
        ),
      );
    }

    // Beside the modal: in the room the screen leaves around it, or — at
    // full screen, or with too little room — floating over the sheet's
    // edges, hidden and shown with the × by a tap on the sheet.
    final room = (size.width - box.width) / 2;
    final floating = full || room < _sideRoom + _sideGap;
    // The side panel's „Opakující se animace“ (0065) holds for these too.
    final breathe = ref.watch(
      settingsProvider.select((s) => s.value?.kioskAnimations ?? true),
    );
    Widget faded(Widget child) => AnimatedOpacity(
      opacity: _controls ? 1 : 0,
      duration: const Duration(milliseconds: 200),
      child: IgnorePointer(ignoring: !_controls, child: child),
    );
    Widget arrow(bool forward) {
      final to = forward ? next : previous;
      return _SideArrow(
        forward: forward,
        floating: floating,
        breathe: breathe,
        onTap: to == null ? null : () => _show(to),
      );
    }

    final content = Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => setState(() => _controls = !_controls),
          child: sheet,
        ),
        if (floating) ...[
          Align(alignment: Alignment.centerLeft, child: faded(arrow(false))),
          Align(alignment: Alignment.centerRight, child: faded(arrow(true))),
        ],
        Positioned(
          top: 8,
          right: 8,
          child: SafeArea(
            child: faded(
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (play != null) ...[
                    _PlayButton(play: play),
                    const SizedBox(width: 8),
                  ],
                  _Disc(
                    tooltip: 'Zavřít',
                    onTap: () => Navigator.of(context).pop(),
                    child: const Icon(Icons.close, size: _Disc.iconSize),
                  ),
                ],
              ),
            ),
          ),
        ),
        ...list,
      ],
    );
    if (floating) return modal(content);
    return Stack(
      children: [
        modal(content),
        // Right beside the modal's edges.
        for (final forward in [false, true])
          Positioned(
            top: 0,
            bottom: 0,
            left: forward ? null : room - _sideGap - _sideRoom,
            right: forward ? room - _sideGap - _sideRoom : null,
            width: _sideRoom,
            child: Center(child: arrow(forward)),
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

/// ‹ or › beside the Zápis, as the side panel's button — a bare chevron
/// breathing on the panel buttons' beat ([KioskBreathingIcon]); floating
/// over the sheet it sits on a disc the size of the × ([_Disc]) so the
/// sheet's cells do not swallow it. Dim and still with nothing that way.
class _SideArrow extends StatelessWidget {
  const _SideArrow({
    required this.forward,
    required this.floating,
    required this.breathe,
    required this.onTap,
  });

  final bool forward;
  final bool floating;
  final bool breathe;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final icon = forward ? Icons.chevron_right : Icons.chevron_left;
    final label = forward ? 'Další zápas' : 'Předchozí zápas';
    if (floating) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: _Disc(
          tooltip: label,
          onTap: onTap,
          child: KioskBreathingIcon(
            icon,
            size: _Disc.iconSize,
            breathe: breathe,
            enabled: onTap != null,
            strong: true,
          ),
        ),
      );
    }
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: _KioskZapisState._sideRoom,
          height: 96,
          child: Center(
            child: KioskBreathingIcon(
              icon,
              breathe: breathe,
              enabled: onTap != null,
            ),
          ),
        ),
      ),
    );
  }
}

/// A round button over the sheet — the ×, and the arrows floating at full
/// screen — all one size.
class _Disc extends StatelessWidget {
  const _Disc({required this.tooltip, required this.onTap, required this.child});

  final String tooltip;
  final VoidCallback? onTap;
  final Widget child;

  static const size = 56.0;
  static const iconSize = 32.0;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Semantics(
      button: true,
      enabled: onTap != null,
      label: tooltip,
      child: Material(
        shape: const CircleBorder(),
        color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.85),
        elevation: 2,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox.square(dimension: size, child: Center(child: child)),
        ),
      ),
    ),
  );
}

/// The paging bar: the home team at the left and the away team at the
/// right — over their halves of the sheet below — and ‹ the day › in the
/// middle, the arrows beside the day they page from; the ▶ and the × at
/// the right end. The teams are buttons that list their matches.
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

  /// The day's box: as wide as the widest day can be — every weekday with
  /// a two-digit day and month, in the bar's style and text size — so the
  /// arrows beside it stay put whichever day it shows („středa 14. 10.“ is
  /// narrower than „čtvrtek 15. 10.“).
  static double _dayWidth(BuildContext context, TextStyle style) {
    final base = DefaultTextStyle.of(context).style.merge(style);
    var widest = 0.0;
    for (var i = 0; i < 7; i++) {
      final painter = TextPainter(
        text: TextSpan(text: dayFull(Day(2026, 12, 21).addDays(i)), style: base),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      widest = math.max(widest, painter.width);
      painter.dispose();
    }
    return widest.ceilToDouble() + 2;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Shown with the club's nickname (0080); the tap still names the team.
    final names = shownNamesNow(context);
    Widget team(String name, double maxWidth) => ConstrainedBox(
      constraints: BoxConstraints(maxWidth: math.max(0, maxWidth)),
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
                names.team(name),
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
      padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final dayStyle = TextStyle(color: scheme.onSurfaceVariant);
          final dayWidth = _dayWidth(context, dayStyle);
          // ‹ (48), the day with its padding, › (48).
          final middle = 48 + 16 + dayWidth + 48;
          // Each team gets its half of what the middle leaves; the away
          // team shares its half with the ▶ and the ×.
          final half = (constraints.maxWidth - middle) / 2 - 8;
          final end = (play == null ? 0.0 : 220.0) + 48 + 8;
          return Stack(
            alignment: Alignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    iconSize: 32,
                    tooltip: 'Předchozí zápas',
                    onPressed: previous == null
                        ? null
                        : () => onShow(previous),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: SizedBox(
                      width: dayWidth,
                      child: Text(
                        dayFull(slot.date),
                        maxLines: 1,
                        textAlign: TextAlign.center,
                        style: dayStyle,
                      ),
                    ),
                  ),
                  IconButton(
                    iconSize: 32,
                    tooltip: 'Další zápas',
                    onPressed: next == null ? null : () => onShow(next),
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: team(slot.homeTeam, half),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    team(slot.awayTeam, half - end),
                    const SizedBox(width: 8),
                    if (play != null) ...[
                      _PlayButton(play: play),
                      const SizedBox(width: 4),
                    ],
                    IconButton(
                      iconSize: 32,
                      tooltip: 'Zavřít',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
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
    final names = shownNamesNow(context);
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
                  names.team(home ? m.awayTeam : m.homeTeam),
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

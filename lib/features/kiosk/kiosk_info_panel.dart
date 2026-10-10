/// The kiosk's side drawer: the alley's active notices (they take turns when
/// there are several; a tap reads one in full), the matches of the last and
/// next weeks (a tap on a finished one opens its Zápis) — and, while a match
/// is being played, that match across the whole drawer in the Souboje view
/// (several live matches take turns too). Display only, like the board:
/// nothing here books or writes. Closed it is gone entirely, leaving only a
/// button floating at the screen's edge. The admin picks what it lists and
/// how it looks (Správa → Kiosk); the shell closes or reopens it to its
/// resting state after a minute without a touch.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../core/widgets/emoji_text.dart';
import '../../data/clock.dart';
import '../../data/providers.dart';
import '../../domain/duels.dart';
import '../../domain/kiosk_panel.dart';
import '../../domain/models.dart';
import '../../domain/palette.dart';
import '../../domain/results.dart';
import '../clubhouse/widgets/duel_card.dart';
import '../clubhouse/widgets/duels_compact.dart';
import '../clubhouse/widgets/match_scoreboard.dart';
import '../clubhouse/widgets/match_title.dart';
import '../clubhouse/widgets/team_totals_card.dart';
import '../schedule/widgets/calendar_board.dart' show calendarRulerWidth;

/// The drawer's width for a screen [screenWidth] wide: [columns] of the
/// board's [visibleDays] day columns (the board sizes them on the whole
/// screen), at least one and at most one fewer than all — so open or
/// closed, the board shows whole days only.
double kioskDrawerWidthFor(
  double screenWidth, {
  required int columns,
  required int visibleDays,
}) {
  final days = visibleDays < 2 ? 2 : visibleDays;
  final column = (screenWidth - calendarRulerWidth) / days;
  return columns.clamp(1, days - 1) * column;
}

const _resultRowHeight = 64.0;
const _moreRowHeight = 52.0;

/// Asks the server for a fresh score of the match [id] (refresh_match,
/// forced: the kiosk's own clock decides how often). Errors are swallowed —
/// a failed ask leaves the score as it was, and the age line says how old.
final kioskRefreshMatchProvider = Provider<Future<void> Function(String id)>(
  (ref) => (id) async {
    try {
      await Api.refreshMatch(id, force: true);
    } catch (e) {
      debugPrint('Kiosk: refresh of $id failed: $e');
    }
  },
);

/// The matches being played whose players the site has delivered — empty
/// with live mode off. A match marked as playing but without data is not
/// here ([kioskLiveMatches]).
final kioskLiveProvider = Provider<List<PrioritySlot>>((ref) {
  final settings = ref.watch(settingsProvider).value;
  if (!(settings?.kioskPanelEnabled ?? true) ||
      !(settings?.kioskLiveMode ?? true)) {
    return const [];
  }
  final slots = ref.watch(prioritySlotsProvider);
  final results = ref.watch(matchResultsProvider).value ?? const {};
  final withData = <String>{};
  for (final s in slots) {
    if (results[s.id]?.status != MatchStatus.inProgress) continue;
    if (ref.watch(matchPlayerResultsProvider(s.id)).value?.isNotEmpty ??
        false) {
      withData.add(s.id);
    }
  }
  return kioskLiveMatches(
    slots: slots,
    results: results,
    withData: withData,
    now: ref.watch(nowProvider).value ?? DateTime.now(),
  );
});

/// What the drawer would show now, from the providers and the admin's
/// settings — null when there is nothing (the shell then draws no drawer).
final kioskPanelContentProvider = Provider<KioskPanelContent?>((ref) {
  final settings = ref.watch(settingsProvider).value;
  if (!(settings?.kioskPanelEnabled ?? true)) return null;
  final now = ref.watch(nowProvider).value ?? DateTime.now();
  final live = ref.watch(kioskLiveProvider);
  final notices = (settings?.kioskShowNotices ?? true)
      ? kioskNotices(ref.watch(messagesProvider).value ?? const [], now)
      : const <Message>[];
  final hasMatches =
      (settings?.kioskShowMatches ?? true) &&
      kioskMatchWindow(
        slots: ref.watch(prioritySlotsProvider),
        today: Day.fromDateTime(now),
        weeksBack: settings?.kioskWeeksBack ?? 2,
        weeksAhead: settings?.kioskWeeksAhead ?? 1,
        showUpcoming: settings?.kioskShowUpcoming ?? true,
      ).matches.isNotEmpty;
  if (live.isEmpty && notices.isEmpty && !hasMatches) return null;
  return KioskPanelContent(
    notices: notices,
    hasMatches: hasMatches,
    live: live,
  );
});

class KioskPanelContent {
  const KioskPanelContent({
    required this.notices,
    required this.hasMatches,
    required this.live,
  });

  final List<Message> notices;
  final bool hasMatches;

  /// Matches being played, with data; non-empty = the drawer shows only them.
  final List<PrioritySlot> live;
}

class KioskDrawer extends ConsumerWidget {
  const KioskDrawer({
    super.key,
    required this.content,
    required this.open,
    required this.onOpenNotice,
    required this.onOpenMatch,
    this.resetToken = 0,
    this.boardDays,
    this.showLive = true,
    this.onShowLive,
  });

  /// False after a visitor switched from the match being played to the
  /// list of matches; the idle reset turns it back.
  final bool showLive;

  /// Between the live view and the list: true = the live match.
  final void Function(bool live)? onShowLive;

  /// Bumped by the shell on every idle reset.
  final int resetToken;

  /// The days a visitor scrolled the board to, when the list follows it.
  final ({Day first, Day last})? boardDays;

  final KioskPanelContent content;
  final bool open;
  final void Function(Message notice) onOpenNotice;
  final void Function(PrioritySlot match) onOpenMatch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final settings = ref.watch(settingsProvider).value;
    final width = kioskDrawerWidthFor(
      MediaQuery.sizeOf(context).width,
      columns: settings?.kioskDrawerColumns ?? 2,
      visibleDays: settings?.kioskVisibleDays ?? 7,
    );
    final noticeTurn = Duration(
      seconds: settings?.kioskNoticesRotationSeconds ?? 12,
    );
    final liveTurn = Duration(
      seconds: settings?.kioskLiveRotationSeconds ?? 12,
    );
    final share = settings?.kioskNoticesShare ?? 40;
    final notices = content.notices.isEmpty
        ? null
        : _NoticesCard(
            notices: content.notices,
            turn: noticeTurn,
            fill: content.hasMatches,
            onOpen: onOpenNotice,
          );
    final matches = content.hasMatches
        // A new key after every idle reset: the list starts over (its
        // weeks and its scroll) like the rest of the kiosk.
        ? _MatchesCard(
            key: ValueKey(resetToken),
            onOpen: onOpenMatch,
            boardDays: boardDays,
            // Back to the match being played, when one is.
            onShowLive: content.live.isEmpty || onShowLive == null
                ? null
                : () => onShowLive!(true),
          )
        : null;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      width: open ? width : 0,
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(color: scheme.surfaceContainer),
      // Laid out at its full width even while it grows or shrinks, so the
      // text does not reflow during the animation.
      child: OverflowBox(
        alignment: Alignment.centerLeft,
        minWidth: width,
        maxWidth: width,
        child: !open
            ? const SizedBox.shrink()
            : content.live.isNotEmpty && (showLive || matches == null)
            ? _LiveView(
                matches: content.live,
                turn: liveTurn,
                onOpenMatch: onOpenMatch,
                onShowList: matches == null || onShowLive == null
                    ? null
                    : () => onShowLive!(false),
              )
            : Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (notices != null && matches != null) ...[
                      Expanded(flex: share, child: notices),
                      const SizedBox(height: 12),
                      Expanded(flex: 100 - share, child: matches),
                    ] else if (matches != null)
                      Expanded(child: matches)
                    else if (notices != null)
                      Flexible(child: notices),
                  ],
                ),
              ),
      ),
    );
  }
}

/// The button that opens and closes the drawer: a bare double arrow, gray
/// and half see-through, floating over the board at the drawer's left edge
/// (or the screen's, while it is closed). Every few seconds it breathes once
/// — a soft glow and a little more opacity — so a tablet on the wall shows
/// that there is something to open, without ever moving.
class KioskDrawerButton extends StatefulWidget {
  const KioskDrawerButton({
    super.key,
    required this.open,
    required this.onTap,
    this.breathe = true,
  });

  final bool open;
  final VoidCallback onTap;

  /// Off = a still button (the admin's „Dýchající tlačítko panelu“, 0065):
  /// every breath repaints the screen, which a slow display feels.
  final bool breathe;

  static const size = 56.0;
  static const margin = 8.0;

  /// One breath, and the rest between two.
  static const pulse = Duration(milliseconds: 2400);
  static const pause = Duration(milliseconds: 1800);

  @override
  State<KioskDrawerButton> createState() => _KioskDrawerButtonState();
}

class _KioskDrawerButtonState extends State<KioskDrawerButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: KioskDrawerButton.pulse,
  );
  Timer? _rest;

  @override
  void initState() {
    super.initState();
    if (widget.breathe) _breathe();
  }

  @override
  void didUpdateWidget(KioskDrawerButton old) {
    super.didUpdateWidget(old);
    if (old.breathe == widget.breathe) return;
    if (widget.breathe) {
      _breathe();
    } else {
      // Mid-breath: stopped, and no rest timer follows a breath that never
      // finished (whenComplete waits for the finish).
      _rest?.cancel();
      _controller.stop();
      _controller.value = 0;
    }
  }

  /// One breath, then a rest on a timer (not a repeating animation, which
  /// would keep a test's pumpAndSettle from ever settling).
  void _breathe() {
    _controller.forward(from: 0).whenComplete(() {
      if (!mounted) return;
      _rest = Timer(KioskDrawerButton.pause, _breathe);
    });
  }

  @override
  void dispose() {
    _rest?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: widget.open ? 'Skrýt panel' : 'Zobrazit nástěnku a zápasy',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: SizedBox(
          width: KioskDrawerButton.size,
          height: KioskDrawerButton.size,
          child: Center(
            // Its own layer: a breath repaints the icon, not the board and
            // the drawer under it.
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, child) {
                  // 0 → 1 → 0 over one breath; 0 while the button is still.
                  final glow = math.sin(_controller.value * math.pi);
                  return Icon(
                    widget.open
                        ? Icons.keyboard_double_arrow_right
                        : Icons.keyboard_double_arrow_left,
                    size: 44,
                    color: scheme.onSurfaceVariant.withValues(
                      alpha: 0.4 + 0.35 * glow,
                    ),
                    shadows: [
                      Shadow(
                        color: scheme.primary.withValues(alpha: 0.75 * glow),
                        blurRadius: 4 + 16 * glow,
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A horizontal swipe over [child]: a fling to the left asks for the next
/// item ([onSwipe] 1), to the right for the previous one (-1). Vertical
/// scrolling inside [child] is untouched.
class _Swipe extends StatelessWidget {
  const _Swipe({required this.onSwipe, required this.child});

  final void Function(int direction) onSwipe;
  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onHorizontalDragEnd: (details) {
      final v = details.primaryVelocity ?? 0;
      if (v.abs() < 200) return;
      onSwipe(v < 0 ? 1 : -1);
    },
    child: child,
  );
}

/// A rounded card with a title; [fill] makes its body take all the height
/// the card is given (a slot of the drawer), otherwise it is as tall as its
/// content.
class _Card extends StatelessWidget {
  const _Card({
    required this.icon,
    required this.title,
    required this.child,
    this.fill = false,
    this.action,
  });

  final IconData icon;
  final String title;
  final Widget child;
  final bool fill;

  /// At the right of the title row.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                  color: scheme.primary,
                ),
              ),
              if (action != null) ...[const Spacer(), action!],
            ],
          ),
          const SizedBox(height: 10),
          fill ? Expanded(child: child) : Flexible(child: child),
        ],
      ),
    );
  }
}

const _noticeTitleStyle = TextStyle(fontSize: 20, fontWeight: FontWeight.w800);
const _noticeBodyStyle = TextStyle(fontSize: 16, height: 1.3);
const _noticeFooterHeight = 32.0;

/// The notices, one at a time. A single notice just stays; several take
/// turns every [turn], with dots to say how many there are. What does not
/// fit the card is cut, and only then „Více“ offers the full text.
class _NoticesCard extends StatefulWidget {
  const _NoticesCard({
    required this.notices,
    required this.turn,
    required this.fill,
    required this.onOpen,
  });

  final List<Message> notices;
  final Duration turn;
  final bool fill;
  final void Function(Message notice) onOpen;

  @override
  State<_NoticesCard> createState() => _NoticesCardState();
}

class _NoticesCardState extends State<_NoticesCard> {
  Timer? _timer;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(_NoticesCard old) {
    super.didUpdateWidget(old);
    if (old.turn != widget.turn) _start();
  }

  void _start() {
    _timer?.cancel();
    _timer = Timer.periodic(widget.turn, (_) => _step(1));
  }

  /// To the next ([direction] 1) or previous (-1) notice — on the timer or
  /// by a swipe; either way the next turn is a whole [turn] away.
  void _step(int direction) {
    if (!mounted || widget.notices.length < 2) return;
    final n = widget.notices.length;
    setState(() => _index = (_index + direction) % n);
    _start();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final notices = widget.notices;
    final scheme = Theme.of(context).colorScheme;
    final m = notices[_index.clamp(0, notices.length - 1)];
    return _Card(
      icon: Icons.campaign_outlined,
      title: 'NÁSTĚNKA',
      fill: widget.fill,
      child: _Swipe(
        onSwipe: _step,
        child: LayoutBuilder(
          builder: (context, box) {
            final fit = _fitNotice(context, m, box);
            // Only a cut notice has more to read; a whole one is not a link.
            return InkWell(
              onTap: fit.truncated ? () => widget.onOpen(m) : null,
              borderRadius: BorderRadius.circular(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: widget.fill ? MainAxisSize.max : MainAxisSize.min,
                children: [
                  SizedBox(
                    height: fit.height,
                    child: ClipRect(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        layoutBuilder: (current, previous) => Stack(
                          alignment: Alignment.topLeft,
                          children: [...previous, ?current],
                        ),
                        child: Column(
                          key: ValueKey(m.id),
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              m.title ?? '',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: _noticeTitleStyle,
                            ),
                            const SizedBox(height: 6),
                            Text(
                              m.body,
                              maxLines: fit.bodyLines,
                              // An ellipsis without a line limit makes Skia
                              // cut the text to its first line.
                              overflow: fit.bodyLines == null
                                  ? TextOverflow.clip
                                  : TextOverflow.ellipsis,
                              style: _noticeBodyStyle,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (widget.fill)
                    const Spacer()
                  else
                    const SizedBox(height: 8),
                  SizedBox(
                    height: _noticeFooterHeight - 8,
                    child: Row(
                      children: [
                        for (
                          var i = 0;
                          notices.length > 1 && i < notices.length;
                          i++
                        )
                          Container(
                            width: 8,
                            height: 8,
                            margin: const EdgeInsets.only(right: 6),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: i == _index
                                  ? scheme.primary
                                  : scheme.onSurfaceVariant.withValues(
                                      alpha: 0.35,
                                    ),
                            ),
                          ),
                        const Spacer(),
                        if (fit.truncated) ...[
                          Text(
                            'Více',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: scheme.primary,
                            ),
                          ),
                          Icon(
                            Icons.expand_more,
                            size: 20,
                            color: scheme.primary,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// How much of [m] fits [box] (the card's interior): the height of the
  /// text block, the body lines that fit, and whether anything is cut. An
  /// unbounded box (a lone notice card) shows everything.
  ({double height, int? bodyLines, bool truncated}) _fitNotice(
    BuildContext context,
    Message m,
    BoxConstraints box,
  ) {
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    // The same style the Text widgets resolve: theirs merged into the
    // ambient one, or the measure would differ from what is drawn.
    final base = DefaultTextStyle.of(context).style;
    TextPainter paint(String text, TextStyle style, int? maxLines) =>
        TextPainter(
          text: TextSpan(text: text, style: base.merge(style)),
          textDirection: direction,
          textScaler: scaler,
          maxLines: maxLines,
        )..layout(maxWidth: box.maxWidth);

    final title = paint(m.title ?? '', _noticeTitleStyle, 2);
    final body = paint(m.body, _noticeBodyStyle, null);
    final natural = title.height + 6 + body.height;
    final available = box.hasBoundedHeight
        ? box.maxHeight - _noticeFooterHeight
        : double.infinity;
    if (natural <= available) {
      return (height: natural, bodyLines: null, truncated: false);
    }
    final line = paint('A', _noticeBodyStyle, 1).height;
    final lines = math.max(1, ((available - title.height - 6) / line).floor());
    return (height: math.max(available, 0), bodyLines: lines, truncated: true);
  }
}

/// The finished and the coming matches of the weeks the admin chose,
/// chronological, opened on the first one not decided yet. „Zobrazit další“
/// at either end brings one more week of the season; a tap on a finished
/// match opens its Zápis.
class _MatchesCard extends ConsumerStatefulWidget {
  const _MatchesCard({
    super.key,
    required this.onOpen,
    this.boardDays,
    this.onShowLive,
  });

  final void Function(PrioritySlot match) onOpen;

  /// Back to the match being played; null when none is.
  final VoidCallback? onShowLive;

  /// The days the board shows after a visitor scrolled it; the list turns
  /// to the first match among them.
  final ({Day first, Day last})? boardDays;

  @override
  ConsumerState<_MatchesCard> createState() => _MatchesCardState();
}

class _MatchesCardState extends ConsumerState<_MatchesCard> {
  int _extraBack = 0;
  int _extraAhead = 0;

  /// The first match below the bottom edge when the list opened (see
  /// [kioskFirstUpcomingIndex]); null when none is coming. The list grows away from it in both
  /// directions, so what was on screen stays where it was when more weeks
  /// load (older matches grow upwards from here, not by shifting the rest).
  String? _anchorId;
  final _centerKey = GlobalKey();
  final _controller = ScrollController();
  bool _opened = false;

  /// One key per match row, to scroll a row into view.
  final _rowKeys = <String, GlobalKey>{};

  @override
  void didUpdateWidget(_MatchesCard old) {
    super.didUpdateWidget(old);
    final days = widget.boardDays;
    if (days != null && days != old.boardDays) _follow(days);
  }

  /// Turns the list to the first match the board now shows — widening the
  /// list by whole weeks when that match lies outside it.
  void _follow(({Day first, Day last}) days) {
    bool inDays(PrioritySlot s) =>
        !s.date.isBefore(days.first) && !s.date.isAfter(days.last);
    var back = _extraBack;
    var ahead = _extraAhead;
    PrioritySlot? target;
    for (var i = 0; i < 60; i++) {
      final w = _window(back, ahead, watch: false);
      target = w.matches.where(inDays).firstOrNull;
      if (target != null) break;
      final earlier =
          w.matches.isEmpty || days.first.isBefore(w.matches.first.date);
      if (earlier && w.moreBefore) {
        back++;
      } else if (!earlier && w.moreAfter) {
        ahead++;
      } else {
        break;
      }
    }
    final found = target;
    if (found == null) return;
    if (back != _extraBack || ahead != _extraAhead) {
      setState(() {
        _extraBack = back;
        _extraAhead = ahead;
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final row = _rowKeys[found.id]?.currentContext;
      if (row == null || !row.mounted) return;
      Scrollable.ensureVisible(
        row,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeInOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// The window for [extraBack]/[extraAhead] more weeks, from the current
  /// providers; [watch] subscribes the build, a tap only reads.
  KioskMatchWindow _window(
    int extraBack,
    int extraAhead, {
    required bool watch,
  }) {
    final settings =
        (watch ? ref.watch(settingsProvider) : ref.read(settingsProvider))
            .value;
    final now = (watch ? ref.watch(nowProvider) : ref.read(nowProvider)).value;
    return kioskMatchWindow(
      slots: watch
          ? ref.watch(prioritySlotsProvider)
          : ref.read(prioritySlotsProvider),
      today: Day.fromDateTime(now ?? DateTime.now()),
      weeksBack: settings?.kioskWeeksBack ?? 2,
      weeksAhead: settings?.kioskWeeksAhead ?? 1,
      showUpcoming: settings?.kioskShowUpcoming ?? true,
      extraBack: extraBack,
      extraAhead: extraAhead,
    );
  }

  /// „Zobrazit předchozí/další“: widens the window by whole weeks until a
  /// match shows up — a week with none (a holiday, a free round) would
  /// otherwise answer a tap with nothing — or the season has no more.
  void _more({required bool older}) {
    final shown = _window(_extraBack, _extraAhead, watch: false).matches.length;
    var back = _extraBack;
    var ahead = _extraAhead;
    while (true) {
      if (older) {
        back++;
      } else {
        ahead++;
      }
      final w = _window(back, ahead, watch: false);
      if (w.matches.length > shown || !(older ? w.moreBefore : w.moreAfter)) {
        break;
      }
    }
    setState(() {
      _extraBack = back;
      _extraAhead = ahead;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final now = ref.watch(nowProvider).value ?? DateTime.now();
    final today = Day.fromDateTime(now);
    final results =
        ref.watch(matchResultsProvider).value ?? const <String, MatchResult>{};
    final window = _window(_extraBack, _extraAhead, watch: true);
    final matches = window.matches;

    // Like Výsledky: opens with the first coming match at the bottom edge
    // and as many played (and playing) ones as fit above it. Afterwards the
    // same match stays the anchor (found by id, as more weeks are added).
    if (!_opened && matches.isNotEmpty) {
      final first = kioskFirstUpcomingIndex(matches, results, today);
      _anchorId = first < matches.length ? matches[first].id : null;
    }
    final anchor = _anchorId == null
        ? -1
        : matches.indexWhere((m) => m.id == _anchorId);
    // The centre sliver starts with the first coming match; offset 0 puts
    // it at the top edge, so the opening jump goes up one viewport and
    // leaves it just below the bottom one.
    final split = anchor < 0 ? matches.length : anchor;
    if (!_opened && matches.isNotEmpty) {
      _opened = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_controller.hasClients) return;
        final p = _controller.position;
        _controller.jumpTo(math.max(-p.viewportDimension, p.minScrollExtent));
      });
    }
    // Index 0 of the part before the centre is the last match above it.
    final older = matches.sublist(0, split).reversed.toList();
    final newer = matches.sublist(split);

    Widget row(PrioritySlot s) => SizedBox(
      key: _rowKeys.putIfAbsent(s.id, GlobalKey.new),
      height: _resultRowHeight,
      child: _MatchRow(slot: s, result: results[s.id], onOpen: widget.onOpen),
    );
    Widget more(String label, VoidCallback onTap) => SizedBox(
      height: _moreRowHeight,
      child: Center(
        child: TextButton(onPressed: onTap, child: Text(label)),
      ),
    );

    final showLive = widget.onShowLive;
    return _Card(
      icon: Icons.emoji_events_outlined,
      title: 'ZÁPASY',
      // A match is being played: back to it.
      action: showLive == null
          ? null
          : ActionChip(
              avatar: Icon(Icons.circle, size: 10, color: scheme.error),
              label: const Text('Právě se hraje'),
              visualDensity: VisualDensity.compact,
              onPressed: showLive,
            ),
      fill: true,
      child: matches.isEmpty
          ? Text(
              'V tomhle období není žádný zápas.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            )
          : CustomScrollView(
              controller: _controller,
              center: _centerKey,
              // Every row built, so following the board can scroll to any.
              // (Deprecated on newer stable Flutter for scrollCacheExtent,
              // which the SDK this repo builds with locally lacks — CI runs
              // the newer one.)
              // ignore: deprecated_member_use
              cacheExtent: 100000,
              slivers: [
                SliverList.builder(
                  itemCount: older.length + (window.moreBefore ? 1 : 0),
                  itemBuilder: (context, i) => i < older.length
                      ? row(older[i])
                      : more('Zobrazit předchozí', () => _more(older: true)),
                ),
                SliverList.list(
                  key: _centerKey,
                  children: [
                    for (final s in newer) row(s),
                    if (window.moreAfter)
                      more('Zobrazit další', () => _more(older: false)),
                  ],
                ),
              ],
            ),
    );
  }
}

class _MatchRow extends StatelessWidget {
  const _MatchRow({required this.slot, required this.onOpen, this.result});

  final PrioritySlot slot;
  final MatchResult? result;
  final void Function(PrioritySlot match) onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasScore = hasScoreData(result);
    final score = hasScore
        ? pointsLabel(result!.homePoints, result!.awayPoints)
        : null;
    final when =
        '${dayLabel(slot.date)}'
        '${slot.timeKnown ? ' ${slot.startsAt.display()}' : ''}';
    final row = Row(
      children: [
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MatchTitle(
                slot: slot,
                winner: displayWinner(result),
                style: const TextStyle(fontSize: 15),
              ),
              EmojiText(
                '${slot.isAway ? '' : '🏠 '}$when',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        if (score != null) ...[
          const SizedBox(width: 10),
          Text(
            score,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: scheme.primary,
            ),
          ),
        ],
      ],
    );
    // Only a match with a score has a Zápis to open.
    if (!hasScore) return row;
    return InkWell(
      onTap: () => onOpen(slot),
      borderRadius: BorderRadius.circular(8),
      child: row,
    );
  }
}

/// The match being played across the whole drawer, the Souboje view of the
/// match detail: the scoreboard, one card per duel, the team totals. Several
/// live matches take turns every [turn].
class _LiveView extends ConsumerStatefulWidget {
  const _LiveView({
    required this.matches,
    required this.turn,
    required this.onOpenMatch,
    this.onShowList,
  });

  /// To the list of matches; null when there is none to show.
  final VoidCallback? onShowList;

  /// A tap on the score: the match's Zápis.
  final void Function(PrioritySlot match) onOpenMatch;

  final List<PrioritySlot> matches;
  final Duration turn;

  @override
  ConsumerState<_LiveView> createState() => _LiveViewState();
}

class _LiveViewState extends ConsumerState<_LiveView> {
  Timer? _timer;
  int _index = 0;

  /// The way the last change went: 1 to the next match, -1 back — the
  /// cards slide in from that side.
  int _direction = 1;

  /// The match a visitor pinned (a tap on the dots): no turns until it ends
  /// — it then drops out of the live matches, and the lock with it.
  String? _lockedId;

  /// Asks the server for fresh scores of the matches being played, every
  /// [_refreshEvery] (the admin's choice).
  Timer? _refresh;
  Duration? _refreshEvery;

  void _armRefresh(Duration every) {
    if (_refreshEvery == every) return;
    _refreshEvery = every;
    _refresh?.cancel();
    void ask() {
      final ask = ref.read(kioskRefreshMatchProvider);
      for (final m in widget.matches) {
        unawaited(ask(m.id));
      }
    }

    _refresh = Timer.periodic(every, (_) => ask());
    // And once now: the score on screen is as old as it is.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ask();
    });
  }

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(_LiveView old) {
    super.didUpdateWidget(old);
    if (old.turn != widget.turn) _start();
  }

  /// (Re)starts the wait for the next turn — also on every touch or scroll
  /// in the view: whoever is reading a match keeps it on screen.
  void _start() {
    _timer?.cancel();
    _timer = Timer.periodic(widget.turn, (_) => _step(1));
  }

  /// To the next ([direction] 1) or previous (-1) live match — on the timer
  /// or by a swipe; either way the next turn is a whole turn away.
  void _step(int direction, {bool byHand = false}) {
    if (!mounted || widget.matches.length < 2) return;
    if (_locked && !byHand) return;
    setState(() {
      // A swipe moves on, and takes the lock off.
      _lockedId = null;
      _direction = direction;
      _index = (_index + direction) % widget.matches.length;
    });
    _start();
  }

  bool get _locked =>
      _lockedId != null && widget.matches.any((m) => m.id == _lockedId);

  void _toggleLock(String id) {
    setState(() => _lockedId = _lockedId == id ? null : id);
    _start();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _refresh?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final matches = widget.matches;
    final refreshEvery = Duration(
      seconds: ref.watch(settingsProvider).value?.kioskLiveRefreshSeconds ?? 60,
    );
    _armRefresh(refreshEvery);
    // A locked match stays on screen wherever the list puts it.
    final lockedAt = _locked
        ? matches.indexWhere((m) => m.id == _lockedId)
        : -1;
    if (lockedAt >= 0) _index = lockedAt;
    final slot = matches[_index.clamp(0, matches.length - 1)];
    final current = ValueKey(slot.id);
    final locked = lockedAt >= 0;
    return Listener(
      onPointerDown: (_) => _start(),
      behavior: HitTestBehavior.translucent,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n is UserScrollNotification) _start();
          return false;
        },
        child: _Swipe(
          onSwipe: (d) => _step(d, byHand: true),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Back to all matches on the left, the dots (how many take
                // turns; the lock) in the middle, how old the score is on
                // the right. (The scoreboard's own chip says it is live.)
                Row(
                  children: [
                    if (widget.onShowList != null)
                      IconButton(
                        tooltip: 'Všechny zápasy',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.arrow_back),
                        onPressed: widget.onShowList,
                      ),
                    const Spacer(),
                    // The dots say how many matches take turns; a tap
                    // pins the one on screen until it ends (or another
                    // tap, or a swipe).
                    if (matches.length > 1)
                      Semantics(
                        button: true,
                        label: locked
                            ? 'Odemknout zápas'
                            : 'Zamknout tento zápas',
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => _toggleLock(slot.id),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 200),
                                  child: Icon(
                                    locked ? Icons.lock : Icons.lock_open,
                                    key: ValueKey(locked),
                                    size: 16,
                                    color: locked
                                        ? scheme.primary
                                        : scheme.onSurfaceVariant.withValues(
                                            alpha: 0.5,
                                          ),
                                  ),
                                ),
                                for (var i = 0; i < matches.length; i++)
                                  AnimatedContainer(
                                    duration: const Duration(milliseconds: 300),
                                    width: i == _index ? 18 : 8,
                                    height: 8,
                                    margin: const EdgeInsets.only(left: 6),
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(4),
                                      color: i == _index
                                          ? scheme.primary
                                          : scheme.onSurfaceVariant.withValues(
                                              alpha: 0.35,
                                            ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    const Spacer(),
                    _LiveAge(slot: slot),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ClipRect(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 380),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      layoutBuilder: (current, previous) => Stack(
                        fit: StackFit.expand,
                        children: [...previous, ?current],
                      ),
                      // The new match slides in from the side it comes from,
                      // the old one out the other way, both fading.
                      transitionBuilder: (child, animation) {
                        final incoming = child.key == current;
                        final from = incoming ? _direction : -_direction;
                        return SlideTransition(
                          position: Tween(
                            begin: Offset(0.35 * from, 0),
                            end: Offset.zero,
                          ).animate(animation),
                          child: FadeTransition(
                            opacity: animation,
                            child: child,
                          ),
                        );
                      },
                      child: _LiveMatch(
                        key: current,
                        slot: slot,
                        onOpenMatch: widget.onOpenMatch,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// How old the score on screen is: „⟳ před 3 min“.
class _LiveAge extends ConsumerWidget {
  const _LiveAge({required this.slot});

  final PrioritySlot slot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final now = ref.watch(nowProvider).value ?? DateTime.now();
    final fetched = ref.watch(
      matchResultsProvider.select((r) => r.value?[slot.id]?.fetchedAt),
    );
    if (fetched == null) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.refresh, size: 14, color: scheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(
          freshnessLabel(fetched, now),
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// One live match: its scoreboard stays on top, the duels and the team
/// totals scroll under it — opened on the last duel played or being
/// played, the earlier ones above it.
class _LiveMatch extends ConsumerStatefulWidget {
  const _LiveMatch({super.key, required this.slot, required this.onOpenMatch});

  final void Function(PrioritySlot match) onOpenMatch;

  final PrioritySlot slot;

  @override
  ConsumerState<_LiveMatch> createState() => _LiveMatchState();
}

class _LiveMatchState extends ConsumerState<_LiveMatch> {
  final _expanded = <int>{};
  final _duelKeys = <int, GlobalKey>{};
  bool _scrolled = false;

  @override
  Widget build(BuildContext context) {
    final slot = widget.slot;
    final now = ref.watch(nowProvider).value ?? DateTime.now();
    final result = ref.watch(
      matchResultsProvider.select((r) => r.value?[slot.id]),
    );
    final players =
        ref.watch(matchPlayerResultsProvider(slot.id)).value ?? const [];
    final duels = duelsOf(players);
    final scale = diffScale(duels);

    // Duels are played in groups, two on a four-lane alley, three on a
    // six-lane one: open on the group the play has reached, its first card
    // whole at the top (a card cut at the bottom is the lesser evil).
    final target = kioskLiveScrollTarget(
      duels,
      laneCount: ref.watch(settingsProvider).value?.laneCount ?? 4,
    );
    if (!_scrolled && target != null) {
      _scrolled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final card = _duelKeys[target]?.currentContext;
        if (card == null || !card.mounted) return;
        Scrollable.ensureVisible(card);
      });
    }

    // The score opens the Zápis — when there are players to put in it.
    final zapis = players.isEmpty ? null : () => widget.onOpenMatch(slot);
    final layout =
        ref.watch(settingsProvider).value?.kioskLiveLayout ?? MatchLayout.full;
    if (layout != MatchLayout.full) {
      // The score pinned on top (a tap opens the Zápis), the duels fitted
      // under it. Zápis is not a kiosk layout (0064's check); drawn as the
      // table should a row ever carry it.
      final score = GestureDetector(
        onTap: zapis,
        child: MatchScoreLine(slot: slot, result: result, duels: duels),
      );
      return layout == MatchLayout.compact
          ? DuelsCompact(duels: duels, result: result, header: score)
          : DuelsTable(duels: duels, result: result, header: score);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          onTap: zapis,
          child: MatchScoreboard(
            slot: slot,
            result: result,
            players: players,
            now: now,
            homeColor: homeSideColor,
            awayColor: awaySideColor,
            // The row above says how old the score is.
            showFreshness: false,
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final duel in duels)
                  Padding(
                    key: _duelKeys.putIfAbsent(duel.position, GlobalKey.new),
                    padding: const EdgeInsets.only(top: 8),
                    child: DuelCard(
                      duel: duel,
                      scale: scale,
                      expanded: _expanded.contains(duel.position),
                      onTap: duel.state == DuelState.waiting
                          ? () {}
                          : () => setState(() {
                              if (!_expanded.remove(duel.position)) {
                                _expanded.add(duel.position);
                              }
                            }),
                      homeColor: homeSideColor,
                      awayColor: awaySideColor,
                      showSetPoints: setPointsMatter(result?.discipline),
                    ),
                  ),
                if (result != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: TeamTotalsCard(
                      result: result,
                      homeColor: homeSideColor,
                      awayColor: awaySideColor,
                      showSetPoints: setPointsMatter(result.discipline),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

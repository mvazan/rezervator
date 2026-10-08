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
import '../../data/clock.dart';
import '../../data/providers.dart';
import '../../domain/duels.dart';
import '../../domain/kiosk_panel.dart';
import '../../domain/models.dart';
import '../../domain/palette.dart';
import '../../domain/results.dart';
import '../clubhouse/widgets/duel_card.dart';
import '../clubhouse/widgets/match_scoreboard.dart';
import '../clubhouse/widgets/match_title.dart';
import '../clubhouse/widgets/team_totals_card.dart';

/// The drawer's width for a screen [screenWidth] wide: what the admin chose,
/// at most 60 % of the screen.
double kioskDrawerWidthFor(double screenWidth, int chosen) =>
    math.min(chosen.toDouble(), screenWidth * 0.6);

const _resultRowHeight = 64.0;
const _moreRowHeight = 52.0;

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
  return kioskLiveMatches(slots: slots, results: results, withData: withData);
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
  });

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
      settings?.kioskDrawerWidth ?? 440,
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
        ? _MatchesCard(onOpen: onOpenMatch)
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
            : content.live.isNotEmpty
            ? _LiveView(matches: content.live, turn: liveTurn)
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
  const KioskDrawerButton({super.key, required this.open, required this.onTap});

  final bool open;
  final VoidCallback onTap;

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
    _breathe();
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
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                // 0 → 1 → 0 over one breath.
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
  });

  final IconData icon;
  final String title;
  final Widget child;
  final bool fill;

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
  const _MatchesCard({required this.onOpen});

  final void Function(PrioritySlot match) onOpen;

  @override
  ConsumerState<_MatchesCard> createState() => _MatchesCardState();
}

class _MatchesCardState extends ConsumerState<_MatchesCard> {
  final _controller = ScrollController();
  int _extraBack = 0;
  int _extraAhead = 0;
  bool _opened = false;

  /// Set when older matches were just added: the list length before, so the
  /// view can stay on what it showed.
  int? _lengthBeforeOlder;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final settings = ref.watch(settingsProvider).value;
    final now = ref.watch(nowProvider).value ?? DateTime.now();
    final today = Day.fromDateTime(now);
    final results =
        ref.watch(matchResultsProvider).value ?? const <String, MatchResult>{};
    final window = kioskMatchWindow(
      slots: ref.watch(prioritySlotsProvider),
      today: today,
      weeksBack: settings?.kioskWeeksBack ?? 2,
      weeksAhead: settings?.kioskWeeksAhead ?? 1,
      showUpcoming: settings?.kioskShowUpcoming ?? true,
      extraBack: _extraBack,
      extraAhead: _extraAhead,
    );
    final matches = window.matches;
    final nowIndex = kioskNowIndex(matches, results, today);

    if (!_opened) {
      _opened = true;
      // On the first match not decided yet, with the one before it in view.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_controller.hasClients) return;
        final top =
            (window.moreBefore ? _moreRowHeight : 0) +
            math.max(0, nowIndex - 1) * _resultRowHeight;
        _controller.jumpTo(top.clamp(0, _controller.position.maxScrollExtent));
      });
    }
    final before = _lengthBeforeOlder;
    if (before != null) {
      _lengthBeforeOlder = null;
      final added = matches.length - before;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_controller.hasClients) {
          _controller.jumpTo(_controller.offset + added * _resultRowHeight);
        }
      });
    }

    Widget more(String label, VoidCallback onTap) => SizedBox(
      height: _moreRowHeight,
      child: Center(
        child: TextButton(onPressed: onTap, child: Text(label)),
      ),
    );

    final items = <Widget>[
      if (window.moreBefore)
        more('Zobrazit další', () {
          _lengthBeforeOlder = matches.length;
          setState(() => _extraBack++);
        }),
      for (final s in matches)
        SizedBox(
          height: _resultRowHeight,
          child: _MatchRow(
            slot: s,
            result: results[s.id],
            onOpen: widget.onOpen,
          ),
        ),
      if (window.moreAfter)
        more('Zobrazit další', () => setState(() => _extraAhead++)),
    ];
    return _Card(
      icon: Icons.emoji_events_outlined,
      title: 'ZÁPASY',
      fill: true,
      child: matches.isEmpty
          ? Text(
              'V tomhle období není žádný zápas.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            )
          : ListView(controller: _controller, children: items),
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
              Text(
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
  const _LiveView({required this.matches, required this.turn});

  final List<PrioritySlot> matches;
  final Duration turn;

  @override
  ConsumerState<_LiveView> createState() => _LiveViewState();
}

class _LiveViewState extends ConsumerState<_LiveView> {
  Timer? _timer;
  int _index = 0;

  /// Duels opened to their lane tables, by position.
  final _expanded = <int>{};

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

  void _start() {
    _timer?.cancel();
    _timer = Timer.periodic(widget.turn, (_) => _step(1));
  }

  /// To the next ([direction] 1) or previous (-1) live match — on the timer
  /// or by a swipe; either way the next turn is a whole turn away.
  void _step(int direction) {
    if (!mounted || widget.matches.length < 2) return;
    setState(() {
      _index = (_index + direction) % widget.matches.length;
      _expanded.clear();
    });
    _start();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final matches = widget.matches;
    final slot = matches[_index.clamp(0, matches.length - 1)];
    final now = ref.watch(nowProvider).value ?? DateTime.now();
    final result = ref.watch(
      matchResultsProvider.select((r) => r.value?[slot.id]),
    );
    final players =
        ref.watch(matchPlayerResultsProvider(slot.id)).value ?? const [];
    final duels = duelsOf(players);
    final scale = diffScale(duels);
    return _Swipe(
      onSwipe: _step,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Row(
            children: [
              Icon(Icons.circle, size: 12, color: scheme.error),
              const SizedBox(width: 8),
              Text(
                'PRÁVĚ SE HRAJE',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                  color: scheme.primary,
                ),
              ),
              const Spacer(),
              for (var i = 0; matches.length > 1 && i < matches.length; i++)
                Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.only(left: 6),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i == _index
                        ? scheme.primary
                        : scheme.onSurfaceVariant.withValues(alpha: 0.35),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          MatchScoreboard(
            slot: slot,
            result: result,
            players: players,
            now: now,
            homeColor: homeSideColor,
            awayColor: awaySideColor,
          ),
          for (final duel in duels)
            Padding(
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
    );
  }
}

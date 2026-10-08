/// The kiosk's side drawer: the alley's active notices (they take turns when
/// there are several; a tap reads one in full) and the matches — the next
/// one, and the finished ones of the last few days; a tap on a finished one
/// opens its Zápis. Display only, like the board: nothing here books or
/// writes. Closed it is gone entirely, leaving only a round button floating
/// at the screen's edge; the admin picks the resting state and what it lists
/// (Správa → Kiosk), and the shell closes or reopens it to that state after
/// a minute without a touch.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/clock.dart';
import '../../data/providers.dart';
import '../../domain/kiosk_panel.dart';
import '../../domain/models.dart';
import '../../domain/results.dart';
import '../clubhouse/widgets/match_title.dart';

/// How long one notice stays up before the next takes its place.
const kioskNoticeTurn = Duration(seconds: 12);

/// Open drawer width on a full-HD screen (narrower screens get 40 %).
const kioskDrawerWidth = 440.0;

/// The drawer's width for a screen [screenWidth] wide.
double kioskDrawerWidthFor(double screenWidth) =>
    (screenWidth * 0.4).clamp(300.0, kioskDrawerWidth);

const _resultRowHeight = 64.0;

/// What the drawer would show now, from the providers and the admin's
/// settings — null when there is nothing (the shell then draws no drawer).
final kioskPanelContentProvider = Provider<KioskPanelContent?>((ref) {
  final settings = ref.watch(settingsProvider).value;
  final now = ref.watch(nowProvider).value ?? DateTime.now();
  final notices = (settings?.kioskShowNotices ?? true)
      ? kioskNotices(ref.watch(messagesProvider).value ?? const [], now)
      : const <Message>[];
  final matches = (settings?.kioskShowMatches ?? true)
      ? kioskMatches(
          slots: ref.watch(prioritySlotsProvider),
          results: ref.watch(matchResultsProvider).value ?? const {},
          today: Day.fromDateTime(now),
          historyDays: settings?.kioskMatchesHistoryDays ?? 21,
        )
      : (next: null, recent: const <PrioritySlot>[]);
  if (notices.isEmpty && matches.next == null && matches.recent.isEmpty) {
    return null;
  }
  return KioskPanelContent(
    notices: notices,
    next: matches.next,
    recent: matches.recent,
  );
});

class KioskPanelContent {
  const KioskPanelContent({
    required this.notices,
    required this.next,
    required this.recent,
  });

  final List<Message> notices;
  final PrioritySlot? next;
  final List<PrioritySlot> recent;

  bool get hasMatches => next != null || recent.isNotEmpty;
}

/// The drawer itself: [open] it is [kioskDrawerWidthFor] wide, closed it
/// has no width at all. The button that opens and closes it is
/// [KioskDrawerButton], floating outside of it.
class KioskDrawer extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final width = kioskDrawerWidthFor(MediaQuery.sizeOf(context).width);
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
        child: open
            ? Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (content.notices.isNotEmpty)
                      _NoticesCard(
                        notices: content.notices,
                        onOpen: onOpenNotice,
                      ),
                    if (content.notices.isNotEmpty && content.hasMatches)
                      const SizedBox(height: 12),
                    // The matches take what the notices leave and scroll.
                    if (content.hasMatches)
                      Flexible(
                        child: _MatchesCard(
                          next: content.next,
                          recent: content.recent,
                          onOpen: onOpenMatch,
                        ),
                      ),
                  ],
                ),
              )
            : const SizedBox.shrink(),
      ),
    );
  }
}

/// The button that opens and closes the drawer: a bare double arrow, gray
/// and half see-through, floating over the board at the drawer's left edge
/// (or the screen's, while it is closed). Place it in a [Stack] with
/// [KioskDrawerButton.positioned]; the arrow turns over as the drawer moves.
class KioskDrawerButton extends StatelessWidget {
  const KioskDrawerButton({
    super.key,
    required this.open,
    required this.onTap,
  });

  final bool open;
  final VoidCallback onTap;

  static const size = 56.0;
  static const margin = 8.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: open ? 'Skrýt panel' : 'Zobrazit nástěnku a zápasy',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(
                  scale: Tween(begin: 0.7, end: 1.0).animate(animation),
                  child: child,
                ),
              ),
              child: Icon(
                open
                    ? Icons.keyboard_double_arrow_right
                    : Icons.keyboard_double_arrow_left,
                key: ValueKey(open),
                size: 44,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.icon, required this.title, required this.child});

  final IconData icon;
  final String title;
  final Widget child;

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
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
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
          Flexible(child: child),
        ],
      ),
    );
  }
}

/// The notices, one at a time. A single notice just stays; several take
/// turns every [kioskNoticeTurn], with dots to say how many there are.
class _NoticesCard extends StatefulWidget {
  const _NoticesCard({required this.notices, required this.onOpen});

  final List<Message> notices;
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
    _timer = Timer.periodic(kioskNoticeTurn, (_) {
      if (!mounted || widget.notices.length < 2) return;
      setState(() => _index = (_index + 1) % widget.notices.length);
    });
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
    final until = m.expiresAt?.toLocal();
    return _Card(
      icon: Icons.campaign_outlined,
      title: 'NÁSTĚNKA',
      child: InkWell(
        onTap: () => widget.onOpen(m),
        borderRadius: BorderRadius.circular(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: KeyedSubtree(
                key: ValueKey(m.id),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      m.title ?? '',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      m.body,
                      maxLines: 8,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16, height: 1.3),
                    ),
                    if (until != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Platí do ${until.day}. ${until.month}.',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (notices.length > 1) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  for (var i = 0; i < notices.length; i++)
                    Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.only(right: 6),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i == _index
                            ? scheme.primary
                            : scheme.onSurfaceVariant.withValues(alpha: 0.35),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MatchesCard extends ConsumerWidget {
  const _MatchesCard({
    required this.next,
    required this.recent,
    required this.onOpen,
  });

  final PrioritySlot? next;
  final List<PrioritySlot> recent;
  final void Function(PrioritySlot match) onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final results =
        ref.watch(matchResultsProvider).value ?? const <String, MatchResult>{};
    final label = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w700,
      color: scheme.onSurfaceVariant,
    );
    final n = next;
    return _Card(
      icon: Icons.emoji_events_outlined,
      title: 'ZÁPASY',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (n != null) ...[
            Text(
              results[n.id]?.status == MatchStatus.inProgress
                  ? 'PRÁVĚ SE HRAJE'
                  : 'PŘÍŠTÍ ZÁPAS',
              style: label,
            ),
            const SizedBox(height: 2),
            _MatchRow(
              slot: n,
              result: results[n.id],
              upcoming: true,
              onOpen: onOpen,
            ),
          ],
          if (n != null && recent.isNotEmpty) const SizedBox(height: 12),
          if (recent.isNotEmpty) ...[
            Text('POSLEDNÍ VÝSLEDKY', style: label),
            const SizedBox(height: 4),
            Flexible(
              child: _RecentList(
                recent: recent,
                results: results,
                onOpen: onOpen,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The finished matches, chronological, opened on the newest: a long
/// history scrolls inside its own box rather than pushing the notices away.
class _RecentList extends StatefulWidget {
  const _RecentList({
    required this.recent,
    required this.results,
    required this.onOpen,
  });

  final List<PrioritySlot> recent;
  final Map<String, MatchResult> results;
  final void Function(PrioritySlot match) onOpen;

  @override
  State<_RecentList> createState() => _RecentListState();
}

class _RecentListState extends State<_RecentList> {
  final _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _toNewest();
  }

  @override
  void didUpdateWidget(_RecentList old) {
    super.didUpdateWidget(old);
    if (old.recent.length != widget.recent.length) _toNewest();
  }

  void _toNewest() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_controller.hasClients) {
      _controller.jumpTo(_controller.position.maxScrollExtent);
    }
  });

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rows = widget.recent.length;
    return ListView.builder(
      controller: _controller,
      shrinkWrap: true,
      itemCount: rows,
      itemBuilder: (context, i) {
        final s = widget.recent[i];
        return SizedBox(
          height: _resultRowHeight,
          child: _MatchRow(
            slot: s,
            result: widget.results[s.id],
            onOpen: widget.onOpen,
          ),
        );
      },
    );
  }
}

class _MatchRow extends StatelessWidget {
  const _MatchRow({
    required this.slot,
    required this.onOpen,
    this.result,
    this.upcoming = false,
  });

  final PrioritySlot slot;
  final MatchResult? result;
  final bool upcoming;
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
              fontSize: upcoming ? 18 : 20,
              fontWeight: FontWeight.w800,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 4),
          Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
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

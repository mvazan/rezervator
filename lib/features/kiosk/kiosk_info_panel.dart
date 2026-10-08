/// The kiosk's side drawer: the alley's active notices (they take turns when
/// there are several; a tap reads one in full) and the matches — the next
/// one, and the finished ones of the last few days; a tap on a finished one
/// opens its Zápis. Display only, like the board: nothing here books or
/// writes. Closed it is a thin strip with what it holds; the admin picks the
/// resting state and what it lists (Správa → Kiosk), and the shell closes
/// or reopens it to that state after a minute without a touch.
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

/// Open drawer width on a full-HD screen (narrower screens get 40 %), and
/// the strip left when it is closed.
const kioskDrawerWidth = 440.0;
const kioskHandleWidth = 64.0;

/// How many finished-match rows show before the list scrolls.
const _visibleResultRows = 5;
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

class KioskDrawer extends ConsumerWidget {
  const KioskDrawer({
    super.key,
    required this.content,
    required this.open,
    required this.onToggle,
    required this.onOpenNotice,
    required this.onOpenMatch,
  });

  final KioskPanelContent content;
  final bool open;
  final VoidCallback onToggle;
  final void Function(Message notice) onOpenNotice;
  final void Function(PrioritySlot match) onOpenMatch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final screen = MediaQuery.sizeOf(context).width;
    final openWidth = (screen * 0.4).clamp(300.0, kioskDrawerWidth);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      width: open ? openWidth : kioskHandleWidth,
      color: scheme.surfaceContainer,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Handle(content: content, open: open, onTap: onToggle),
          if (open)
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(0, 12, 12, 12),
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
                    if (content.hasMatches)
                      _MatchesCard(
                        next: content.next,
                        recent: content.recent,
                        onOpen: onOpenMatch,
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The strip on the drawer's left edge: the whole of it is the toggle, big
/// enough for a finger, with a chevron and — when closed — one icon per
/// thing inside, the notice count on its icon.
class _Handle extends StatelessWidget {
  const _Handle({
    required this.content,
    required this.open,
    required this.onTap,
  });

  final KioskPanelContent content;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: open ? 'Skrýt panel' : 'Zobrazit nástěnku a zápasy',
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: kioskHandleWidth,
          child: Column(
            children: [
              const SizedBox(height: 16),
              Icon(
                open ? Icons.chevron_right : Icons.chevron_left,
                size: 36,
                color: scheme.primary,
              ),
              if (!open) ...[
                const SizedBox(height: 24),
                if (content.notices.isNotEmpty)
                  Badge(
                    label: Text('${content.notices.length}'),
                    child: Icon(
                      Icons.campaign_outlined,
                      size: 32,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                if (content.notices.isNotEmpty && content.hasMatches)
                  const SizedBox(height: 28),
                if (content.hasMatches)
                  Icon(
                    Icons.emoji_events_outlined,
                    size: 32,
                    color: scheme.onSurfaceVariant,
                  ),
              ],
            ],
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
          child,
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
            _RecentList(recent: recent, results: results, onOpen: onOpen),
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
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: _visibleResultRows * _resultRowHeight,
      ),
      child: ListView.builder(
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
      ),
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

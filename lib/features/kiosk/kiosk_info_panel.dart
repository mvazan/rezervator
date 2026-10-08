/// The kiosk's side panel: the alley's active notices (they take turns when
/// there are several; a tap reads one in full) and the matches — the next
/// one, and the last finished ones with their score. Display only, like the
/// board: nothing here books, writes or leaves the kiosk. Wide screens get
/// it as a rail beside the board, narrow ones as a strip under it.
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

/// Width of the rail, and height of the strip, beside/under the board.
const kioskRailWidth = 320.0;
const kioskStripHeight = 232.0;

/// Whether the panel has anything to show; the shell hides it otherwise,
/// so an alley with no notices and no federation matches loses no room.
final kioskPanelHasContentProvider = Provider<bool>((ref) {
  final now = ref.watch(nowProvider).value ?? DateTime.now();
  final notices = kioskNotices(
    ref.watch(messagesProvider).value ?? const [],
    now,
  );
  final m = kioskMatches(
    slots: ref.watch(prioritySlotsProvider),
    results: ref.watch(matchResultsProvider).value ?? const {},
    today: Day.fromDateTime(now),
  );
  return notices.isNotEmpty || m.next != null || m.recent.isNotEmpty;
});

class KioskInfoPanel extends ConsumerWidget {
  const KioskInfoPanel({super.key, required this.rail});

  /// Beside the board (cards stacked) or under it (cards side by side).
  final bool rail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(nowProvider).value ?? DateTime.now();
    final notices = kioskNotices(
      ref.watch(messagesProvider).value ?? const [],
      now,
    );
    final matches = kioskMatches(
      slots: ref.watch(prioritySlotsProvider),
      results: ref.watch(matchResultsProvider).value ?? const {},
      today: Day.fromDateTime(now),
    );
    final cards = [
      if (notices.isNotEmpty) _NoticesCard(notices: notices),
      if (matches.next != null || matches.recent.isNotEmpty)
        _MatchesCard(next: matches.next, recent: matches.recent),
    ];
    if (cards.isEmpty) return const SizedBox.shrink();
    const gap = 12.0;
    final body = rail
        // Cards are as tall as their content, from the top; a very full
        // rail scrolls rather than squeezing a card.
        ? SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < cards.length; i++) ...[
                  if (i > 0) const SizedBox(height: gap),
                  cards[i],
                ],
              ],
            ),
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < cards.length; i++) ...[
                if (i > 0) const SizedBox(width: gap),
                Expanded(child: cards[i]),
              ],
            ],
          );
    return Padding(padding: const EdgeInsets.all(12), child: body);
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
  const _NoticesCard({required this.notices});

  final List<Message> notices;

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

  void _open(Message m) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(m.title ?? ''),
        content: SingleChildScrollView(child: Text(m.body)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Zavřít'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final notices = widget.notices;
    final scheme = Theme.of(context).colorScheme;
    final m = notices[_index.clamp(0, notices.length - 1)];
    final until = m.expiresAt;
    return _Card(
      icon: Icons.campaign_outlined,
      title: 'NÁSTĚNKA',
      child: InkWell(
        onTap: () => _open(m),
        borderRadius: BorderRadius.circular(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: AnimatedSwitcher(
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
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Flexible(
                        child: Text(
                          m.body,
                          maxLines: 6,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 15, height: 1.3),
                        ),
                      ),
                      if (until != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          'Platí do ${until.toLocal().day}. ${until.toLocal().month}.',
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
  const _MatchesCard({required this.next, required this.recent});

  final PrioritySlot? next;
  final List<PrioritySlot> recent;

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
      child: SingleChildScrollView(
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
              _MatchRow(slot: n, result: results[n.id], upcoming: true),
            ],
            if (n != null && recent.isNotEmpty) const SizedBox(height: 12),
            if (recent.isNotEmpty) ...[
              Text('POSLEDNÍ VÝSLEDKY', style: label),
              for (final s in recent) ...[
                const SizedBox(height: 6),
                _MatchRow(slot: s, result: results[s.id]),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _MatchRow extends StatelessWidget {
  const _MatchRow({required this.slot, this.result, this.upcoming = false});

  final PrioritySlot slot;
  final MatchResult? result;
  final bool upcoming;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final score = hasScoreData(result)
        ? pointsLabel(result!.homePoints, result!.awayPoints)
        : null;
    final when =
        '${dayLabel(slot.date)}'
        '${slot.timeKnown ? ' ${slot.startsAt.display()}' : ''}';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
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
        ],
      ],
    );
  }
}

/// The notices in the kiosk's status bar, between the clock and
/// „Rezervace tréninku“: the title of one notice, large enough to read from across
/// the room, and every few seconds (the admin's notice rotation) a soft
/// cross-fade to the next, right where it stays. Nothing moves in between —
/// a running news strip pulled the eye all the time. A tap opens the notice
/// in full; its text is also in the drawer. The newest comes first, and a
/// fresh one (0081) wears „NOVÉ“ or stays longer, as the admin chose.
library;

import 'package:flutter/material.dart';

import '../../domain/kiosk_panel.dart' show isFreshNotice;
import '../../domain/models.dart';
import 'kiosk_new_chip.dart';
import 'kiosk_notice_turns.dart';

class KioskHeadline extends StatefulWidget {
  const KioskHeadline({
    super.key,
    required this.notices,
    required this.turn,
    required this.now,
    required this.fresh,
    required this.freshDays,
    required this.onOpen,
  });

  /// Newest first (`kioskNotices`).
  final List<Message> notices;
  final Duration turn;

  /// The kiosk's clock: a notice stops being fresh as the minutes go by.
  final DateTime now;

  /// What a fresh notice gets (0081) and for how many days it is fresh.
  final KioskNoticesFresh fresh;
  final int freshDays;
  final void Function(Message notice) onOpen;

  @override
  State<KioskHeadline> createState() => _KioskHeadlineState();
}

class _KioskHeadlineState extends State<KioskHeadline>
    with KioskNoticeTurns<KioskHeadline> {
  @override
  List<Message> get notices => widget.notices;

  @override
  Duration get turn => widget.turn;

  @override
  KioskNoticesFresh get fresh => widget.fresh;

  @override
  int get freshDays => widget.freshDays;

  @override
  DateTime get now => widget.now;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final shown = noticeIndex;
    final m = notices[shown];
    final isNew = fresh.highlights && isFreshNotice(m, now, freshDays);
    return InkWell(
      onTap: () => widget.onOpen(m),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        // The whole line fades — icon, title and counter — each centred on
        // its own across the full width: the last one fades out where it
        // was, the next one in where it stays. Nothing jumps after the fade.
        child: SizedBox(
          width: double.infinity,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 600),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.center,
              children: [...previous, ?current],
            ),
            child: Row(
              key: ValueKey(m.id),
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.campaign_outlined, size: 26, color: scheme.primary),
                const SizedBox(width: 10),
                if (isNew) ...[
                  const KioskNewChip(),
                  const SizedBox(width: 10),
                ],
                // Loose: the counter sits right after the title, not at the
                // far end of the bar; a long title ends in an ellipsis.
                Flexible(
                  child: Text(
                    (m.title ?? '').trim().isEmpty ? m.body : m.title!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
                if (notices.length > 1) ...[
                  const SizedBox(width: 12),
                  Text(
                    '${shown + 1}/${notices.length}',
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The notices in the kiosk's status bar, between the clock and
/// „Rezervace tréninku“: the title of one notice, large enough to read from across
/// the room, and every few seconds (the admin's notice rotation) a soft
/// cross-fade to the next, right where it stays. Nothing moves in between —
/// a running news strip pulled the eye all the time. A tap opens the notice
/// in full; its text is also in the drawer. The newest comes first, and a
/// fresh one (0080) wears „NOVÉ“ or stays longer, as the admin chose.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/kiosk_panel.dart' show isFreshNotice, kioskNoticeTurn;
import '../../domain/models.dart';
import 'kiosk_new_chip.dart';

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

  /// What a fresh notice gets (0080) and for how many days it is fresh.
  final KioskNoticesFresh fresh;
  final int freshDays;
  final void Function(Message notice) onOpen;

  @override
  State<KioskHeadline> createState() => _KioskHeadlineState();
}

class _KioskHeadlineState extends State<KioskHeadline> {
  Timer? _timer;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(KioskHeadline old) {
    super.didUpdateWidget(old);
    final notices = widget.notices;
    if (notices.firstOrNull?.id != old.notices.firstOrNull?.id) {
      // A new notice on top (or the order changed): the newest at once,
      // for a whole turn of its own.
      _index = 0;
      _start();
    } else if (_index >= notices.length) {
      // Fewer notices: the last one, so the counter stays within them.
      _index = notices.isEmpty ? 0 : notices.length - 1;
      _start();
    } else if (old.turn != widget.turn ||
        old.fresh != widget.fresh ||
        old.freshDays != widget.freshDays) {
      _start();
    }
  }

  /// A turn for the notice shown: one-shot, re-armed after every step, so
  /// each notice gets its own — twice the admin's for a fresh one when the
  /// admin wants fresh ones shown longer.
  void _start() {
    _timer?.cancel();
    final notices = widget.notices;
    if (notices.isEmpty) return;
    _timer = Timer(
      kioskNoticeTurn(
        notices[_index % notices.length],
        now: widget.now,
        turn: widget.turn,
        fresh: widget.fresh,
        days: widget.freshDays,
      ),
      _next,
    );
  }

  void _next() {
    if (!mounted) return;
    final n = widget.notices.length;
    if (n > 1) setState(() => _index = (_index + 1) % n);
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
    final notices = widget.notices;
    final m = notices[_index % notices.length];
    final isNew =
        widget.fresh.highlights &&
        isFreshNotice(m, widget.now, widget.freshDays);
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
                    '${_index % notices.length + 1}/${notices.length}',
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

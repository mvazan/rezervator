/// The notices in the kiosk's status bar, between the clock and
/// „Rezervovat“: the title of one notice, large enough to read from across
/// the room, and every few seconds (the admin's notice rotation) a soft
/// cross-fade to the next. Nothing moves in between — a running news strip
/// pulled the eye all the time. A tap opens the notice in full; its text is
/// also in the drawer.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../domain/models.dart';

class KioskHeadline extends StatefulWidget {
  const KioskHeadline({
    super.key,
    required this.notices,
    required this.turn,
    required this.onOpen,
  });

  final List<Message> notices;
  final Duration turn;
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
    if (old.turn != widget.turn) _start();
  }

  void _start() {
    _timer?.cancel();
    _timer = Timer.periodic(widget.turn, (_) {
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
    final scheme = Theme.of(context).colorScheme;
    final notices = widget.notices;
    final m = notices[_index % notices.length];
    return InkWell(
      onTap: () => widget.onOpen(m),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.campaign_outlined, size: 26, color: scheme.primary),
            const SizedBox(width: 10),
            // Loose: the counter sits right after the title, not at the far
            // end of the bar.
            Flexible(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 600),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                layoutBuilder: (current, previous) => Stack(
                  alignment: Alignment.centerLeft,
                  children: [...previous, ?current],
                ),
                child: Text(
                  (m.title ?? '').trim().isEmpty ? m.body : m.title!,
                  key: ValueKey(m.id),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ),
            if (notices.length > 1) ...[
              const SizedBox(width: 12),
              Text(
                '${_index % notices.length + 1}/${notices.length}',
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

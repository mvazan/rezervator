/// A swipe across a score sheet: the kiosk's Zápis pages with it (0079).
library;

import 'package:flutter/widgets.dart';

/// A quick sideways stroke of one finger over [child] — at least
/// [minDistance] across, mostly sideways, within [maxDuration] — calls
/// [onSwipe]: 1 for a stroke to the left (the next match), -1 to the right
/// (the previous one). A plain [Listener]: it takes no part in the gesture
/// arena, so the pinch-zoom and the taps under it work as before. [active]
/// says whether a stroke counts now — not while the sheet is zoomed in,
/// where a stroke pans it.
class SheetSwipe extends StatefulWidget {
  const SheetSwipe({
    super.key,
    required this.onSwipe,
    required this.child,
    this.active,
  });

  final void Function(int direction) onSwipe;
  final bool Function()? active;
  final Widget child;

  static const minDistance = 60.0;
  static const maxDuration = Duration(milliseconds: 700);

  @override
  State<SheetSwipe> createState() => _SheetSwipeState();
}

class _SheetSwipeState extends State<SheetSwipe> {
  int _down = 0;
  int? _pointer;
  Offset _start = Offset.zero;
  Duration _startedAt = Duration.zero;

  /// A second finger went down: a pinch, not a swipe.
  bool _several = false;

  void _onDown(PointerDownEvent e) {
    _down++;
    if (_down == 1) {
      _pointer = e.pointer;
      _start = e.position;
      _startedAt = e.timeStamp;
      _several = false;
    } else {
      _several = true;
    }
  }

  void _onUp(PointerUpEvent e) {
    if (e.pointer == _pointer && !_several && (widget.active?.call() ?? true)) {
      final d = e.position - _start;
      final quick = e.timeStamp - _startedAt <= SheetSwipe.maxDuration;
      if (quick &&
          d.dx.abs() >= SheetSwipe.minDistance &&
          d.dx.abs() > 2 * d.dy.abs()) {
        widget.onSwipe(d.dx < 0 ? 1 : -1);
      }
    }
    _lift();
  }

  void _lift() {
    if (_down > 0) _down--;
    if (_down == 0) _pointer = null;
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: _onDown,
    onPointerUp: _onUp,
    onPointerCancel: (_) => _lift(),
    child: widget.child,
  );
}

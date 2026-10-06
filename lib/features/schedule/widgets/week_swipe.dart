import 'package:flutter/material.dart';

/// A sideways swipe over [child] turns the week: left for the next one,
/// right for the previous one. The one rule behind every strip that stands
/// for a week (the header's range, the day chips) — taps inside [child] keep
/// working, only a fast enough horizontal drag is taken here. The days below
/// are a pager of their own and turn the day.
class WeekSwipe extends StatelessWidget {
  const WeekSwipe({super.key, required this.onGo, required this.child});

  /// -1 / +1 a week — the same callback the header's arrows call.
  final void Function(int delta) onGo;

  final Widget child;

  /// A swipe faster than this (logical px/s) turns the week.
  static const velocity = 250.0;

  void _onSwipe(DragEndDetails details) {
    final v = details.primaryVelocity ?? 0;
    if (v <= -velocity) {
      onGo(1);
    } else if (v >= velocity) {
      onGo(-1);
    }
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onHorizontalDragEnd: _onSwipe,
    child: child,
  );
}

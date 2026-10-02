import 'package:flutter/material.dart';

import '../../../domain/duties.dart';
import '../../../domain/models.dart';
import 'home_header.dart';
import 'week_range_nav.dart';

/// The calendar's take on the home's top strip: [HomeHeader] with the week
/// navigation in its middle slot. The strip itself — title, padding, the
/// icons at the right edge — is the shared one, so it lines up with Můj
/// přehled's to the pixel.
class WeekHeader extends StatefulWidget {
  const WeekHeader({
    super.key,
    required this.monday,
    required this.weekOffset,
    required this.onGo,
    required this.trailing,
    this.duty,
    this.onDutyTap,
  });

  final Day monday;

  /// 0 = this week → no "dnes" button.
  final int weekOffset;

  /// Week navigation: -1 / +1 a week, 0 = today.
  final void Function(int delta) onGo;

  /// Action icons pinned to the right edge — in landscape the shell has no
  /// AppBar and parks its icons here (one shared top line).
  final List<Widget> trailing;

  /// Who serves in the canteen this week (0050): a `labelSmall` line under
  /// the range, tinted when it is my duty; null for no line.
  final DutyHeader? duty;

  /// Tapping the duty line — the calendar opens Klubovna → Služby.
  final VoidCallback? onDutyTap;

  @override
  State<WeekHeader> createState() => _WeekHeaderState();
}

class _WeekHeaderState extends State<WeekHeader> {
  /// Which way the last move went: +1 a later week, -1 an earlier one — the
  /// range slides in from that side.
  int _direction = 1;

  /// A swipe faster than this (logical px/s) turns the week.
  static const _swipeVelocity = 250.0;

  @override
  void didUpdateWidget(WeekHeader old) {
    super.didUpdateWidget(old);
    if (widget.monday != old.monday) {
      _direction = widget.monday.isAfter(old.monday) ? 1 : -1;
    }
  }

  /// Dragging the strip sideways turns the week, as swiping the days below
  /// turns the day: left for the next week, right for the previous one.
  void _onSwipe(DragEndDetails details) {
    final v = details.primaryVelocity ?? 0;
    if (v <= -_swipeVelocity) {
      widget.onGo(1);
    } else if (v >= _swipeVelocity) {
      widget.onGo(-1);
    }
  }

  @override
  Widget build(BuildContext context) => HomeHeader(
    trailing: widget.trailing,
    middle: (stacked) => GestureDetector(
      // The arrows and the duty line keep their taps; only a sideways
      // drag is taken here.
      behavior: HitTestBehavior.translucent,
      onHorizontalDragEnd: _onSwipe,
      child: ClipRect(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (child, animation) {
            final incoming = child.key == ValueKey(widget.monday);
            // The new week enters from the side it is on, the old one
            // leaves to the other (its animation runs backwards).
            final from = Offset(
              incoming ? _direction * 0.6 : -_direction * 0.6,
              0,
            );
            return FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween(
                  begin: from,
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            );
          },
          child: KeyedSubtree(
            key: ValueKey(widget.monday),
            child: _weekNav(context, stacked),
          ),
        ),
      ),
    ),
  );

  // On one line the week selector sits centred between the title and the
  // icons; stacked it has the second line to itself, so the range can take
  // all the width between the two arrows.
  Widget _weekNav(BuildContext context, bool stacked) {
    final nav = WeekRangeNav(
      monday: widget.monday,
      weekOffset: widget.weekOffset,
      onGo: widget.onGo,
      stacked: stacked,
    );
    final duty = widget.duty;
    if (duty == null) return nav;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        nav,
        // A button to a screen reader (when it opens something); the hit
        // area spans the nav's width and is 32dp tall, the line itself
        // stays one small centred row.
        Semantics(
          button: widget.onDutyTap != null,
          child: InkWell(
            onTap: widget.onDutyTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minWidth: double.infinity,
                minHeight: 32,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Center(
                  widthFactor: 1,
                  heightFactor: 1,
                  child: Text(
                    duty.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: duty.mine
                          ? scheme.primary
                          : scheme.onSurfaceVariant,
                      fontWeight: duty.mine ? FontWeight.w700 : null,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

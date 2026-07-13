/// Shared building blocks of the calendar-style schedule views: the hour
/// ruler, one day column (a Stack of time-positioned entries over hour
/// gridlines), the day header, and the column-snap physics. The kiosk board
/// (fit-height, read-only) and the app's week view (fixed scale, scrollable,
/// interactive) both compose these — they share ONE [CalendarWindow] +
/// px/minute pair per build, so the ruler and every column are geometrically
/// aligned by construction.
library;

import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../domain/calendar_layout.dart';
import '../../../domain/models.dart';

/// Width of the hour ruler column.
const double calendarRulerWidth = 46.0;

/// Height of every day-column header (shared so column content below the
/// headers starts on one line).
const double calendarHeaderHeight = 56.0;

/// Equal day-column width: `clamp(160, (width−ruler)/7, 220)` so a typical
/// tablet shows exactly 7 days without horizontal scroll.
double boardColumnWidth(double availableWidth) =>
    ((availableWidth - calendarRulerWidth) / 7).clamp(160.0, 220.0);

/// One time-positioned widget inside a [CalendarColumn].
class CalendarEntry {
  const CalendarEntry({
    required this.start,
    required this.end,
    required this.child,
  });

  final HourMinute start;
  final HourMinute end;
  final Widget child;
}

/// The hour ruler: right-aligned `HH:00` labels on the shared hour lines,
/// plus quieter `HH:30` labels when [halfHourMarks] is set (the alley
/// actually uses half-hour block boundaries). Labels thin out automatically
/// when the scale gets too tight.
class HourRuler extends StatelessWidget {
  const HourRuler({
    super.key,
    required this.window,
    required this.pxPerMinute,
    this.halfHourMarks = false,
  });

  final CalendarWindow window;
  final double pxPerMinute;

  /// Also label (and let columns line) the half hours — only worth the ink
  /// when some visible block starts/ends on one.
  final bool halfHourMarks;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hourPx = pxPerMinute * 60;
    final step = hourPx >= 26 ? 1 : (hourPx >= 13 ? 2 : 3);
    final showHalves = halfHourMarks && step == 1 && hourPx >= 28;
    final labels = <Widget>[];
    for (var m = window.startMinute; m <= window.endMinute; m += 30) {
      final isHour = m % 60 == 0;
      if (isHour && (m ~/ 60) % step != 0) continue;
      if (!isHour && !showHalves) continue;
      labels.add(Positioned(
        top: (m - window.startMinute) * pxPerMinute - 6,
        right: 6,
        child: Text(
          '${'${m ~/ 60}'.padLeft(2, '0')}:${'${m % 60}'.padLeft(2, '0')}',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: scheme.onSurfaceVariant
                .withValues(alpha: isHour ? 0.7 : 0.45),
          ),
        ),
      ));
    }
    return SizedBox(
      width: calendarRulerWidth,
      height: window.minutes * pxPerMinute,
      child: Stack(clipBehavior: Clip.none, children: labels),
    );
  }
}

/// One day's time area: hour gridlines, an optional full-height [background]
/// (e.g. the closed-day filler), the time-positioned [entries], a "now" line
/// when [nowMinute] is set, and — when [onTapFreeAt] is given — taps on
/// uncovered space reported as the minute under the finger. Entries sit
/// above the tap target, so a tap only counts as "free" if no entry consumed
/// it AND the caller's own gap check agrees.
class CalendarColumn extends StatelessWidget {
  const CalendarColumn({
    super.key,
    required this.window,
    required this.pxPerMinute,
    required this.entries,
    this.background,
    this.nowMinute,
    this.onTapFreeAt,
    this.halfHourMarks = false,
  });

  final CalendarWindow window;
  final double pxPerMinute;
  final List<CalendarEntry> entries;
  final Widget? background;

  /// Draw fainter half-hour gridlines too (see [HourRuler.halfHourMarks]).
  final bool halfHourMarks;

  /// Minutes from midnight to draw the current-time line at (today's column
  /// only), already known to lie inside the window.
  final int? nowMinute;

  /// Admin-only: called with the minute-from-midnight under a tap that
  /// landed on empty (entry-free) space.
  final void Function(int minute)? onTapFreeAt;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final firstHour = window.startMinute ~/ 60 + 1;
    final lastHour = (window.endMinute - 1) ~/ 60;

    Widget base = Stack(
      children: [
        if (background != null) Positioned.fill(child: background!),
        for (var h = firstHour; h <= lastHour; h++)
          Positioned(
            top: (h * 60 - window.startMinute) * pxPerMinute,
            left: 0,
            right: 0,
            child: Divider(
              height: 1,
              thickness: 1,
              color: scheme.outlineVariant.withValues(alpha: 0.25),
            ),
          ),
        if (halfHourMarks)
          for (var m = window.startMinute - window.startMinute % 60 + 30;
              m < window.endMinute;
              m += 60)
            if (m > window.startMinute)
              Positioned(
                top: (m - window.startMinute) * pxPerMinute,
                left: 0,
                right: 0,
                child: Divider(
                  height: 1,
                  thickness: 1,
                  color: scheme.outlineVariant.withValues(alpha: 0.12),
                ),
              ),
        for (final entry in entries)
          Positioned(
            top: window.topFor(entry.start, pxPerMinute),
            left: 0,
            right: 0,
            height: window.heightFor(entry.start, entry.end, pxPerMinute),
            child: entry.child,
          ),
        if (nowMinute != null)
          Positioned(
            top: (nowMinute! - window.startMinute) * pxPerMinute - 1,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: scheme.error,
                      shape: BoxShape.circle,
                    ),
                  ),
                  Expanded(child: Container(height: 2, color: scheme.error)),
                ],
              ),
            ),
          ),
      ],
    );
    if (onTapFreeAt != null) {
      base = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) =>
            onTapFreeAt!(window.minuteAt(details.localPosition.dy, pxPerMinute)),
        child: base,
      );
    }
    return SizedBox(height: window.minutes * pxPerMinute, child: base);
  }
}

/// A type/rental-colored band for an event rendered outside any block —
/// positioned by a [CalendarEntry] at the event's true time.
class CalendarEventBand extends StatelessWidget {
  const CalendarEventBand({
    super.key,
    required this.background,
    required this.foreground,
    required this.text,
    this.bold = false,
  });

  final Color background;
  final Color foreground;
  final String text;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 1.5),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
      ),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        text,
        textAlign: TextAlign.center,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 10,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w600,
          color: foreground,
        ),
      ),
    );
  }
}

/// One board column's header: the day label (today gets the "DNES · …"
/// gradient treatment) plus a priority-slot strip, or a quiet [subtitle]
/// when there are no priority slots. Typed on [date] so widget tests can
/// enumerate visible days.
class BoardColumnHeader extends StatelessWidget {
  const BoardColumnHeader({
    super.key,
    required this.date,
    required this.isToday,
    required this.priority,
    this.subtitle,
  });

  final Day date;
  final bool isToday;
  final List<PrioritySlot> priority;

  /// Quiet second line shown when [priority] is empty (e.g. "3 volné").
  final String? subtitle;

  static const _gradientColors = [Color(0xFF6366F1), Color(0xFF22D3EE)];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: calendarHeaderHeight,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        gradient:
            isToday ? const LinearGradient(colors: _gradientColors) : null,
        color: isToday ? null : scheme.surfaceContainerHigh,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            isToday ? 'DNES · ${dayLabel(date)}' : dayLabel(date),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: isToday ? Colors.white : scheme.onSurface,
            ),
          ),
          if (priority.isNotEmpty)
            Text(
              priority
                  .map((m) => '${m.type.isMatch ? '🏆' : '⛔'} ${m.title}')
                  .join(' · '),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                color: isToday
                    ? Colors.white.withValues(alpha: 0.9)
                    : scheme.primary,
              ),
            )
          else if (subtitle != null)
            Text(
              subtitle!,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                color: isToday
                    ? Colors.white.withValues(alpha: 0.85)
                    : scheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
        ],
      ),
    );
  }
}

/// Column-snap scroll physics for the horizontal day list. A plain
/// [PageView] can't be used instead because its `viewportFraction` — the
/// mechanism that would let multiple column-widths share one viewport — is
/// fixed at [PageController] construction time, before the [LayoutBuilder]
/// that computes the column width from the available width ever runs. This
/// mirrors [PageScrollPhysics]'s own `createBallisticSimulation`,
/// substituting `pixels / columnWidth` for its "page" unit so a fling
/// settles on the nearest column boundary.
class ColumnSnapPhysics extends ScrollPhysics {
  const ColumnSnapPhysics({required this.columnWidth, super.parent});

  final double columnWidth;

  @override
  ColumnSnapPhysics applyTo(ScrollPhysics? ancestor) =>
      ColumnSnapPhysics(columnWidth: columnWidth, parent: buildParent(ancestor));

  double _targetPixels(
      ScrollMetrics position, Tolerance tolerance, double velocity) {
    var column = position.pixels / columnWidth;
    if (velocity < -tolerance.velocity) {
      column -= 0.5;
    } else if (velocity > tolerance.velocity) {
      column += 0.5;
    }
    return column.roundToDouble() * columnWidth;
  }

  @override
  Simulation? createBallisticSimulation(
      ScrollMetrics position, double velocity) {
    if ((velocity <= 0.0 && position.pixels <= position.minScrollExtent) ||
        (velocity >= 0.0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }
    final tolerance = toleranceFor(position);
    final target = _targetPixels(position, tolerance, velocity)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (target != position.pixels) {
      return ScrollSpringSimulation(spring, position.pixels, target, velocity,
          tolerance: tolerance);
    }
    return null;
  }

  @override
  bool get allowImplicitScrolling => false;
}

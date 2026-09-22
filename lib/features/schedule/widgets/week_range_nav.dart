/// The week range navigation row: ‹ arrows › around the "po–ne" range, plus
/// a "dnes" button once off the current week. Split out of [WeekHeader] so
/// the public overview can put the same control directly under its AppBar
/// title (no second, app-branded strip beneath it) — see
/// `PublicScheduleScreen`.
library;

import 'package:flutter/material.dart';

import '../../../domain/models.dart';

class WeekRangeNav extends StatelessWidget {
  const WeekRangeNav({
    super.key,
    required this.monday,
    required this.weekOffset,
    required this.onGo,
    this.stacked = false,
  });

  final Day monday;

  /// 0 = this week → no "dnes" button.
  final int weekOffset;

  /// Week navigation: -1 / +1 a week, 0 = today.
  final void Function(int delta) onGo;

  /// True lets the range label claim the whole row (the caller's own
  /// title/icons already took the line above); false centers the row as a
  /// unit, for sharing a line with a title.
  final bool stacked;

  @override
  Widget build(BuildContext context) {
    final navPrev = IconButton(
      icon: const Icon(Icons.chevron_left),
      visualDensity: VisualDensity.compact,
      onPressed: () => onGo(-1),
    );
    final navNext = IconButton(
      icon: const Icon(Icons.chevron_right),
      visualDensity: VisualDensity.compact,
      onPressed: () => onGo(1),
    );
    final range = Text(
      rangeLabel(monday, monday.addDays(6)),
      textAlign: TextAlign.center,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.titleMedium,
    );
    final todayButton = weekOffset == 0
        ? null
        : TextButton(onPressed: () => onGo(0), child: const Text('dnes'));
    return stacked
        ? Row(
            children: [
              navPrev,
              Expanded(child: range),
              ?todayButton,
              navNext,
            ],
          )
        : Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              navPrev,
              range,
              ?todayButton,
              navNext,
            ],
          );
  }
}

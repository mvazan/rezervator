/// Seven-day chip strip for the day pager: one chip per Monday..Sunday day
/// of the currently displayed week, showing the day's number, a dimmed look
/// for closed days, and a dot count of the caller's own live reservations
/// that day. Purely presentational — selection and day-closed state are
/// supplied by the caller (the shell owns the schedule computation).
library;

import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../domain/schedule.dart';

class DayChipStrip extends StatelessWidget {
  const DayChipStrip({
    super.key,
    required this.days,
    required this.selectedIndex,
    required this.myCountByIndex,
    required this.onSelect,
  });

  /// Exactly 7 entries, Monday..Sunday — the same [DaySchedule] list the
  /// pager's pages are built from.
  final List<DaySchedule> days;

  /// Index (0..6) of the currently shown/selected day.
  final int selectedIndex;

  /// Count of the caller's own live reservations for each day, by index —
  /// rendered as dots under the day number.
  final List<int> myCountByIndex;

  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        for (var i = 0; i < days.length; i++)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: _chip(context, scheme, i),
            ),
          ),
      ],
    );
  }

  Widget _chip(BuildContext context, ColorScheme scheme, int index) {
    final day = days[index];
    final selected = index == selectedIndex;
    final closed = day is ClosedDay;
    final dots = myCountByIndex[index].clamp(0, 3);

    final foreground = selected ? Colors.white : scheme.onSurface;
    final decoration = BoxDecoration(
      borderRadius: BorderRadius.circular(14),
      gradient: selected
          ? const LinearGradient(colors: [Color(0xFF6366F1), Color(0xFF22D3EE)])
          : null,
      color: selected ? null : scheme.surfaceContainerHigh,
    );

    return Opacity(
      opacity: closed && !selected ? 0.45 : 1,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => onSelect(index),
          child: Container(
            decoration: decoration,
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  weekdaysShort[day.date.weekday - 1],
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: foreground.withValues(alpha: selected ? 1 : 0.7),
                  ),
                ),
                Text(
                  '${day.date.day}',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: foreground,
                  ),
                ),
                const SizedBox(height: 3),
                SizedBox(
                  height: 5,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var d = 0; d < dots; d++)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 1),
                          child: Container(
                            width: 4,
                            height: 4,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: selected
                                  ? Colors.white
                                  : scheme.primary.withValues(alpha: 0.8),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

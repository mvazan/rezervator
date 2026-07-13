/// Shared day header for the schedule views: a date badge, the day's full
/// Czech name, an availability/closed chip, and the match strip. Purely
/// presentational — callers compute the chip label and pass in matches.
library;

import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../domain/models.dart';

class DayHeader extends StatelessWidget {
  const DayHeader({
    super.key,
    required this.date,
    required this.priority,
    this.chipLabel,
    this.closedReason,
  });

  final Day date;
  final List<PrioritySlot> priority;

  /// Preformatted trailing chip text (e.g. 'N volných'); omitted when the
  /// day is closed and [closedReason] is used instead.
  final String? chipLabel;

  /// Non-null when the day is closed: '' renders 'Zavřeno', otherwise
  /// 'Zavřeno — $closedReason'.
  final String? closedReason;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final reason = closedReason;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _dateBadge(scheme),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                dayFull(date),
                style: textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            if (reason != null)
              _pill(
                text: reason.isEmpty ? 'Zavřeno' : 'Zavřeno — $reason',
                background: scheme.surfaceContainerHighest,
                foreground: scheme.onSurfaceVariant,
              )
            else if (chipLabel != null)
              _pill(
                text: chipLabel!,
                background: scheme.primaryContainer.withValues(alpha: 0.5),
                foreground: scheme.onPrimaryContainer,
                bold: true,
              ),
          ],
        ),
        for (final m in priority)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 52),
            child: Text(
              '${m.type.isMatch ? '🏆' : '⛔'} ${m.title} · ${m.startsAt.display()}–${m.endsAt.display()}',
              style: TextStyle(color: scheme.primary, fontSize: 13),
            ),
          ),
      ],
    );
  }

  Widget _dateBadge(ColorScheme scheme) => Container(
        width: 34,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              weekdaysShort[date.weekday - 1],
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: scheme.onPrimaryContainer,
                height: 1.1,
              ),
            ),
            Text(
              '${date.day}',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: scheme.onPrimaryContainer,
                height: 1.1,
              ),
            ),
          ],
        ),
      );

  Widget _pill({
    required String text,
    required Color background,
    required Color foreground,
    bool bold = false,
  }) =>
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11,
            color: foreground,
            fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      );
}

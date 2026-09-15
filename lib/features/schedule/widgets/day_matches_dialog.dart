/// The day-column header lists a day's matches (and blockages) in a strip
/// whose lines are one-line, ellipsised — a long "Home – Away" pair is cut to
/// "…". Tapping the strip opens this dialog, where the same events read in
/// full. Shared by the week header ([BoardColumnHeader]) and the pager header
/// ([DayHeader]); the kiosk board is a passive display and does not use it.
library;

import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../domain/models.dart';

/// Lists [events] (the header's own `headerEvents` — matches and blockages,
/// no úklid children) for [date] in full. No-op when [events] is empty.
Future<void> showDayMatchesDialog(
  BuildContext context,
  Day date,
  List<PrioritySlot> events,
) {
  if (events.isEmpty) return Future.value();
  return showDialog<void>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      final scheme = theme.colorScheme;
      return AlertDialog(
        title: Text(dayFull(date)),
        content: SizedBox(
          width: 340,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final m in events)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          m.type.isMatch
                              ? Icons.emoji_events_outlined
                              : Icons.block,
                          size: 20,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(m.title, style: theme.textTheme.titleSmall),
                              Text(
                                _meta(m),
                                style: theme.textTheme.bodySmall
                                    ?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Zavřít'),
          ),
        ],
      );
    },
  );
}

/// Time, then doma/venku for a match (a blockage has no side), then its note.
String _meta(PrioritySlot m) {
  final parts = [
    '${m.startsAt.display()}–${m.endsAt.display()}',
    if (m.type.isMatch) m.isAway ? 'venku' : 'doma',
    if (m.description.isNotEmpty) m.description,
  ];
  return parts.join(' · ');
}

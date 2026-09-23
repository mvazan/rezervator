/// The day-column header lists a day's matches (and blockages) in a strip
/// whose lines are one-line, ellipsised — a long "Home – Away" pair is cut to
/// "…". Tapping the strip opens this dialog, where the same events read in
/// full — a federation match also shows its score/pins/video (PR B) and taps
/// through to [MatchDetailScreen]. Shared by the week header
/// ([BoardColumnHeader]) and the pager header ([DayHeader]); the kiosk board
/// is a passive display and does not use it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui.dart';
import '../../../data/clock.dart';
import '../../../data/providers.dart';
import '../../../domain/models.dart';
import '../../../domain/results.dart';
import '../../clubhouse/match_detail_screen.dart';

/// Lists [events] (the header's own `headerEvents` — matches and blockages,
/// no úklid children) for [date] in full. No-op when [events] is empty.
/// [launch] is injectable so tests never reach the platform's browser.
Future<void> showDayMatchesDialog(
  BuildContext context,
  Day date,
  List<PrioritySlot> events, {
  void Function(String url) launch = launchWeb,
}) {
  if (events.isEmpty) return Future.value();
  // Captured before the dialog opens: the same Navigator that will host the
  // pushed detail screen once the dialog (its own top-most route) pops —
  // the dialog builder's own BuildContext is on its way out by then.
  final navigator = Navigator.of(context);
  return showDialog<void>(
    context: context,
    builder: (dialogContext) {
      final theme = Theme.of(dialogContext);
      final scheme = theme.colorScheme;
      return AlertDialog(
        title: Text(dayFull(date)),
        content: SizedBox(
          width: 340,
          child: SingleChildScrollView(
            child: Consumer(
              builder: (context, ref, _) {
                final results = ref.watch(matchResultsProvider).value ??
                    const <String, MatchResult>{};
                final now = ref.watch(nowProvider).value ?? DateTime.now();
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final m in events)
                      _eventRow(
                        theme,
                        scheme,
                        m,
                        m.fromFederation ? results[m.id] : null,
                        now,
                        launch,
                        m.fromFederation
                            ? () {
                                navigator.pop();
                                navigator.push(MaterialPageRoute(
                                  builder: (_) =>
                                      MatchDetailScreen(matchId: m.id),
                                ));
                              }
                            : null,
                      ),
                  ],
                );
              },
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Zavřít'),
          ),
        ],
      );
    },
  );
}

Widget _eventRow(
  ThemeData theme,
  ColorScheme scheme,
  PrioritySlot m,
  MatchResult? result,
  DateTime now,
  void Function(String url) launch,
  VoidCallback? onOpen,
) {
  final live = result != null && isLive(m, result, now);
  final pins =
      result == null ? '' : pinsLabel(result.homeTotal, result.awayTotal);
  final row = Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(
        m.type.isMatch ? Icons.emoji_events_outlined : Icons.block,
        size: 20,
        color: scheme.onSurfaceVariant,
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (result == null)
              Text(m.title, style: theme.textTheme.titleSmall)
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(m.title, style: theme.textTheme.titleSmall),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    pointsLabel(result.homePoints, result.awayPoints),
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  if (live)
                    Text(
                      ' • probíhá',
                      style: TextStyle(color: scheme.error),
                    ),
                ],
              ),
            Text(
              _meta(m),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (pins.isNotEmpty)
              Text(
                pins,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
      if (m.videoUrl case final url?)
        IconButton(
          icon: const Icon(Icons.play_circle_outline),
          tooltip: 'Video',
          onPressed: () => launch(url),
        ),
    ],
  );
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: onOpen == null
        ? row
        : InkWell(onTap: onOpen, child: row),
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

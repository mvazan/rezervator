/// The day-column header lists a day's matches (and blockages) in a strip
/// whose lines are one-line, ellipsised — a long "Home – Away" pair is cut to
/// "…". Tapping the strip opens this dialog, where the same events read in
/// full — a federation match also shows its score/pins/video (PR B) and, when
/// [showDayMatchesDialog] is opened interactively, taps through to
/// [MatchDetailScreen]. Shared by the week header ([BoardColumnHeader]) and
/// the pager header ([DayHeader]) — which the kiosk board and the public,
/// unauthenticated overview use too, always non-interactively (see
/// [showDayMatchesDialog]'s own [interactive] doc); the kiosk plays a
/// YouTube video in its own stream window instead.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui.dart';
import '../../../data/clock.dart';
import '../../../data/providers.dart';
import '../../../domain/kiosk_panel.dart' show hasKioskVideo;
import '../../../domain/models.dart';
import '../../../domain/results.dart';
import '../../clubhouse/match_detail_screen.dart';
import '../../clubhouse/widgets/match_title.dart';
import '../../clubhouse/widgets/match_video_icon.dart';
import '../../../core/push_screen.dart';

/// Lists [events] (the header's own `headerEvents` — matches and blockages,
/// no úklid children) for [date] in full. No-op when [events] is empty.
/// [launch] is injectable so tests never reach the platform's browser.
///
/// [interactive] gates BOTH the browser's video button and the tap-through
/// to [MatchDetailScreen] (scores/pins still render either way) — false on
/// the kiosk board (its own 60 s idle-reset `Listener`
/// never sees touches on a pushed route, and an external video browser on a
/// kiosk tablet is undesirable) and on the public, unauthenticated overview
/// (whose slots are auth-gated, so the detail screen would be a dead end).
/// [onOpenMatch] is the kiosk's own way in: a match with a score opens its
/// Zápis modal, with no navigation off the kiosk. [onPlayVideo] is the
/// kiosk's video control, the app's own (live badge / play button) at a
/// match with a YouTube video ([hasKioskVideo]; any other keeps the
/// trophy): a tap closes the dialog and plays it in the kiosk's stream
/// window. Only without [interactive] — the app keeps the browser.
/// [pulseLive] false keeps the live badge still (the kiosk's „Opakující se
/// animace“ off). [width] is the list's: the app's 340, the kiosk's as its
/// admin sets it (0075) — never past the screen, the dialog's own insets
/// keep it in.
Future<void> showDayMatchesDialog(
  BuildContext context,
  Day date,
  List<PrioritySlot> events, {
  void Function(String url) launch = launchWeb,
  bool interactive = true,
  void Function(PrioritySlot match)? onOpenMatch,
  void Function(PrioritySlot match)? onPlayVideo,
  bool pulseLive = true,
  double width = 340,
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
          width: width,
          child: SingleChildScrollView(
            child: Consumer(
              builder: (context, ref, _) {
                final results =
                    ref.watch(matchResultsProvider).value ??
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
                        pulseLive,
                        interactive
                            ? launch
                            // The kiosk: the video plays in its own window.
                            : onPlayVideo != null && hasKioskVideo(m)
                                ? (_) {
                                    navigator.pop();
                                    onPlayVideo(m);
                                  }
                                : null,
                        interactive && m.fromFederation
                            ? () {
                                navigator.pop();
                                pushScreen(
                                  navigator.context,
                                  (_) => MatchDetailScreen(matchId: m.id),
                                );
                              }
                            // The kiosk: a match with a score opens its Zápis
                            // in the kiosk's own modal.
                            : onOpenMatch != null &&
                                    m.fromFederation &&
                                    hasScoreData(results[m.id])
                                ? () {
                                    navigator.pop();
                                    onOpenMatch(m);
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
  bool pulseLive,
  void Function(String url)? launch,
  VoidCallback? onOpen,
) {
  final showScore = hasScoreData(result);
  final winner = displayWinner(result);
  final pins = result == null
      ? ''
      : pinsLabel(result.homeTotal, result.awayTotal);
  final league = _league(m);
  final small = theme.textTheme.bodySmall?.copyWith(
    color: scheme.onSurfaceVariant,
  );
  final row = Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      MatchLeading(
        slot: m,
        result: result,
        now: now,
        linksEnabled: launch != null,
        fallback: Icon(
          m.type.isMatch ? Icons.emoji_events_outlined : Icons.block,
          size: 20,
          color: scheme.onSurfaceVariant,
        ),
        launch: launch ?? launchWeb,
        pulse: pulseLive,
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The match and the time with the kuželna, the points at the
            // end, centred on the two — bolder and larger than the names,
            // the day's headline.
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MatchTitle(
                        slot: m,
                        winner: showScore ? winner : null,
                        style: theme.textTheme.titleSmall,
                      ),
                      Text(_where(m), style: small),
                    ],
                  ),
                ),
                if (showScore) ...[
                  const SizedBox(width: 8),
                  Text(
                    pointsLabel(result!.homePoints, result.awayPoints),
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ],
            ),
            // The competition and the round, the pins at the end — under
            // the points.
            if (league.isNotEmpty || pins.isNotEmpty)
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Expanded(child: Text(league, style: small)),
                  if (pins.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Text(pins, style: small),
                  ],
                ],
              ),
          ],
        ),
      ),
    ],
  );
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: onOpen == null ? row : InkWell(onTap: onOpen, child: row),
  );
}

/// Time, then where: „Kuželna {venue}“ once the site named the alley, else
/// doma/venku for a match (a blockage has no side).
String _where(PrioritySlot m) {
  final venue = m.venue ?? '';
  final parts = [
    '${m.startsAt.display()}–${m.endsAt.display()}',
    if (venue.isNotEmpty)
      'Kuželna $venue'
    else if (m.type.isMatch)
      m.isAway ? 'venku' : 'doma',
  ];
  return parts.join(' · ');
}

/// A federation match's competition and round; anything else its note (a
/// federation match's own note only repeats them, with the venue).
String _league(PrioritySlot m) {
  final parts = [
    if ((m.competition ?? '').isNotEmpty) m.competition!,
    if (m.round != null) '${m.round}. kolo',
  ];
  if (parts.isNotEmpty) return parts.join(' · ');
  return m.fromFederation ? '' : m.description;
}

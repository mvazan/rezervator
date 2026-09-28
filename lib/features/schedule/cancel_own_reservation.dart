/// Confirm-then-cancel for a player's OWN future reservation, with two
/// more ways out (0051): message the admins, or today's duty — the exact
/// dialog and copy the calendar (`ScheduleActions._cancel`'s `ownFuture`
/// branch) and „Můj přehled" both need, pulled out so the two call sites
/// can never drift apart. Only the actual cancel call differs: a live Api
/// call on the calendar, an injected one on the screen (and in its tests).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../domain/models.dart';
import '../clubhouse/widgets/message_composers.dart' show showPlayerComposer;

/// What the player picked in the dialog; null = „Zpět“ or dismissed.
enum _Choice { cancel, messageAdmins, messageDuty }

/// Asks „Zrušit rezervaci?“ for [reservation] in [block], then runs the
/// choice: [cancel] the reservation, or open the player composer with the
/// training as context — „Napsat správci…“ always, „Napsat službě…“ only
/// while [dutyServesToday] (see `dutyReachableToday`). [ref] opens the
/// composer.
Future<void> confirmCancelOwnReservation(
  BuildContext context, {
  required WidgetRef ref,
  required Reservation reservation,
  required TimeBlock block,
  required Future<void> Function(String id) cancel,
  required bool dutyServesToday,
}) async {
  final choice = await showDialog<_Choice>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Zrušit rezervaci?'),
      content: Text(
        '${dayFull(reservation.date)} · ${block.label} · '
        'Dráha ${reservation.lane}',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Zpět'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, _Choice.messageAdmins),
          child: const Text('Napsat správci…'),
        ),
        if (dutyServesToday)
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, _Choice.messageDuty),
            child: const Text('Napsat službě…'),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, _Choice.cancel),
          child: const Text('Zrušit rezervaci'),
        ),
      ],
    ),
  );
  if (choice == null || !context.mounted) return;
  switch (choice) {
    case _Choice.cancel:
      await tryAction(
        context,
        () => cancel(reservation.id),
        success: 'Rezervace zrušena.',
        errorText: friendlyDbError,
      );
    case _Choice.messageAdmins:
      await showPlayerComposer(
        context,
        ref,
        date: reservation.date,
        block: block,
        preselect: MessageAudience.admins,
      );
    case _Choice.messageDuty:
      await showPlayerComposer(
        context,
        ref,
        date: reservation.date,
        block: block,
        preselect: MessageAudience.duty,
      );
  }
}

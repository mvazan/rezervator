/// Confirm-then-cancel for a player's OWN future reservation: the exact
/// dialog and copy the calendar (`ScheduleActions._cancel`'s `ownFuture`
/// branch) and „Můj přehled" both need — pulled out so the two call sites
/// can never drift apart. Only the actual cancel call differs: a live Api
/// call on the calendar, an injected one on the screen (and in its tests).
library;

import 'package:flutter/material.dart';

import '../../core/ui.dart';
import '../../domain/models.dart';

Future<void> confirmCancelOwnReservation(
  BuildContext context, {
  required Reservation reservation,
  required TimeBlock block,
  required Future<void> Function(String id) cancel,
}) async {
  final ok = await confirmDialog(
    context,
    title: 'Zrušit rezervaci?',
    message:
        '${dayFull(reservation.date)} · ${block.label} · Dráha ${reservation.lane}',
    confirmLabel: 'Zrušit rezervaci',
    cancelLabel: 'Zpět',
  );
  if (!ok || !context.mounted) return;
  await tryAction(
    context,
    () => cancel(reservation.id),
    success: 'Rezervace zrušena.',
    errorText: friendlyDbError,
  );
}

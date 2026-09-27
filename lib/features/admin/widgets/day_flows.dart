/// The whole-day edits the calendar offers the admin and the player on
/// canteen duty (0050): closing a day and returning it to the weekly rules.
/// Shared by [BlockDialog]'s day mode and the portrait day menu (⋮), so both
/// ask the same questions and make the same RPC calls.
library;

import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/day_edit.dart';
import '../../../domain/models.dart';

/// Confirms that [hit] reservations on [date] will be cancelled with [note]
/// — the note the write will actually carry. Nothing to cancel is a yes.
Future<bool> confirmDayCancellations(
  BuildContext context,
  int hit,
  Day date,
  String note,
) async {
  if (hit == 0) return true;
  if (!context.mounted) return false;
  return confirmDialog(
    context,
    title: 'Pozor — rezervace budou zrušeny',
    message:
        '$hit rezervací (${dayFull(date)}) bude zrušeno se '
        'zprávou „$note". Pokračovat?',
    confirmLabel: 'Pokračovat',
  );
}

/// The reservation picture a day write needs; null (after a snack saying
/// why) when it cannot be read — then nobody can promise what the write
/// would cancel, so the flow stops.
Future<List<StrandableReservation>?> _futureRows(
  BuildContext context,
  String Function(Object error) errorText,
) async {
  try {
    return await Api.futureLiveReservations(today());
  } catch (e) {
    if (context.mounted) snack(context, errorText(e));
    return null;
  }
}

/// Closes [date]: „Důvod zavření“, then the count of that day's live
/// reservations the closure cancels (the reason is their note), then
/// `set_day_override(closed)`. True once the day is closed; false when
/// the user backed out or the write failed (the snack said why).
Future<bool> closeDayFlow(
  BuildContext context, {
  required Day date,
  String Function(Object error) errorText = friendlyDbError,
}) async {
  final reason = await promptText(
    context,
    title: 'Důvod zavření',
    message: '${dayFull(date)} — rezervace v tento den se zruší.',
    confirmLabel: 'Zavřít den',
  );
  if (reason == null || !context.mounted) return false;
  final rows = await _futureRows(context, errorText);
  if (rows == null || !context.mounted) return false;
  final ok = await confirmDayCancellations(
    context,
    strandedOnDate(rows, date, const {}),
    date,
    dayCancelNote(reason),
  );
  if (!ok || !context.mounted) return false;
  return tryAction(
    context,
    () => Api.setDayOverride(date: date, closed: true, reason: reason),
    success: 'Den zavřen.',
    errorText: errorText,
  );
}

/// Drops the day's fork and returns [date] to the weekly rules. A training
/// day goes back to the template blocks (reservations on day-only specials
/// cancel via the RPC); a NON-training day closes again — every
/// reservation that date cancels, and the closed write lands FIRST so a
/// failure between the two calls can't leave the day wide open. True once
/// done.
Future<bool> restoreDayFlow(
  BuildContext context, {
  required Day date,
  required bool isTraining,
  required List<TimeBlock> blocks,
  String Function(Object error) errorText = friendlyDbError,
}) async {
  final rows = await _futureRows(context, errorText);
  if (rows == null || !context.mounted) return false;
  final plan = planRestoreTemplate(
    date: date,
    isTraining: isTraining,
    blocks: blocks,
    rows: rows,
  );
  final ok = await confirmDayCancellations(
    context,
    plan.cancellations,
    date,
    scheduleChangeNote,
  );
  if (!ok || !context.mounted) return false;
  return tryAction(
    context,
    () => Api.restoreDayToTemplate(
      date,
      isTraining: isTraining,
      templateIds: plan.templateIds,
    ),
    success: 'Den vrácen k týdennímu rozvrhu.',
    errorText: errorText,
  );
}

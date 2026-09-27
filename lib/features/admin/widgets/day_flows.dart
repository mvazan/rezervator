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
/// would cancel, so the flow stops. With [dutyNow] (the player on duty on
/// today, 0050) the rows on [date] whose block has started are left out:
/// the server spares them, so the count must too.
Future<List<StrandableReservation>?> _futureRows(
  BuildContext context,
  String Function(Object error) errorText, {
  required Day date,
  required HourMinute? dutyNow,
  required List<TimeBlock> blocks,
}) async {
  try {
    final rows = await Api.futureLiveReservations(today());
    return dutyNow == null
        ? rows
        : withoutStarted(rows, date: date, now: dutyNow, blocks: blocks);
  } catch (e) {
    if (context.mounted) snack(context, errorText(e));
    return null;
  }
}

/// Closes [date]: „Důvod zavření“, then the count of that day's live
/// reservations the closure cancels (the reason is their note), then
/// `set_day_override(closed)`. True once the day is closed; false when
/// the user backed out or the write failed (the snack said why).
///
/// [dutyNow]: the player on duty closing TODAY (0050) — the current time;
/// trainings already under way stay, so they are not counted ([blocks]
/// tells their start). Null for the admin and any other day.
Future<bool> closeDayFlow(
  BuildContext context, {
  required Day date,
  String Function(Object error) errorText = friendlyDbError,
  List<TimeBlock> blocks = const [],
  HourMinute? dutyNow,
}) async {
  final reason = await promptText(
    context,
    title: 'Důvod zavření',
    message: '${dayFull(date)} — rezervace v tento den se zruší.',
    confirmLabel: 'Zavřít den',
  );
  if (reason == null || !context.mounted) return false;
  final rows = await _futureRows(context, errorText,
      date: date, dutyNow: dutyNow, blocks: blocks);
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
/// done. [dutyNow] as in [closeDayFlow].
Future<bool> restoreDayFlow(
  BuildContext context, {
  required Day date,
  required bool isTraining,
  required List<TimeBlock> blocks,
  String Function(Object error) errorText = friendlyDbError,
  HourMinute? dutyNow,
}) async {
  final rows = await _futureRows(context, errorText,
      date: date, dutyNow: dutyNow, blocks: blocks);
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

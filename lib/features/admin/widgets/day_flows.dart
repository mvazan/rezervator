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
import 'block_dialog.dart' show blockStartedMessage;

/// Confirms that [hit] reservations on [date] will be cancelled with [note]
/// — the note the write will actually carry. Nothing to cancel is a yes.
/// [startedStay]: the duty's today closes and trainings under way stay —
/// the message says so (0050).
Future<bool> confirmDayCancellations(
  BuildContext context,
  int hit,
  Day date,
  String note, {
  bool startedStay = false,
}) async {
  if (hit == 0) return true;
  if (!context.mounted) return false;
  return confirmDialog(
    context,
    title: 'Pozor — rezervace budou zrušeny',
    message:
        '$hit rezervací (${dayFull(date)}) bude zrušeno se '
        'zprávou „$note"${startedStay ? _startedStayClause : ''}. '
        'Pokračovat?',
    confirmLabel: 'Pokračovat',
  );
}

/// The reservation picture a day write needs; null (after a snack saying
/// why) when it cannot be read — then nobody can promise what the write
/// would cancel, so the flow stops. With [dutyClock] (the player on duty on
/// today, 0050) the rows on [date] whose block has started by now — read
/// here, right before the count — are left out: the server spares them, so
/// the count must too.
Future<List<StrandableReservation>?> _futureRows(
  BuildContext context,
  String Function(Object error) errorText, {
  required Day date,
  required HourMinute Function()? dutyClock,
  required List<TimeBlock> blocks,
}) async {
  try {
    final rows = await Api.futureLiveReservations(today());
    final dutyNow = dutyClock?.call();
    return dutyNow == null
        ? rows
        : withoutStarted(rows, date: date, now: dutyNow, blocks: blocks);
  } catch (e) {
    if (context.mounted) snack(context, errorText(e));
    return null;
  }
}

/// What the duty's close prompts add when a training of today is under way
/// (0050: the server keeps it).
const _startedStayClause = ' (tréninky, které už začaly, zůstanou)';

/// The duty's today: whether a block [date] shows ([renderedIds]; null =
/// any of [blocks]) starts by [dutyClock] or within the next minute
/// ([clockAtWrite] — the write follows the prompt). Always false for the
/// admin and any other day ([dutyClock] null).
bool _someStarted(
  List<TimeBlock> blocks,
  Set<String>? renderedIds,
  HourMinute Function()? dutyClock,
) {
  final now = dutyClock?.call();
  if (now == null) return false;
  final by = clockAtWrite(now);
  return blocks.any((b) =>
      (renderedIds == null || renderedIds.contains(b.id)) &&
      b.startsAt.compareTo(by) <= 0);
}

/// Closes [date]: „Důvod zavření“, then the count of that day's live
/// reservations the closure cancels (the reason is their note), then
/// `set_day_override(closed)`. True once the day is closed; false when
/// the user backed out or the write failed (the snack said why).
///
/// [dutyClock]: the player on duty closing TODAY (0050) — reads the current
/// time; trainings already under way stay, so they are not counted
/// ([blocks] tells their start). Null for the admin and any other day.
/// [renderedIds]: the blocks the day shows — the prompt says trainings
/// under way stay only when one of them has started (null = any block).
Future<bool> closeDayFlow(
  BuildContext context, {
  required Day date,
  String Function(Object error) errorText = friendlyDbError,
  List<TimeBlock> blocks = const [],
  Set<String>? renderedIds,
  HourMinute Function()? dutyClock,
}) async {
  // The duty's today: the server keeps the trainings already under way.
  final stay = _someStarted(blocks, renderedIds, dutyClock);
  final reason = await promptText(
    context,
    title: 'Důvod zavření',
    message: '${dayFull(date)} — rezervace v tento den se zruší'
        '${stay ? _startedStayClause : ''}.',
    confirmLabel: 'Zavřít den',
  );
  if (reason == null || !context.mounted) return false;
  final rows = await _futureRows(context, errorText,
      date: date, dutyClock: dutyClock, blocks: blocks);
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
/// done. [dutyClock] as in [closeDayFlow]; [renderedIds]: the blocks the
/// day shows (null = any of [blocks]).
///
/// The duty's today (0050): a training day's restore may not drop a block
/// the day shows that has started — the server would spare its trainings
/// on a block the calendar no longer shows — so it is refused before any
/// request and again right before the write. A closing day keeps them
/// like „Zavřít den“, and the count says so.
Future<bool> restoreDayFlow(
  BuildContext context, {
  required Day date,
  required bool isTraining,
  required List<TimeBlock> blocks,
  Set<String>? renderedIds,
  String Function(Object error) errorText = friendlyDbError,
  HourMinute Function()? dutyClock,
}) async {
  // The blocks the day shows beyond the weekly ones — the restore drops
  // them (a closing day drops everything, but the server keeps what has
  // started, as when closing).
  final templateIds = templateBlockIds(blocks).toSet();
  final dropped = [
    if (isTraining)
      for (final b in blocks)
        if (!templateIds.contains(b.id) &&
            (renderedIds == null || renderedIds.contains(b.id)))
          b,
  ];
  bool refuseStarted({required bool atWrite}) {
    final now = dutyClock?.call();
    if (now == null) return false;
    final by = atWrite ? clockAtWrite(now) : now;
    if (!dropped.any((b) => b.startsAt.compareTo(by) <= 0)) return false;
    if (context.mounted) snack(context, blockStartedMessage);
    return true;
  }

  if (refuseStarted(atWrite: false)) return false;
  final rows = await _futureRows(context, errorText,
      date: date, dutyClock: dutyClock, blocks: blocks);
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
    startedStay: !isTraining && _someStarted(blocks, renderedIds, dutyClock),
  );
  if (!ok || !context.mounted) return false;
  // The confirm took time: the clock is asked again right before the write.
  if (refuseStarted(atWrite: true)) return false;
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

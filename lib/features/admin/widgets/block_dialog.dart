import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/day_edit.dart';
import '../../../domain/models.dart';
import 'day_flows.dart';
import 'move_reservations_dialog.dart';
import 'notify_choice_dialog.dart';

/// What the player on duty is told about a block of today that has
/// already started (0050): the server keeps it — and its trainings — the
/// admin's.
const blockStartedMessage = 'Blok už začal — upravit ho může jen správce.';

/// What the player on duty is told when a day edit of today would hide a
/// block that has already started — not the block being edited (0050: a
/// started block stays the admin's).
const hideStartedMessage =
    'Nový čas by skryl blok, který už začal — to může jen správce.';

/// What the player on duty is told when a day edit of today would start a
/// block at a time that has already passed (0050: the server refuses it).
const startPassedMessage = 'Začátek už dnes minul — vyber pozdější čas.';

/// How a refusal of a DAY edit (a block, not a reservation) reads. For the
/// player on duty a `too_late` means a block of today has started meanwhile
/// — the plain copy would talk about cancelling a reservation.
String dayEditError(Object error, {required bool wasOnDuty}) =>
    wasOnDuty && '$error'.contains('too_late')
        ? blockStartedMessage
        : friendlyDbError(error, wasOnDuty: wasOnDuty);

/// If deactivating [blockId] would cancel future live reservations (the
/// server cascades them with 'změna rozvrhu', 0018), asks the admin first.
/// Returns true when it's safe to proceed (nothing stranded, or the admin
/// confirmed anyway); false when the admin declined.
Future<bool> confirmIfBlockStrands(BuildContext context, String blockId) async {
  final stranded =
      strandedOnBlock(await Api.futureLiveReservations(today()), blockId);
  if (stranded == 0) return true;
  if (!context.mounted) return false;
  return confirmDialog(
    context,
    title: 'Pozor — rezervace se zruší',
    message:
        '$stranded budoucích rezervací na tomto bloku se tímto zruší (hráči dostanou upozornění). Opravdu deaktivovat?',
    confirmLabel: 'Uložit i tak',
  );
}

/// Add/edit dialog for a time block: two time pickers for start/end.
/// [initialStart]/[initialEnd] prefill a NEW block (e.g. from a schedule
/// gap); an [existing] block also gets a destructive action.
///
/// Two modes:
/// - GLOBAL (default, [dayContext] null): edits the weekly template — the
///   change applies to every training day. Used by the admin Rozvrh screen.
/// - DAY-SCOPED ([dayContext] set): the change applies ONLY to that day.
///   Saving finds-or-creates an inactive "special" block with the picked
///   times and points the day's override at it (replacing the edited block
///   in [dayBaseIds], or appending for a new one); the weekly template stays
///   untouched. That day's reservations on a replaced/removed block are
///   cancelled by the set_day_override RPC ('změna rozvrhu'). Used by the
///   calendar's long-press/tap-gap gestures.
///
/// All rules live in `domain/day_edit.dart` (planBlockEdit /
/// planBlockRemoval / planRestoreTemplate); this widget fetches the
/// reservation picture, sequences the confirm dialogs the plan calls for
/// and issues the RPC calls it prescribes.
class BlockDialog extends StatefulWidget {
  const BlockDialog({
    super.key,
    required this.existing,
    required this.blocks,
    this.initialStart,
    this.initialEnd,
    this.dayContext,
    this.dayBaseIds,
    this.dayRenderedIds,
    this.dayHasOverride = false,
    this.dayIsTraining = true,
    this.dayPriority = const <PrioritySlot>[],
    this.dayReason = '',
    this.noAccountIds = const <String>{},
    this.offerCloseDay = false,
    this.wasOnDuty = false,
    this.dutyClock,
  });

  final TimeBlock? existing;

  /// ALL blocks (active + special) — overlap warning in global mode and the
  /// find-or-create pool for specials in day mode.
  final List<TimeBlock> blocks;
  final HourMinute? initialStart;
  final HourMinute? initialEnd;

  /// Day-scoped mode: the date the edit applies to.
  final Day? dayContext;

  /// Hand-made "hráči bez účtu" (0022): a move never offers to message
  /// them, and when only they move the notify choice is skipped.
  final Set<String> noAccountIds;

  /// Day-scoped mode: the day's PRE-cancellation block ids (existing
  /// override selection, or the active weekly template) — the base the new
  /// override is composed from, so a block hidden by a priority slot isn't
  /// permanently lost.
  final List<String>? dayBaseIds;

  /// Day-scoped mode: ids of the blocks the day currently RENDERS. Hiding
  /// a block nobody can see (a match already cancelled it) needs no
  /// warning — unless it still holds live reservations. Null = warn for
  /// everything (conservative default).
  final Set<String>? dayRenderedIds;

  /// Day-scoped mode: whether the day already has an override row — shows
  /// the "Obnovit týdenní rozvrh" escape hatch.
  final bool dayHasOverride;

  /// Day-scoped mode: whether the WEEKDAY rule opens this day. Returning a
  /// non-training day to the template means CLOSING it again (all its
  /// reservations cancel), not opening it with the weekly blocks.
  final bool dayIsTraining;

  /// Day-scoped mode: the day's priority slots — a removal's move targets
  /// must actually render after the removal (not sit under a match).
  final List<PrioritySlot> dayPriority;

  /// Day-scoped mode: the day's existing override reason, preserved on save.
  final String dayReason;

  /// Day-scoped mode, a NEW block from the header ＋ on an open day: also
  /// offer „Zavřít den“ (0050 — the admin and the player on duty).
  final bool offerCloseDay;

  /// Opened by the player on canteen duty (0050): a `not_allowed` refusal
  /// then means the duty has just ended, and says so.
  final bool wasOnDuty;

  /// Day-scoped mode, the player on duty editing TODAY (0050): reads the
  /// current time. A block starting at or before it has started — the
  /// server refuses to move one there and spares its reservations — so the
  /// save refuses such a start, the counts leave those rows out and no move
  /// targets them. Read afresh for every check: right before the first
  /// write it is asked again, and a block that started while the dialog
  /// was open writes nothing. Null (the admin, any other day) = no limit.
  final HourMinute Function()? dutyClock;

  @override
  State<BlockDialog> createState() => _BlockDialogState();
}

class _BlockDialogState extends State<BlockDialog> {
  HourMinute? _start;
  HourMinute? _end;
  bool _saving = false;

  bool get _dayMode => widget.dayContext != null;

  DayEditContext get _day => DayEditContext(
        date: widget.dayContext!,
        baseIds: widget.dayBaseIds!,
        renderedIds: widget.dayRenderedIds,
        isTraining: widget.dayIsTraining,
        reason: widget.dayReason,
        priority: widget.dayPriority,
      );

  @override
  void initState() {
    super.initState();
    // Explicit prefill wins over the existing block's times (callers only
    // pass both when they mean it — e.g. tests driving a changed edit).
    _start = widget.initialStart ?? widget.existing?.startsAt;
    _end = widget.initialEnd ?? widget.existing?.endsAt;
  }

  Future<void> _pickStart() async {
    final picked = await pickTime(context, initial: _start);
    if (picked != null) setState(() => _start = picked);
  }

  Future<void> _pickEnd() async {
    final picked = await pickTime(context, initial: _end);
    if (picked != null) setState(() => _end = picked);
  }

  void _bail() {
    if (mounted) setState(() => _saving = false);
  }

  /// The reservation picture every day-scoped plan needs. Fail-safe: without
  /// it we can't promise what a write would cancel — abort rather than
  /// guess (the snackbar explains, the caller bails).
  Future<List<StrandableReservation>?> _loadRows() async {
    try {
      final rows = await Api.futureLiveReservations(today());
      final now = widget.dutyClock?.call();
      return now == null
          ? rows
          : withoutStarted(rows,
              date: widget.dayContext!, now: now, blocks: widget.blocks);
    } catch (e) {
      if (mounted) snack(context, _errorText(e));
      return null;
    }
  }

  /// The duty's clock, one minute ahead when [atWrite] (see [clockAtWrite]);
  /// null = no limit.
  HourMinute? _dutyNow({required bool atWrite}) {
    final now = widget.dutyClock?.call();
    return now == null || !atWrite ? now : clockAtWrite(now);
  }

  /// The duty's today: whether [block] has started by now — then the snack
  /// says it stays the admin's and the caller writes nothing. [atWrite]:
  /// asked right before a write, with the one-minute margin.
  /// [message]: what the snack says (the hidden-block copy for a block
  /// the edit would hide).
  bool _refuseStarted(
    TimeBlock block, {
    bool atWrite = false,
    String message = blockStartedMessage,
  }) {
    final now = _dutyNow(atWrite: atWrite);
    if (now == null || block.startsAt.compareTo(now) > 0) return false;
    if (mounted) snack(context, message);
    return true;
  }

  /// The duty's today, asked before any write of [plan]: a start that has
  /// passed would be refused — only after the hidden blocks' sign-ups were
  /// cancelled and the special inserted. Neither the edited block nor a
  /// block the day shows that the new times would hide may have started:
  /// a started block stays the admin's, its trainings live on it. True
  /// (after a snack saying why) = write nothing. [atWrite] as in
  /// [_refuseStarted].
  bool _refuseForDuty(DayEditDay plan, {bool atWrite = false}) {
    final now = _dutyNow(atWrite: atWrite);
    if (now == null) return false;
    if (plan.start.compareTo(now) <= 0) {
      if (mounted) snack(context, startPassedMessage);
      return true;
    }
    final existing = plan.existing;
    if (existing != null && _refuseStarted(existing, atWrite: atWrite)) {
      return true;
    }
    final rendered = widget.dayRenderedIds;
    return plan.hidden.any((b) =>
        (rendered == null || rendered.contains(b.id)) &&
        _refuseStarted(b, atWrite: atWrite, message: hideStartedMessage));
  }

  /// How a refusal reads — „Služba skončila…“ for a duty that just ended,
  /// the block copy for a duty's `too_late` (see [dayEditError]).
  String _errorText(Object error) =>
      dayEditError(error, wasOnDuty: widget.wasOnDuty);

  /// Confirms the RPC's exact cancellation count for [date]; quotes the
  /// [note] the write will actually carry.
  Future<bool> _confirmCancellations(int hit, Day date, String note) async {
    if (hit == 0) return true;
    if (!mounted) return false;
    return confirmDayCancellations(context, hit, date, note);
  }

  /// Day-scoped removal: the block disappears from [widget.dayContext] only.
  /// When it still has sign-ups and blocks that render after the removal
  /// exist, the move dialog lets the admin drag each reservation to a new
  /// home first; anything left unmoved is cancelled (confirmed inside).
  Future<void> _removeForDay() async {
    final existing = widget.existing!;
    final date = widget.dayContext!;
    if (_refuseStarted(existing)) return;
    setState(() => _saving = true);
    final rows = await _loadRows();
    if (rows == null || !mounted) {
      _bail();
      return;
    }
    final plan = planBlockRemoval(
        existing: existing,
        day: _day,
        blocks: widget.blocks,
        rows: rows,
        startedBy: widget.dutyClock?.call());
    if (plan.offersMove) {
      // The dialog's moves are the first write.
      if (_refuseStarted(existing, atWrite: true)) {
        _bail();
        return;
      }
      final moved = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => MoveReservationsDialog(
          date: date,
          fromBlock: existing,
          targets: plan.targets,
          cancelNote: plan.cancelNote,
          errorText: _errorText,
        ),
      );
      if (moved != true || !mounted) {
        _bail();
        return;
      }
    }
    // After a move the dialog covered the removed block's sign-ups; stranded
    // rows on OTHER non-kept blocks still deserve the standard sweep confirm.
    final ok = await _confirmCancellations(
        strandedOnDate(rows, date, plan.sweepKeptIds), date, plan.cancelNote);
    if (!ok || !mounted || _refuseStarted(existing, atWrite: true)) {
      _bail();
      return;
    }
    final done = await tryAction(
      context,
      () => Api.setDayOverride(
        date: date,
        closed: false,
        reason: widget.dayReason,
        blockIds: plan.idsAfter,
      ),
      success: 'Blok odebrán (jen tento den).',
      errorText: _errorText,
    );
    if (!mounted) return;
    if (done) {
      closeDialog(context);
    } else {
      setState(() => _saving = false);
    }
  }

  /// One-tap escape hatch: drop the day's fork and return to the weekly
  /// rules. A training day goes back to the template blocks (reservations
  /// on day-only specials cancel via the RPC); a NON-training day closes
  /// again — every reservation that date cancels, and the closed write
  /// lands FIRST so a failure between the two calls can't leave the day
  /// wide open.
  Future<void> _restoreTemplate() async {
    setState(() => _saving = true);
    final done = await restoreDayFlow(
      context,
      date: widget.dayContext!,
      isTraining: widget.dayIsTraining,
      blocks: widget.blocks,
      errorText: _errorText,
      dutyClock: widget.dutyClock,
    );
    if (!mounted) return;
    if (done) {
      closeDialog(context);
    } else {
      setState(() => _saving = false);
    }
  }

  /// „Zavřít den“ (0050): the reason, the count confirm, the closed write.
  Future<void> _closeDay() async {
    setState(() => _saving = true);
    final done = await closeDayFlow(
      context,
      date: widget.dayContext!,
      errorText: _errorText,
      blocks: widget.blocks,
      renderedIds: widget.dayRenderedIds,
      dutyClock: widget.dutyClock,
    );
    if (!mounted) return;
    if (done) {
      closeDialog(context);
    } else {
      setState(() => _saving = false);
    }
  }

  Future<void> _deactivateGlobal() async {
    final existing = widget.existing!;
    final ok = await confirmIfBlockStrands(context, existing.id);
    if (!ok || !mounted) return;
    final done = await tryAction(
      context,
      () => Api.updateTimeBlock(existing.id, active: false),
      success: 'Blok deaktivován.',
      errorText: _errorText,
    );
    if (done && mounted) closeDialog(context);
  }

  Future<void> _save() async {
    final start = _start;
    final end = _end;
    if (start == null || end == null) {
      snack(context, 'Vyber začátek i konec.');
      return;
    }
    if (end.compareTo(start) <= 0) {
      snack(context, 'Konec musí být po začátku.');
      return;
    }
    final existing = widget.existing;
    if (!_dayMode) {
      await _saveGlobal(start, end, existing);
      return;
    }
    // The no-op verdict needs no reservation picture — decide it before any
    // I/O so an unchanged save closes without a single request.
    final dry = planBlockEdit(
        start: start,
        end: end,
        existing: existing,
        blocks: widget.blocks,
        day: _day,
        rows: const []);
    if (dry is DayEditNoOp) {
      closeDialog(context);
      return;
    }
    // The duty's today: refused before any request (see _refuseForDuty).
    if (_refuseForDuty(dry as DayEditDay)) return;
    setState(() => _saving = true);
    // Everything below awaits — the flag above keeps both action buttons
    // disabled for the whole flight (confirms included).
    final rows = await _loadRows();
    if (rows == null || !mounted) {
      _bail();
      return;
    }
    final plan = planBlockEdit(
        start: start,
        end: end,
        existing: existing,
        blocks: widget.blocks,
        day: _day,
        rows: rows) as DayEditDay;
    final notifiable = existing == null
        ? 0
        : rows
            .where((r) =>
                r.date == _day.date &&
                r.blockId == existing.id &&
                !widget.noAccountIds.contains(r.playerId))
            .length;
    await _saveDay(plan, notifiableRows: notifiable);
  }

  /// Global mode: a weekly block overlapping another would silently stack
  /// on every training day.
  Future<void> _saveGlobal(
      HourMinute start, HourMinute end, TimeBlock? existing) async {
    final plan = planBlockEdit(
        start: start,
        end: end,
        existing: existing,
        blocks: widget.blocks,
        rows: const []) as DayEditGlobal;
    if (plan.overlapping.isNotEmpty) {
      final proceed = await confirmDialog(
        context,
        title: 'Pozor — překryv bloků',
        message: 'Blok se překrývá s '
            '${plan.overlapping.map((b) => b.label).join(', ')}. Bloky platí '
            'pro každý tréninkový den — pro jednorázovou změnu použij '
            'kalendář (podržení bloku v daném dni). Opravdu uložit?',
        confirmLabel: 'Uložit i tak',
      );
      if (!proceed || !mounted) return;
    }
    setState(() => _saving = true);
    final ok = await tryAction(
      context,
      () => existing == null
          ? Api.addTimeBlock(start, end, nextBlockPosition(widget.blocks))
          : Api.updateTimeBlock(existing.id, startsAt: start, endsAt: end),
      success: 'Uloženo.',
      errorText: _errorText,
    );
    if (!mounted) return;
    if (ok) {
      closeDialog(context);
    } else {
      setState(() => _saving = false);
    }
  }

  /// Day mode: the confirms in the plan's order, then the writes it
  /// prescribes.
  /// [notifiableRows]: how many of the moving sign-ups have an inbox.
  Future<void> _saveDay(DayEditDay plan, {required int notifiableRows}) async {
    final date = plan.date;
    final existing = plan.existing;

    // Overlapping ANOTHER day-special: specials don't hide each other, so
    // this is a real visual/booking overlap.
    if (plan.specialOverlaps.isNotEmpty) {
      final proceed = await confirmDialog(
        context,
        title: 'Pozor — překryv bloků',
        message: 'Blok se překrývá s jinou jednodenní změnou '
            '(${plan.specialOverlaps.map((b) => b.label).join(', ')}) — budou se '
            'zobrazovat přes sebe. Opravdu uložit?',
        confirmLabel: 'Uložit i tak',
      );
      if (!proceed || !mounted) {
        _bail();
        return;
      }
    }

    // Template blocks the new times touch are HIDDEN for this day (they
    // reappear when the edit shrinks or goes away) — and their live
    // sign-ups for the day CANCEL, or they'd survive invisibly and
    // double-book the physical lanes. Only blocks the admin can SEE (or
    // that still hold rows) are worth a dialog.
    if (plan.noteworthy.isNotEmpty) {
      final proceed = await confirmDialog(
        context,
        title: 'Blok bude skryt',
        message: 'Upravený blok v tomto dni skryje '
            '${plan.noteworthy.map((b) => b.label).join(', ')}. Zobrazí se zase, '
            'když úpravu zrušíš nebo zkrátíš.'
            '${plan.hiddenRows > 0 ? ' ${plan.hiddenRows} rezervací na skrytých blocích bude zrušeno.' : ''}'
            ' Pokračovat?',
        confirmLabel: 'Pokračovat',
      );
      if (!proceed || !mounted) {
        _bail();
        return;
      }
    }

    // Dissolving into a twin that still holds live rows (legacy forks,
    // pre-cancel-on-hide): sweep them first or the 1:1 move collides.
    if (plan.twinNeedsSweep) {
      final proceed = await confirmDialog(
        context,
        title: 'Pozor — rezervace budou zrušeny',
        message: 'Na původním bloku zůstalo ${plan.twinRows} rezervací — budou '
            'zrušeny, aby se přihlášení z upraveného bloku mohli '
            'přesunout. Pokračovat?',
        confirmLabel: 'Pokračovat',
      );
      if (!proceed || !mounted) {
        _bail();
        return;
      }
    }

    // The RPC's exact cancellation predicate: everything on the date
    // OUTSIDE the kept ids goes (the edited block's rows MOVE, never cancel).
    final ok = await _confirmCancellations(
        plan.cancellations, date, plan.cancelNote);
    if (!ok || !mounted) {
      _bail();
      return;
    }

    // Phase 3: the edited block's own sign-ups MOVE to the new times — the
    // admin chooses whether (and with what wording) to ping them.
    NotifyChoice? moveNotify;
    if (plan.movingRows > 0 && notifiableRows == 0) {
      // Only hráči bez účtu move — nobody to message.
      moveNotify = const NotifyChoice(notify: false);
    } else if (notifiableRows > 0) {
      moveNotify = await showNotifyChoiceDialog(
        context,
        title: 'Upozornit na přesun?',
        summary: notifiableRows == 1
            ? 'Hráč dostane zprávu o novém čase '
                '${plan.start.display()}–${plan.end.display()}.'
            : '$notifiableRows hráčů dostane zprávu o novém čase '
                '${plan.start.display()}–${plan.end.display()}.',
      );
      if (moveNotify == null || !mounted) {
        _bail();
        return;
      }
    }

    // The confirms took time: the duty's clock is asked again right before
    // the first write.
    if (_refuseForDuty(plan, atWrite: true)) {
      _bail();
      return;
    }

    final done = await tryAction(
      context,
      () async {
        final twin = plan.dissolveTwin;
        if (twin != null) {
          // Hand the day back to the template block: sweep the twin's
          // leftover rows first, move the special's sign-ups over (lanes
          // 1:1 — the twin's slots are free now), restore the twin's id in
          // the override, and unwind the row entirely when nothing
          // day-specific remains.
          if (plan.twinNeedsSweep) {
            await Api.cancelBlockDayReservations(date, twin.id);
          }
          await Api.moveDayReservations(date, existing!.id, twin.id,
              notify: moveNotify?.notify ?? true,
              message: moveNotify?.message);
          if (plan.unwindsOverride) {
            await Api.restoreDayToTemplate(date,
                isTraining: true, templateIds: plan.templateIds);
          } else {
            await Api.setDayOverride(
              date: date,
              closed: false,
              reason: widget.dayReason,
              blockIds: plan.dissolveIds,
            );
          }
          return;
        }
        // Cancel the hidden blocks' live sign-ups (confirmed above) BEFORE
        // the override write — no invisible live rows may survive a hide.
        for (final b in plan.hiddenToCancel) {
          await Api.cancelBlockDayReservations(date, b.id,
              note: plan.cancelNote);
        }
        // Find-or-create the special block, swap it into the day's override.
        final specialId = plan.reusableSpecial?.id ??
            await Api.addSpecialBlock(plan.start, plan.end);
        if (existing != null) {
          // The block's sign-ups travel with it to the new times (lanes
          // 1:1 — the fresh special has no rows).
          await Api.moveDayReservations(date, existing.id, specialId,
              notify: moveNotify?.notify ?? true,
              message: moveNotify?.message);
        }
        await Api.setDayOverride(
          date: date,
          closed: false,
          reason: widget.dayReason,
          blockIds: plan.idsAfter(specialId),
        );
      },
      success: 'Uloženo (jen tento den).',
      errorText: _errorText,
    );
    if (!mounted) return;
    if (done) {
      closeDialog(context);
    } else {
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dayLabelSuffix =
        _dayMode ? ' — jen ${dayLabel(widget.dayContext!)}' : '';
    return AlertDialog(
      title: Text(widget.existing == null
          ? 'Nový blok$dayLabelSuffix'
          : 'Upravit blok$dayLabelSuffix'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: const Text('Začátek'),
            trailing: Text(_start?.display() ?? '--:--'),
            onTap: _pickStart,
          ),
          ListTile(
            title: const Text('Konec'),
            trailing: Text(_end?.display() ?? '--:--'),
            onTap: _pickEnd,
          ),
        ],
      ),
      actions: [
        if (_dayMode && widget.existing == null && widget.offerCloseDay)
          TextButton(
            onPressed: _saving ? null : _closeDay,
            child: Text(
              'Zavřít den',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (_dayMode && widget.dayHasOverride)
          TextButton(
            onPressed: _saving ? null : _restoreTemplate,
            child: const Text('Obnovit týdenní rozvrh'),
          ),
        if (widget.existing != null && _dayMode)
          TextButton(
            onPressed: _saving ? null : _removeForDay,
            child: Text(
              'Odebrat v tento den',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          )
        else if (widget.existing != null && widget.existing!.active)
          TextButton(
            onPressed: _saving ? null : _deactivateGlobal,
            child: Text(
              'Deaktivovat',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Zrušit'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Ukládám…' : 'Uložit'),
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/day_edit.dart';
import '../../../domain/models.dart';
import 'move_reservations_dialog.dart';
import 'notify_choice_dialog.dart';

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
      return await Api.futureLiveReservations(today());
    } catch (e) {
      if (mounted) snack(context, friendlyDbError(e));
      return null;
    }
  }

  /// Confirms the RPC's exact cancellation count for [date]; quotes the
  /// [note] the write will actually carry.
  Future<bool> _confirmCancellations(int hit, Day date, String note) async {
    if (hit == 0) return true;
    if (!mounted) return false;
    return confirmDialog(
      context,
      title: 'Pozor — rezervace budou zrušeny',
      message: '$hit rezervací (${dayFull(date)}) bude zrušeno se '
          'zprávou „$note". Pokračovat?',
      confirmLabel: 'Pokračovat',
    );
  }

  /// Day-scoped removal: the block disappears from [widget.dayContext] only.
  /// When it still has sign-ups and blocks that render after the removal
  /// exist, the move dialog lets the admin drag each reservation to a new
  /// home first; anything left unmoved is cancelled (confirmed inside).
  Future<void> _removeForDay() async {
    final existing = widget.existing!;
    final date = widget.dayContext!;
    setState(() => _saving = true);
    final rows = await _loadRows();
    if (rows == null || !mounted) {
      _bail();
      return;
    }
    final plan = planBlockRemoval(
        existing: existing, day: _day, blocks: widget.blocks, rows: rows);
    if (plan.offersMove) {
      final moved = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => MoveReservationsDialog(
          date: date,
          fromBlock: existing,
          targets: plan.targets,
          cancelNote: plan.cancelNote,
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
    if (!ok || !mounted) {
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
      errorText: friendlyDbError,
    );
    if (!mounted) return;
    if (done) {
      Navigator.of(context).pop();
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
    final date = widget.dayContext!;
    setState(() => _saving = true);
    final rows = await _loadRows();
    if (rows == null || !mounted) {
      _bail();
      return;
    }
    final plan = planRestoreTemplate(
        date: date,
        isTraining: widget.dayIsTraining,
        blocks: widget.blocks,
        rows: rows);
    final ok =
        await _confirmCancellations(plan.cancellations, date, scheduleChangeNote);
    if (!ok || !mounted) {
      _bail();
      return;
    }
    final done = await tryAction(
      context,
      () => Api.restoreDayToTemplate(date,
          isTraining: widget.dayIsTraining, templateIds: plan.templateIds),
      success: 'Den vrácen k týdennímu rozvrhu.',
      errorText: friendlyDbError,
    );
    if (!mounted) return;
    if (done) {
      Navigator.of(context).pop();
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
      errorText: friendlyDbError,
    );
    if (done && mounted) Navigator.of(context).pop();
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
      Navigator.of(context).pop();
      return;
    }
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
      errorText: friendlyDbError,
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
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
      errorText: friendlyDbError,
    );
    if (!mounted) return;
    if (done) {
      Navigator.of(context).pop();
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

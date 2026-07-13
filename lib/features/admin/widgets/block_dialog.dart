import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/models.dart';
import '../../../domain/schedule.dart' show timesOverlap;
import 'move_reservations_dialog.dart';

/// If deactivating [blockId] would strand future live reservations
/// (invisible, uncancellable from the grid), asks the admin to confirm.
/// Returns true when it's safe to proceed (nothing stranded, or the admin
/// confirmed anyway); false when the admin declined.
Future<bool> confirmIfBlockStrands(BuildContext context, String blockId) async {
  final reservations = await Api.futureLiveReservations(today());
  final stranded = reservations.where((r) => r.blockId == blockId).length;
  if (stranded == 0) return true;
  if (!context.mounted) return false;
  return confirmDialog(
    context,
    title: 'Pozor — osiřelé rezervace',
    message:
        '$stranded budoucích rezervací na tomto bloku zůstane mimo rozvrh. Opravdu deaktivovat?',
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
class BlockDialog extends StatefulWidget {
  const BlockDialog({
    super.key,
    required this.existing,
    required this.blocks,
    this.initialStart,
    this.initialEnd,
    this.dayContext,
    this.dayBaseIds,
    this.dayHasOverride = false,
    this.dayReason = '',
  });

  final TimeBlock? existing;

  /// ALL blocks (active + special) — overlap warning in global mode and the
  /// find-or-create pool for specials in day mode.
  final List<TimeBlock> blocks;
  final HourMinute? initialStart;
  final HourMinute? initialEnd;

  /// Day-scoped mode: the date the edit applies to.
  final Day? dayContext;

  /// Day-scoped mode: the day's PRE-cancellation block ids (existing
  /// override selection, or the active weekly template) — the base the new
  /// override is composed from, so a block hidden by a priority slot isn't
  /// permanently lost.
  final List<String>? dayBaseIds;

  /// Day-scoped mode: whether the day already has an override row — shows
  /// the "Obnovit týdenní rozvrh" escape hatch.
  final bool dayHasOverride;

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

  int get _nextPosition => widget.blocks.isEmpty
      ? 0
      : widget.blocks.map((b) => b.position).reduce((a, b) => a > b ? a : b) +
          1;

  /// Day-scoped: the override RPC cancels EVERY live reservation on [date]
  /// whose block is NOT in the new id list — mirror exactly that predicate
  /// (not just the edited block: a stranded reservation on a long-
  /// deactivated block gets swept too) and confirm when any would go.
  Future<bool> _confirmDayCancellations(Day date, Set<String> keptIds) async {
    final reservations = await Api.futureLiveReservations(today());
    final hit = reservations
        .where((r) => r.date == date && !keptIds.contains(r.blockId))
        .length;
    if (hit == 0) return true;
    if (!mounted) return false;
    // The RPC uses the override reason as the cancel note when present.
    final note =
        widget.dayReason.trim().isEmpty ? 'změna rozvrhu' : widget.dayReason;
    return confirmDialog(
      context,
      title: 'Pozor — rezervace budou zrušeny',
      message: '$hit rezervací (${dayFull(date)}) bude zrušeno se '
          'zprávou „$note". Pokračovat?',
      confirmLabel: 'Pokračovat',
    );
  }

  /// Day-scoped removal: the block disappears from [widget.dayContext] only.
  /// When it still has sign-ups and the blocks it was covering resurface,
  /// the move dialog lets the admin drag each reservation to a new home
  /// first; anything left unmoved is cancelled (confirmed inside).
  Future<void> _removeForDay() async {
    final existing = widget.existing!;
    final date = widget.dayContext!;
    final ids = [
      for (final id in widget.dayBaseIds!)
        if (id != existing.id) id,
    ];
    setState(() => _saving = true);
    final reservations = await Api.futureLiveReservations(today());
    if (!mounted) return;
    final signUps = reservations
        .where((r) => r.date == date && r.blockId == existing.id)
        .length;
    final blockById = {for (final b in widget.blocks) b.id: b};
    final targets = [
      for (final id in ids)
        if (blockById[id] != null &&
            timesOverlap(existing.startsAt, existing.endsAt,
                blockById[id]!.startsAt, blockById[id]!.endsAt))
          blockById[id]!,
    ];
    if (signUps > 0 && targets.isNotEmpty) {
      final moved = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => MoveReservationsDialog(
          date: date,
          fromBlock: existing,
          targets: targets,
          cancelNote: widget.dayReason.trim().isEmpty
              ? 'změna rozvrhu'
              : widget.dayReason,
        ),
      );
      if (moved != true || !mounted) {
        if (mounted) setState(() => _saving = false);
        return;
      }
    } else {
      final ok = await _confirmDayCancellations(date, ids.toSet());
      if (!ok || !mounted) {
        if (mounted) setState(() => _saving = false);
        return;
      }
    }
    final done = await tryAction(
      context,
      () => Api.setDayOverride(
        date: date,
        closed: false,
        reason: widget.dayReason,
        blockIds: ids,
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
  /// template (reservations on day-only specials get cancelled by the RPC
  /// first; deleting the row afterwards restores full weekday rules —
  /// including closing a non-training day again).
  Future<void> _restoreTemplate() async {
    final date = widget.dayContext!;
    final templateIds = [
      for (final b in widget.blocks)
        if (b.active && b.position >= 0) b.id,
    ];
    setState(() => _saving = true);
    final ok = await _confirmDayCancellations(date, templateIds.toSet());
    if (!ok || !mounted) {
      if (mounted) setState(() => _saving = false);
      return;
    }
    final done = await tryAction(
      context,
      () async {
        await Api.setDayOverride(
            date: date, closed: false, reason: '', blockIds: templateIds);
        await Api.deleteDayOverride(date);
      },
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
    // Day-mode no-op: unchanged times on a block the day already uses must
    // not fork the day into an override (and cancel its reservations for a
    // pixel-identical schedule) — just close.
    if (_dayMode &&
        existing != null &&
        start == existing.startsAt &&
        end == existing.endsAt &&
        widget.dayBaseIds!.contains(existing.id)) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _saving = true);
    // Everything below awaits — the flag above keeps both action buttons
    // disabled for the whole flight (confirms included).
    void bail() {
      if (mounted) setState(() => _saving = false);
    }

    // Dissolve: editing a day-special so it EXACTLY copies an active
    // template block hands the day back to that block — its reservations
    // move over silently and the special vanishes from the override.
    TimeBlock? dissolveTwin;
    if (_dayMode && existing != null && existing.position < 0) {
      for (final b in widget.blocks) {
        if (b.active &&
            b.position >= 0 &&
            b.startsAt == start &&
            b.endsAt == end) {
          dissolveTwin = b;
          break;
        }
      }
    }

    if (_dayMode) {
      // The day-scoped block beats the weekly template like a priority
      // slot: template blocks the new times touch are HIDDEN for this day
      // (and reappear as soon as the edit shrinks or goes away) — say so.
      // Irrelevant when dissolving: the result IS a template block.
      final blockById = {for (final b in widget.blocks) b.id: b};
      final hidden = [
        if (dissolveTwin == null)
          for (final id in widget.dayBaseIds!)
            if (id != existing?.id &&
                blockById[id] != null &&
                blockById[id]!.position >= 0 &&
                timesOverlap(
                    start, end, blockById[id]!.startsAt, blockById[id]!.endsAt))
              blockById[id]!,
      ];
      if (hidden.isNotEmpty) {
        final proceed = await confirmDialog(
          context,
          title: 'Blok bude skryt',
          message: 'Upravený blok v tomto dni skryje '
              '${hidden.map((b) => b.label).join(', ')}. Zobrazí se zase, '
              'když úpravu zrušíš nebo zkrátíš. Pokračovat?',
          confirmLabel: 'Pokračovat',
        );
        if (!proceed || !mounted) {
          bail();
          return;
        }
      }

      // Confirm using the RPC's exact cancellation predicate: everything on
      // the date OUTSIDE the kept ids goes (the new special has no
      // reservations, so it needn't be in the set). Runs for the add path
      // too — adding a block still sweeps stranded reservations. When
      // dissolving, the edited special's reservations MOVE (not cancel), so
      // it counts as kept.
      final keptIds = {
        for (final id in widget.dayBaseIds!)
          if (id != existing?.id || dissolveTwin != null) id,
        if (dissolveTwin != null) dissolveTwin.id,
      };
      final ok = await _confirmDayCancellations(widget.dayContext!, keptIds);
      if (!ok || !mounted) {
        bail();
        return;
      }
    } else {
      // Global mode: a weekly block overlapping another would silently
      // stack on every training day.
      final overlapping = [
        for (final b in widget.blocks)
          if (b.active &&
              b.id != existing?.id &&
              timesOverlap(start, end, b.startsAt, b.endsAt))
            b,
      ];
      if (overlapping.isNotEmpty) {
        final proceed = await confirmDialog(
          context,
          title: 'Pozor — překryv bloků',
          message: 'Blok se překrývá s '
              '${overlapping.map((b) => b.label).join(', ')}. Bloky platí '
              'pro každý tréninkový den — pro jednorázovou změnu použij '
              'kalendář (podržení bloku v daném dni). Opravdu uložit?',
          confirmLabel: 'Uložit i tak',
        );
        if (!proceed || !mounted) {
          bail();
          return;
        }
      }
    }

    final ok = await tryAction(
      context,
      () async {
        if (!_dayMode) {
          if (existing == null) {
            await Api.addTimeBlock(start, end, _nextPosition);
          } else {
            await Api.updateTimeBlock(existing.id, startsAt: start, endsAt: end);
          }
          return;
        }
        if (dissolveTwin != null) {
          // Hand the day back to the template block: move the special's
          // sign-ups over (lanes 1:1 — the twin was hidden, so its slots
          // are free), restore the twin's id in the override, and drop the
          // override row entirely when nothing day-specific remains.
          await Api.moveDayReservations(
              widget.dayContext!, existing!.id, dissolveTwin.id);
          final seen = <String>{};
          final ids = [
            for (final id in widget.dayBaseIds!)
              if (seen.add(id == existing.id ? dissolveTwin.id : id))
                id == existing.id ? dissolveTwin.id : id,
          ];
          final templateIds = {
            for (final b in widget.blocks)
              if (b.active && b.position >= 0) b.id,
          };
          if (setEquals(ids.toSet(), templateIds)) {
            await Api.setDayOverride(
                date: widget.dayContext!,
                closed: false,
                reason: '',
                blockIds: templateIds.toList());
            await Api.deleteDayOverride(widget.dayContext!);
          } else {
            await Api.setDayOverride(
              date: widget.dayContext!,
              closed: false,
              reason: widget.dayReason,
              blockIds: ids,
            );
          }
          return;
        }
        // Day-scoped: find-or-create the special block, swap it into the
        // day's override. The reuse pool is ONLY sentinel specials
        // (position < 0) — a deactivated template block sharing the times
        // must never get re-coupled to a day override.
        TimeBlock? special;
        for (final b in widget.blocks) {
          if (!b.active &&
              b.position < 0 &&
              b.startsAt == start &&
              b.endsAt == end) {
            special = b;
            break;
          }
        }
        final specialId =
            special?.id ?? await Api.addSpecialBlock(start, end);
        final base = widget.dayBaseIds!;
        final ids = existing == null
            ? [...base, specialId]
            : [for (final id in base) id == existing.id ? specialId : id];
        await Api.setDayOverride(
          date: widget.dayContext!,
          closed: false,
          reason: widget.dayReason,
          blockIds: ids,
        );
      },
      success: _dayMode ? 'Uloženo (jen tento den).' : 'Uloženo.',
      errorText: friendlyDbError,
    );
    if (!mounted) return;
    if (ok) {
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

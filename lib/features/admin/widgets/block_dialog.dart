import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/models.dart';
import '../../../domain/schedule.dart' show timesOverlap;

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
    this.dayRenderedBlocks,
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

  /// Day-scoped mode: the day's RENDERED blocks — what the overlap warning
  /// checks against (a block cancelled by a match isn't a visible conflict).
  final List<TimeBlock>? dayRenderedBlocks;

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
    _start = widget.existing?.startsAt ?? widget.initialStart;
    _end = widget.existing?.endsAt ?? widget.initialEnd;
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

  /// Day-scoped: reservations on [blockId] on exactly [date] get cancelled
  /// by the override RPC — confirm when any exist.
  Future<bool> _confirmDayCancellations(Day date, String blockId) async {
    final reservations = await Api.futureLiveReservations(today());
    final hit = reservations
        .where((r) => r.date == date && r.blockId == blockId)
        .length;
    if (hit == 0) return true;
    if (!mounted) return false;
    return confirmDialog(
      context,
      title: 'Pozor — rezervace budou zrušeny',
      message:
          '$hit rezervací na tomto bloku (${dayFull(date)}) bude zrušeno se '
          'zprávou „změna rozvrhu". Pokračovat?',
      confirmLabel: 'Pokračovat',
    );
  }

  /// Day-scoped removal: the block disappears from [widget.dayContext] only.
  Future<void> _removeForDay() async {
    final existing = widget.existing!;
    final date = widget.dayContext!;
    final ok = await _confirmDayCancellations(date, existing.id);
    if (!ok || !mounted) return;
    final ids = [
      for (final id in widget.dayBaseIds!)
        if (id != existing.id) id,
    ];
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
    if (done && mounted) Navigator.of(context).pop();
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
    // Overlap warning: in day mode against the day's rendered blocks (a
    // block cancelled by a match isn't a visible conflict); in global mode
    // against every active weekly block — that one would silently overlap
    // on every other training day.
    final warnPool = _dayMode
        ? widget.dayRenderedBlocks!
        : [
            for (final b in widget.blocks)
              if (b.active) b,
          ];
    final overlapping = [
      for (final b in warnPool)
        if (b.id != widget.existing?.id &&
            timesOverlap(start, end, b.startsAt, b.endsAt))
          b,
    ];
    if (overlapping.isNotEmpty) {
      final proceed = await confirmDialog(
        context,
        title: 'Pozor — překryv bloků',
        message: _dayMode
            ? 'Blok se v tomto dni překrývá s '
                '${overlapping.map((b) => b.label).join(', ')}. Opravdu uložit?'
            : 'Blok se překrývá s '
                '${overlapping.map((b) => b.label).join(', ')}. Bloky platí '
                'pro každý tréninkový den — pro jednorázovou změnu použij '
                'kalendář (podržení bloku v daném dni). Opravdu uložit?',
        confirmLabel: 'Uložit i tak',
      );
      if (!proceed || !mounted) return;
    }

    if (_dayMode && widget.existing != null) {
      final ok =
          await _confirmDayCancellations(widget.dayContext!, widget.existing!.id);
      if (!ok || !mounted) return;
    }

    setState(() => _saving = true);
    final existing = widget.existing;
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
        // Day-scoped: find-or-create the special block, swap it into the
        // day's override.
        TimeBlock? special;
        for (final b in widget.blocks) {
          if (!b.active && b.startsAt == start && b.endsAt == end) {
            special = b;
            break;
          }
        }
        final specialId = special?.id ??
            await Api.addSpecialBlock(
                start, end, existing?.position ?? _nextPosition);
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

import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/models.dart';
import '../../../domain/schedule.dart' show upcomingSeriesDates;
import 'form_dialog.dart';
import 'form_fields.dart';

/// Confirm → delete → snack for an exception row. The message warns that
/// the series re-applies for that date, so the server cancels whatever
/// was booked meanwhile on the lanes the exception had freed.
Future<bool> confirmDeleteRentalException(
  BuildContext context, {
  required Rental parent,
  required Rental child,
}) =>
    confirmDelete(
      context,
      title: 'Zrušit výjimku?',
      message: '${dayFull(child.date!)} · ${parent.renterName}: den se vrátí '
          'k pravidelnému pronájmu. Rezervace, které mezitím vznikly na '
          'uvolněných drahách, budou zrušeny.',
      action: () => Api.deleteRental(child.id),
      success: 'Výjimka zrušena.',
    );

/// "Jen tento den": one occurrence of a weekly rental with other lanes or
/// times, or skipped altogether. [date] is known when opened from the
/// calendar; the Pronájmy screen leaves it null and the dialog offers the
/// series' upcoming dates (minus [takenDates], which already have an
/// exception). [existing] is the exception row being edited. Pops `true`
/// after any change (save, skip, removal).
class RentalOccurrenceDialog extends StatefulWidget {
  const RentalOccurrenceDialog({
    super.key,
    required this.parent,
    this.date,
    this.existing,
    this.takenDates = const {},
    required this.laneCount,
  });

  /// The weekly series.
  final Rental parent;
  final Day? date;
  final Rental? existing;
  final Set<Day> takenDates;
  final int laneCount;

  @override
  State<RentalOccurrenceDialog> createState() =>
      _RentalOccurrenceDialogState();
}

class _RentalOccurrenceDialogState extends State<RentalOccurrenceDialog> {
  final _note = TextEditingController();
  HourMinute? _start;
  HourMinute? _end;
  Set<int> _lanes = {};
  Day? _pickedDate;

  /// A leading action (skip / remove) is running: FormDialog only tracks
  /// its own Uložit, so the extra buttons keep their busy state here.
  bool _busy = false;

  Day? get _date => widget.date ?? widget.existing?.date ?? _pickedDate;

  @override
  void initState() {
    super.initState();
    final source = widget.existing ?? widget.parent;
    _note.text = source.note;
    _start = source.startsAt;
    _end = source.endsAt;
    _lanes = {...source.lanes};
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickStart() async {
    final picked = await pickTime(context, initial: _start);
    if (picked != null) setState(() => _start = picked);
  }

  Future<void> _pickEnd() async {
    final picked = await pickTime(context, initial: _end);
    if (picked != null) setState(() => _end = picked);
  }

  List<int> get _parentLanes => [...widget.parent.lanes]..sort();

  bool _sameAsSeries(List<int> lanes, HourMinute start, HourMinute end) {
    final parent = widget.parent;
    final parentLanes = _parentLanes;
    if (lanes.length != parentLanes.length) return false;
    for (var i = 0; i < lanes.length; i++) {
      if (lanes[i] != parentLanes[i]) return false;
    }
    return start == parent.startsAt &&
        end == parent.endsAt &&
        _note.text.trim() == parent.note;
  }

  /// Any lane outside the series', or a longer window: the server will
  /// cancel colliding reservations, and the snack should say so.
  bool _enlarges(List<int> lanes, HourMinute start, HourMinute end) {
    final parent = widget.parent;
    return lanes.any((l) => !parent.lanes.contains(l)) ||
        start.compareTo(parent.startsAt) < 0 ||
        end.compareTo(parent.endsAt) > 0;
  }

  /// Validates and saves; null keeps the dialog open (the snack said why).
  Future<bool?> _save() async {
    final start = _start;
    final end = _end;
    if (start == null || end == null) {
      snack(context, 'Vyber začátek i konec.');
      return null;
    }
    if (end.compareTo(start) <= 0) {
      snack(context, 'Konec musí být po začátku.');
      return null;
    }
    if (_lanes.isEmpty) {
      snack(context, 'Vyber aspoň jednu dráhu.');
      return null;
    }
    final date = _date;
    if (date == null) {
      snack(context, 'Vyber datum.');
      return null;
    }
    final lanes = _lanes.toList()..sort();
    if (_sameAsSeries(lanes, start, end)) {
      snack(context, 'Shoduje se s pravidelným pronájmem.');
      return null;
    }
    final enlarges = _enlarges(lanes, start, end);
    final ok = await tryAction(
      context,
      () => Api.saveRentalException(
        id: widget.existing?.id,
        parent: widget.parent,
        date: date,
        skipped: false,
        lanes: lanes,
        startsAt: start,
        endsAt: end,
        note: _note.text.trim(),
      ),
      success: enlarges
          ? 'Výjimka uložena. Kolidující rezervace byly zrušeny.'
          : 'Výjimka uložena.',
      errorText: friendlyDbError,
    );
    return ok ? true : null;
  }

  /// The occurrence does not happen: the row keeps the series' lanes and
  /// times so un-skipping (a plain save) starts from them.
  Future<void> _skip() async {
    final date = _date;
    if (date == null) {
      snack(context, 'Vyber datum.');
      return;
    }
    final parent = widget.parent;
    setState(() => _busy = true);
    final ok = await tryAction(
      context,
      () => Api.saveRentalException(
        id: widget.existing?.id,
        parent: parent,
        date: date,
        skipped: true,
        lanes: parent.lanes,
        startsAt: parent.startsAt,
        endsAt: parent.endsAt,
        note: _note.text.trim(),
      ),
      success: 'Pronájem v tento den vynechán.',
      errorText: friendlyDbError,
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    final existing = widget.existing;
    if (existing == null) return;
    setState(() => _busy = true);
    final ok = await confirmDeleteRentalException(
      context,
      parent: widget.parent,
      child: existing,
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final parent = widget.parent;
    final existing = widget.existing;
    final date = _date;
    final scheme = Theme.of(context).colorScheme;
    // Only a brand-new exception picks its date; an edit keeps its row's.
    final needsDate = widget.date == null && existing == null;
    final dates = needsDate
        ? upcomingSeriesDates(parent, from: today())
            .where((d) => !widget.takenDates.contains(d))
            .toList()
        : const <Day>[];

    return FormDialog<bool>(
      title: 'Výjimka pronájmu',
      onSave: _save,
      saveEnabled: !_busy,
      leadingActions: [
        if (existing != null)
          TextButton(
            onPressed: _busy ? null : _remove,
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            child: const Text('Zrušit výjimku'),
          ),
        if (existing?.skipped != true)
          TextButton(
            onPressed: _busy ? null : _skip,
            child: const Text('Vynechat tento den'),
          ),
      ],
      children: [
        Text(
          date != null
              ? '${parent.renterName} · jen ${dayFull(date)}'
              : '${parent.renterName} · každý '
                  '${weekdayFull(parent.weekday!)} '
                  '${parent.startsAt.display()}–${parent.endsAt.display()}',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        if (existing?.skipped == true) ...[
          const SizedBox(height: 4),
          const Text('Tento den je vynechán.'),
        ],
        const SizedBox(height: 8),
        if (needsDate)
          if (dates.isEmpty)
            const Text('Pravidelný pronájem už nemá další termíny.')
          else
            DropdownButtonFormField<Day>(
              initialValue: null,
              decoration: const InputDecoration(labelText: 'Datum'),
              items: [
                for (final d in dates)
                  DropdownMenuItem(value: d, child: Text(dayFull(d))),
              ],
              onChanged: (d) => setState(() => _pickedDate = d),
            ),
        PickerTile(
          label: 'Začátek',
          value: _start?.display() ?? '--:--',
          onTap: _pickStart,
        ),
        PickerTile(
          label: 'Konec',
          value: _end?.display() ?? '--:--',
          onTap: _pickEnd,
        ),
        const SizedBox(height: 8),
        LaneChips(
          laneCount: widget.laneCount,
          selected: _lanes,
          onChanged: (lanes) => setState(() => _lanes = lanes),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _note,
          decoration: const InputDecoration(labelText: 'Poznámka'),
        ),
      ],
    );
  }
}

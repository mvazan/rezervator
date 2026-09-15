import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/models.dart';
import 'form_dialog.dart';
import 'form_fields.dart';

/// One date of a nepravidelný pronájem: date (calendar), times, lanes,
/// note. [existing] edits that row; otherwise the date is added next to
/// [anchor] — the row the list was opened from — whose lanes and times
/// pre-fill the form (the date never is: a wrong guess left in place
/// would book the wrong day). Pops `true` after a save.
class RentalDateDialog extends StatefulWidget {
  const RentalDateDialog({
    super.key,
    required this.anchor,
    this.existing,
    required this.laneCount,
  });

  /// A date of the same rental — supplies id (for rental_add_date), name,
  /// colour and the pre-fill.
  final Rental anchor;
  final Rental? existing;
  final int laneCount;

  @override
  State<RentalDateDialog> createState() => _RentalDateDialogState();
}

class _RentalDateDialogState extends State<RentalDateDialog> {
  final _note = TextEditingController();
  Day? _date;
  HourMinute? _start;
  HourMinute? _end;
  Set<int> _lanes = {};

  @override
  void initState() {
    super.initState();
    final source = widget.existing ?? widget.anchor;
    _date = widget.existing?.date;
    _start = source.startsAt;
    _end = source.endsAt;
    _lanes = source.lanes.toSet();
    _note.text = widget.existing?.note ?? '';
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final earliest = today().addDays(-365);
    final picked = await pickDay(
      context,
      initial: _date ?? widget.anchor.date,
      first: earliest,
      last: earliest.addDays(365 * 3),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _pickStart() async {
    final t = await pickTime(context, initial: _start);
    if (t != null) setState(() => _start = t);
  }

  Future<void> _pickEnd() async {
    final t = await pickTime(context, initial: _end);
    if (t != null) setState(() => _end = t);
  }

  Future<bool?> _save() async {
    final date = _date;
    if (date == null) {
      snack(context, 'Vyber datum.');
      return null;
    }
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
    final lanes = _lanes.toList()..sort();
    final note = _note.text.trim();
    final existing = widget.existing;
    final ok = await tryAction(
      context,
      () => existing == null
          ? Api.addRentalDate(
              rentalId: widget.anchor.id,
              date: date,
              startsAt: start,
              endsAt: end,
              lanes: lanes,
              note: note,
            )
          : Api.saveRentalDate(
              id: existing.id,
              renterName: widget.anchor.renterName,
              color: widget.anchor.color,
              date: date,
              lanes: lanes,
              startsAt: start,
              endsAt: end,
              note: note,
            ),
      success: 'Termín uložen. Kolidující rezervace byly zrušeny.',
      errorText: friendlyDbError,
    );
    return ok ? true : null;
  }

  @override
  Widget build(BuildContext context) {
    return FormDialog<bool>(
      title: widget.existing == null ? 'Přidat termín' : 'Upravit termín',
      onSave: _save,
      children: [
        PickerTile(
          label: 'Datum',
          value: _date == null ? 'Vybrat' : dayFull(_date!),
          onTap: _pickDate,
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

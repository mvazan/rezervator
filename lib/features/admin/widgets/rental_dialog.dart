import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/models.dart';
import 'color_picker.dart';
import 'form_dialog.dart';
import 'form_fields.dart';

enum _RentalMode { oneTime, weekly }

/// Add/edit dialog for a lane rental. The mode radio (Jednorázový /
/// Týdenní) structurally guarantees date XOR weekday: only the field for
/// the active mode is ever read when saving, so the other is always sent
/// as null.
class RentalDialog extends StatefulWidget {
  const RentalDialog({super.key, this.existing, required this.laneCount});

  final Rental? existing;
  final int laneCount;

  @override
  State<RentalDialog> createState() => _RentalDialogState();
}

class _RentalDialogState extends State<RentalDialog> {
  final _renterName = TextEditingController();
  final _note = TextEditingController();
  _RentalMode _mode = _RentalMode.oneTime;
  Day? _date;
  int _weekday = DateTime.monday;
  Day? _validFrom;
  Day? _validUntil;
  HourMinute? _start;
  HourMinute? _end;
  Set<int> _lanes = {};
  int _color = -2;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _renterName.text = existing?.renterName ?? '';
    _note.text = existing?.note ?? '';
    _start = existing?.startsAt;
    _end = existing?.endsAt;
    _lanes.addAll(existing?.lanes ?? const []);
    _color = existing?.color ?? -2;
    if (existing == null) {
      _mode = _RentalMode.oneTime;
    } else if (existing.date != null) {
      _mode = _RentalMode.oneTime;
      _date = existing.date;
    } else {
      _mode = _RentalMode.weekly;
      _weekday = existing.weekday!;
      _validFrom = existing.validFrom;
      _validUntil = existing.validUntil;
    }
  }

  @override
  void dispose() {
    _renterName.dispose();
    _note.dispose();
    super.dispose();
  }

  /// Two years from [firstDate] — rentals are planned far ahead.
  Future<void> _pickDate({
    required Day? initial,
    required Day firstDate,
    required void Function(Day) onPicked,
  }) async {
    final picked = await pickDay(
      context,
      initial: initial,
      first: firstDate,
      last: firstDate.addDays(365 * 2),
    );
    if (picked != null) onPicked(picked);
  }

  Future<void> _pickStart() async {
    final picked = await pickTime(context, initial: _start);
    if (picked != null) setState(() => _start = picked);
  }

  Future<void> _pickEnd() async {
    final picked = await pickTime(context, initial: _end);
    if (picked != null) setState(() => _end = picked);
  }

  /// Validates and saves; null keeps the dialog open (the snack said why).
  Future<bool?> _save() async {
    final renterName = _renterName.text.trim();
    if (renterName.isEmpty) {
      snack(context, 'Vyplň nájemce.');
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
    if (_mode == _RentalMode.oneTime && _date == null) {
      snack(context, 'Vyber datum.');
      return null;
    }
    if (_lanes.isEmpty) {
      snack(context, 'Vyber aspoň jednu dráhu.');
      return null;
    }
    final validFrom = _mode == _RentalMode.weekly ? _validFrom : null;
    final validUntil = _mode == _RentalMode.weekly ? _validUntil : null;
    if (validFrom != null &&
        validUntil != null &&
        validUntil.isBefore(validFrom)) {
      snack(context, '„Platí od" musí být před „Platí do".');
      return null;
    }

    final lanes = _lanes.toList()..sort();
    final ok = await tryAction(
      context,
      () => Api.saveRental(
        id: widget.existing?.id,
        renterName: renterName,
        lanes: lanes,
        date: _mode == _RentalMode.oneTime ? _date : null,
        weekday: _mode == _RentalMode.weekly ? _weekday : null,
        startsAt: start,
        endsAt: end,
        validFrom: validFrom,
        validUntil: validUntil,
        note: _note.text.trim(),
        color: _color,
      ),
      success: 'Pronájem uložen. Kolidující rezervace byly zrušeny.',
      errorText: friendlyDbError,
    );
    return ok ? true : null;
  }

  @override
  Widget build(BuildContext context) {
    final now = today();
    // Matches/rentals allow retro entries (unlike overrides, which are
    // future-only).
    final earliestDate = now.addDays(-365);

    return FormDialog<bool>(
      title: widget.existing == null ? 'Přidat pronájem' : 'Upravit pronájem',
      onSave: _save,
      children: [
        TextField(
          controller: _renterName,
          decoration: const InputDecoration(labelText: 'Nájemce'),
        ),
        const SizedBox(height: 8),
        RadioGroup<_RentalMode>(
          groupValue: _mode,
          onChanged: (v) => setState(() => _mode = v!),
          child: const Column(
            children: [
              RadioListTile<_RentalMode>(
                contentPadding: EdgeInsets.zero,
                title: Text('Jednorázový'),
                value: _RentalMode.oneTime,
              ),
              RadioListTile<_RentalMode>(
                contentPadding: EdgeInsets.zero,
                title: Text('Týdenní'),
                value: _RentalMode.weekly,
              ),
            ],
          ),
        ),
        if (_mode == _RentalMode.oneTime)
          PickerTile(
            label: 'Datum',
            value: _date == null ? 'Vybrat' : dayFull(_date!),
            onTap: () => _pickDate(
              initial: _date,
              firstDate: earliestDate,
              onPicked: (d) => setState(() => _date = d),
            ),
          )
        else ...[
          DropdownButtonFormField<int>(
            initialValue: _weekday,
            decoration: const InputDecoration(labelText: 'Den v týdnu'),
            items: [
              for (var w = DateTime.monday; w <= DateTime.sunday; w++)
                DropdownMenuItem(value: w, child: Text(weekdayFull(w))),
            ],
            onChanged: (v) => setState(() => _weekday = v!),
          ),
          PickerTile(
            label: 'Platí od',
            value: _validFrom == null ? 'Nenastaveno' : dayFull(_validFrom!),
            onTap: () => _pickDate(
              initial: _validFrom,
              firstDate: earliestDate,
              onPicked: (d) => setState(() => _validFrom = d),
            ),
          ),
          PickerTile(
            label: 'Platí do',
            value:
                _validUntil == null ? 'Nenastaveno' : dayFull(_validUntil!),
            onTap: () => _pickDate(
              initial: _validUntil,
              firstDate: _validFrom ?? earliestDate,
              onPicked: (d) => setState(() => _validUntil = d),
            ),
          ),
        ],
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
        const SizedBox(height: 16),
        Text('Barva', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        ColorPickerGrid(
          selected: _color,
          noneValue: -2,
          noneLabel: 'Výchozí',
          onChanged: (index) => setState(() => _color = index),
        ),
      ],
    );
  }
}

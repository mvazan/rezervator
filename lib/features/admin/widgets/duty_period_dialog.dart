/// „Přidat službu“ and „Upravit termín…“ in Správa → Služby (0050): one
/// duty's days and note. The server checks the rest (`invalid_range`,
/// `duty_too_long`, `duty_overlap`) and the dialog stays open with the
/// message.
library;

import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../domain/models.dart';
import 'duty_parts.dart';
import 'form_dialog.dart';
import 'form_fields.dart';

/// Pops true once saved.
class DutyPeriodDialog extends StatefulWidget {
  const DutyPeriodDialog({
    super.key,
    this.existing,
    required this.startsOn,
    required this.endsOn,
    required this.today,
    required this.save,
  });

  /// The period to edit; null adds one.
  final DutyPeriod? existing;

  /// The days the fields start with.
  final Day startsOn;
  final Day endsOn;
  final Day today;

  final Future<String> Function({
    String? id,
    required Day startsOn,
    required Day endsOn,
    String note,
  })
  save;

  @override
  State<DutyPeriodDialog> createState() => _DutyPeriodDialogState();
}

class _DutyPeriodDialogState extends State<DutyPeriodDialog> {
  late Day _startsOn = widget.startsOn;
  late Day _endsOn = widget.endsOn;
  late final _note = TextEditingController(text: widget.existing?.note ?? '');

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<Day?> _pick(Day initial) => pickDay(
    context,
    initial: initial,
    first: widget.today.addDays(-3 * 366),
    last: widget.today.addDays(1200),
  );

  Future<bool?> _save() async {
    final ok = await tryAction(
      context,
      () => widget.save(
        id: widget.existing?.id,
        startsOn: _startsOn,
        endsOn: _endsOn,
        note: _note.text.trim(),
      ),
      errorText: friendlyDbError,
    );
    return ok ? true : null;
  }

  @override
  Widget build(BuildContext context) {
    return FormDialog<bool>(
      title: widget.existing == null ? 'Přidat službu' : 'Upravit termín',
      onSave: _save,
      children: [
        PickerTile(
          label: 'Od',
          value: dutyPickerDate(_startsOn),
          onTap: () async {
            final picked = await _pick(_startsOn);
            if (picked == null) return;
            setState(() {
              // Moving the start keeps the length, as a date range would.
              final length = _endsOn.differenceInDays(_startsOn);
              _startsOn = picked;
              _endsOn = picked.addDays(length < 0 ? 0 : length);
            });
          },
        ),
        PickerTile(
          label: 'Do',
          value: dutyPickerDate(_endsOn),
          onTap: () async {
            final picked = await _pick(_endsOn);
            if (picked != null) setState(() => _endsOn = picked);
          },
        ),
        TextField(
          controller: _note,
          maxLength: 80,
          decoration: const InputDecoration(
            labelText: 'Poznámka',
            counterText: '',
          ),
        ),
      ],
    );
  }
}

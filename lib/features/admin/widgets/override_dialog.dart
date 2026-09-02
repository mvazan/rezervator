import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/limits.dart';
import '../../../domain/models.dart';
import 'form_dialog.dart';
import 'form_fields.dart';

/// Add/edit-closure dialog: date (optionally a range) + reason. Picking a
/// date that already has a closure in [overrides] prefills its reason and
/// edits it in place ([Api.setDayOverride] upserts by date).
class OverrideDialog extends StatefulWidget {
  const OverrideDialog({super.key, required this.overrides});

  /// The current day overrides, as the screen has them.
  final List<DayOverride> overrides;

  @override
  State<OverrideDialog> createState() => _OverrideDialogState();
}

class _OverrideDialogState extends State<OverrideDialog> {
  Day? _date;
  Day? _dateTo;
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  /// Closures are future-only: today up to a year ahead.
  Future<void> _pickDate() async {
    final now = today();
    final date = await pickDay(
      context,
      initial: _date,
      first: now,
      last: now.addDays(365),
    );
    if (date == null) return;
    final existing = widget.overrides
        .where((o) => o.date == date && o.closed)
        .firstOrNull;
    setState(() {
      _date = date;
      if (_dateTo != null && _dateTo!.isBefore(date)) _dateTo = null;
      _reason.text = existing?.reason ?? '';
    });
  }

  Future<void> _pickDateTo() async {
    final from = _date ?? today();
    final picked = await pickDay(
      context,
      initial: _dateTo ?? from,
      first: from,
      last: from.addDays(365),
    );
    if (picked != null) setState(() => _dateTo = picked);
  }

  /// Validates and saves; null keeps the dialog open (the snack said why).
  Future<bool?> _save() async {
    final date = _date;
    if (date == null) {
      snack(context, 'Vyber datum.');
      return null;
    }
    if (_reason.text.trim().isEmpty) {
      snack(context, 'Vyplň důvod.');
      return null;
    }
    final to = _dateTo ?? date;
    final span = to.differenceInDays(date);
    if (span < 0) {
      snack(context, '„Do" musí být po datu začátku.');
      return null;
    }
    if (span > Limits.closureSpanDays) {
      snack(context, 'Nejvýše 3 měsíce najednou.');
      return null;
    }

    final ok = await tryAction(
      context,
      () async {
        // One override row per day — the list groups consecutive runs back
        // into a single range tile.
        for (var i = 0; i <= span; i++) {
          await Api.setDayOverride(
            date: date.addDays(i),
            closed: true,
            reason: _reason.text.trim(),
            blockIds: null,
          );
        }
      },
      success: 'Výjimka uložena. Kolidující rezervace byly zrušeny.',
      errorText: friendlyDbError,
    );
    return ok ? true : null;
  }

  @override
  Widget build(BuildContext context) {
    return FormDialog<bool>(
      title: 'Přidat výjimku',
      onSave: _save,
      children: [
        PickerTile(
          label: 'Datum',
          value: _date == null ? 'Vybrat' : dayFull(_date!),
          onTap: _pickDate,
        ),
        // The optional range end carries a hint while unset and a clear
        // button once set — more than PickerTile's label/value pair.
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Do (volitelně)'),
          subtitle: _dateTo == null
              ? const Text('Nevyplněno = jen jeden den',
                  style: TextStyle(fontSize: 12))
              : null,
          trailing: _dateTo == null
              ? const Text('Vybrat')
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(dayFull(_dateTo!)),
                    IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () => setState(() => _dateTo = null),
                    ),
                  ],
                ),
          onTap: _pickDateTo,
        ),
        TextField(
          controller: _reason,
          decoration: const InputDecoration(
            labelText: 'Důvod (zavřeno)',
            hintText: 'Malování drah',
          ),
        ),
      ],
    );
  }
}

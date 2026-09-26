/// „Nová sezóna…“ in Správa → Služby (0050): a season boundary. The counts
/// start again from it; nothing moves, so „Vrátit poslední sezónu“ undoes
/// it whole.
library;

import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../domain/duties.dart';
import '../../../domain/models.dart';
import 'duty_parts.dart';
import 'form_dialog.dart';
import 'form_fields.dart';

/// Pops true once the season started.
class DutySeasonDialog extends StatefulWidget {
  const DutySeasonDialog({
    super.key,
    required this.periods,
    required this.seasons,
    required this.today,
    required this.start,
  });

  /// For the note about a duty that runs across the new boundary.
  final List<DutyPeriod> periods;

  /// The boundaries so far: the new one must come after the newest
  /// (`season_order`).
  final List<DutySeason> seasons;
  final Day today;
  final Future<void> Function(Day startedOn, String name) start;

  @override
  State<DutySeasonDialog> createState() => _DutySeasonDialogState();
}

class _DutySeasonDialogState extends State<DutySeasonDialog> {
  late final _name = TextEditingController(text: seasonNameFor(widget.today));
  late Day _from = _earliest.isAfter(widget.today) ? _earliest : widget.today;

  /// The first day `season_order` allows: the day after the newest
  /// boundary, or any day without one.
  Day get _earliest {
    Day? newest;
    for (final s in widget.seasons) {
      if (newest == null || s.startedOn.isAfter(newest)) newest = s.startedOn;
    }
    return newest?.addDays(1) ?? widget.today.addDays(-3 * 366);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<bool?> _save() async {
    final ok = await tryAction(
      context,
      () => widget.start(_from, _name.text.trim()),
      errorText: friendlyDbError,
    );
    return ok ? true : null;
  }

  @override
  Widget build(BuildContext context) {
    // A duty running across the boundary counts where it began.
    final straddling = periodOn(widget.periods, _from);
    return FormDialog<bool>(
      title: 'Nová sezóna',
      saveLabel: 'Začít sezónu',
      onSave: _save,
      children: [
        TextField(
          controller: _name,
          maxLength: 40,
          decoration: const InputDecoration(
            labelText: 'Název',
            counterText: '',
          ),
        ),
        PickerTile(
          label: 'Od',
          value: dutyPickerDate(_from),
          onTap: () async {
            final picked = await pickDay(
              context,
              initial: _from,
              first: _earliest,
              last: widget.today.addDays(800),
            );
            if (picked != null) setState(() => _from = picked);
          },
        ),
        const SizedBox(height: 8),
        const Text(
          'Počty služeb začnou od nuly. Naplánované služby zůstanou a '
          'pokračují stejně. Historie se dá zobrazit.',
        ),
        if (straddling != null && straddling.startsOn.isBefore(_from)) ...[
          const SizedBox(height: 8),
          Text(
            'Služba ${dutyRangeLabel(straddling)} začala dřív, a tak se '
            'počítá ještě do předchozí sezóny.',
          ),
        ],
      ],
    );
  }
}

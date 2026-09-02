import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/block_generator.dart';
import '../../../domain/day_edit.dart';
import '../../../domain/models.dart';
import 'form_dialog.dart';
import 'form_fields.dart';

const _pastMidnight = 'Série přesahuje půlnoc — zkrať ji.';

String _conflictText(List<String> conflicts) =>
    'Koliduje s existujícími bloky: ${conflicts.join(', ')}';

/// "Vygenerovat bloky": start + délka + pauza + počet with a live preview of
/// the resulting series; saving appends the blocks (positions continue after
/// the current maximum). A series reaching midnight or overlapping existing
/// ACTIVE blocks is refused on save with the message the preview shows.
class GeneratorDialog extends StatefulWidget {
  const GeneratorDialog({super.key, required this.blocks});

  final List<TimeBlock> blocks;

  @override
  State<GeneratorDialog> createState() => _GeneratorDialogState();
}

class _GeneratorDialogState extends State<GeneratorDialog> {
  HourMinute? _start;
  int _duration = 60;
  int _pause = 0;
  int _count = 4;

  List<(HourMinute, HourMinute)>? get _times => _start == null
      ? null
      : generateBlockTimes(
          start: _start!,
          durationMinutes: _duration,
          pauseMinutes: _pause,
          count: _count,
        );

  List<String> get _conflicts =>
      _times == null ? const [] : generatorConflicts(_times!, widget.blocks);

  Future<void> _pickStart() async {
    final picked = await pickTime(context, initial: _start);
    if (picked != null) setState(() => _start = picked);
  }

  Future<bool?> _save() async {
    final times = _times;
    if (times == null) {
      snack(context, _start == null ? 'Vyber začátek.' : _pastMidnight);
      return null;
    }
    final conflicts = _conflicts;
    if (conflicts.isNotEmpty) {
      snack(context, _conflictText(conflicts));
      return null;
    }
    var position = nextBlockPosition(widget.blocks);
    final ok = await tryAction(
      context,
      () async {
        for (final (start, end) in times) {
          await Api.addTimeBlock(start, end, position++);
        }
      },
      success: 'Vytvořeno ${times.length} bloků.',
      errorText: friendlyDbError,
    );
    return ok ? true : null;
  }

  @override
  Widget build(BuildContext context) {
    final times = _times;
    final conflicts = _conflicts;
    final scheme = Theme.of(context).colorScheme;

    return FormDialog<bool>(
      title: 'Vygenerovat bloky',
      saveLabel: 'Vytvořit',
      onSave: _save,
      children: [
        PickerTile(
          label: 'Začátek',
          value: _start?.display() ?? '--:--',
          onTap: _pickStart,
        ),
        _StepperRow(
          label: 'Délka (min)',
          value: _duration,
          onChanged: (v) => setState(() => _duration = v),
          min: 15,
          max: 240,
          step: 15,
        ),
        _StepperRow(
          label: 'Pauza (min)',
          value: _pause,
          onChanged: (v) => setState(() => _pause = v),
          min: 0,
          max: 60,
          step: 5,
        ),
        _StepperRow(
          label: 'Počet bloků',
          value: _count,
          onChanged: (v) => setState(() => _count = v),
          min: 1,
          max: 12,
        ),
        const SizedBox(height: 12),
        if (_start != null && times == null)
          Text(_pastMidnight, style: TextStyle(color: scheme.error))
        else if (times != null) ...[
          Text(
            [
              for (final (s, e) in times) '${s.display()}–${e.display()}',
            ].join(', '),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (conflicts.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _conflictText(conflicts),
                style: TextStyle(color: scheme.error),
              ),
            ),
        ],
      ],
    );
  }
}

/// "Label  −  value  +" row; the buttons disable at [min]/[max].
class _StepperRow extends StatelessWidget {
  const _StepperRow({
    required this.label,
    required this.value,
    required this.onChanged,
    required this.min,
    required this.max,
    this.step = 1,
  });

  final String label;
  final int value;
  final ValueChanged<int> onChanged;
  final int min;
  final int max;
  final int step;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        IconButton(
          icon: const Icon(Icons.remove),
          onPressed: value - step >= min ? () => onChanged(value - step) : null,
        ),
        SizedBox(width: 40, child: Text('$value', textAlign: TextAlign.center)),
        IconButton(
          icon: const Icon(Icons.add),
          onPressed: value + step <= max ? () => onChanged(value + step) : null,
        ),
      ],
    );
  }
}

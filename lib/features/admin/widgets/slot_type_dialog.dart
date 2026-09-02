import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/models.dart';
import 'color_picker.dart';
import 'form_dialog.dart';
import 'form_fields.dart';

/// Add/edit dialog for a priority-slot type: name + color + whole-alley
/// switch/lane chips. is_match and builtin are server-guarded (column
/// grants) and never editable here. Saves through [Api.upsertSlotType]
/// itself and pops with `true` once the row is written.
class SlotTypeDialog extends StatefulWidget {
  const SlotTypeDialog({super.key, this.existing, required this.laneCount});

  final PrioritySlotType? existing;
  final int laneCount;

  @override
  State<SlotTypeDialog> createState() => _SlotTypeDialogState();
}

class _SlotTypeDialogState extends State<SlotTypeDialog> {
  final _name = TextEditingController();
  late int _colorIndex;
  late bool _wholeAlley;
  Set<int> _lanes = {};

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _name.text = existing?.name ?? '';
    _colorIndex = existing?.colorIndex ?? -1;
    _wholeAlley = existing?.lanes == null;
    _lanes = {...?existing?.lanes};
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<bool?> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      snack(context, 'Vyplň název.');
      return null;
    }
    if (!_wholeAlley && _lanes.isEmpty) {
      snack(context, 'Vyber aspoň jednu dráhu.');
      return null;
    }
    final ok = await tryAction(
      context,
      () => Api.upsertSlotType(
        id: widget.existing?.id,
        name: name,
        colorIndex: _colorIndex,
        lanes: _wholeAlley ? null : (_lanes.toList()..sort()),
      ),
      success: 'Uloženo.',
      errorText: friendlyDbError,
    );
    return ok ? true : null;
  }

  @override
  Widget build(BuildContext context) {
    return FormDialog<bool>(
      title: widget.existing == null ? 'Přidat typ' : 'Upravit typ',
      onSave: _save,
      children: [
        TextField(
          controller: _name,
          autofocus: widget.existing == null,
          decoration: const InputDecoration(labelText: 'Název'),
        ),
        const SizedBox(height: 16),
        ColorPickerGrid(
          selected: _colorIndex,
          noneValue: -1,
          noneLabel: 'Výchozí',
          onChanged: (index) => setState(() => _colorIndex = index),
        ),
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Celá kuželna'),
          subtitle: const Text('Vypnuto = blokuje jen vybrané dráhy.'),
          value: _wholeAlley,
          onChanged: (v) => setState(() => _wholeAlley = v),
        ),
        if (!_wholeAlley)
          LaneChips(
            laneCount: widget.laneCount,
            selected: _lanes,
            onChanged: (lanes) => setState(() => _lanes = lanes),
          ),
      ],
    );
  }
}

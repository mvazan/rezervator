import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../domain/models.dart';
import 'color_picker.dart';
import 'form_dialog.dart';

/// Add/edit dialog for a club: name field + [ColorPickerGrid]. Pops with
/// `(name, colorIndex)` — the screen runs the RPC, so a failed save can be
/// retried from the list.
class ClubDialog extends StatefulWidget {
  const ClubDialog({super.key, this.existing});

  final Club? existing;

  @override
  State<ClubDialog> createState() => _ClubDialogState();
}

class _ClubDialogState extends State<ClubDialog> {
  final _name = TextEditingController();
  late int _colorIndex;

  @override
  void initState() {
    super.initState();
    _name.text = widget.existing?.name ?? '';
    _colorIndex = widget.existing?.colorIndex ?? -1;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<(String, int)?> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      snack(context, 'Vyplň název oddílu.');
      return null;
    }
    return (name, _colorIndex);
  }

  @override
  Widget build(BuildContext context) {
    return FormDialog<(String, int)>(
      title: widget.existing == null ? 'Přidat oddíl' : 'Upravit oddíl',
      onSave: _save,
      children: [
        TextField(
          controller: _name,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Název'),
        ),
        const SizedBox(height: 16),
        ColorPickerGrid(
          selected: _colorIndex,
          noneValue: -1,
          noneLabel: 'Žádná',
          onChanged: (index) => setState(() => _colorIndex = index),
        ),
      ],
    );
  }
}

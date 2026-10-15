import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../domain/models.dart';
import 'color_picker.dart';
import 'form_dialog.dart';

/// Add/edit dialog for a club: name, nickname (0080) + [ColorPickerGrid].
/// Pops with `(name, colorIndex, nickname)` — the screen saves them, so a
/// failed save can be retried from the list. A club linked to the ČKA site
/// (0047) shows its name there under the field: the link survives any
/// rename.
class ClubDialog extends StatefulWidget {
  const ClubDialog({super.key, this.existing});

  final Club? existing;

  @override
  State<ClubDialog> createState() => _ClubDialogState();
}

class _ClubDialogState extends State<ClubDialog> {
  final _name = TextEditingController();
  final _nickname = TextEditingController();
  late int _colorIndex;

  @override
  void initState() {
    super.initState();
    _name.text = widget.existing?.name ?? '';
    _nickname.text = widget.existing?.nickname ?? '';
    _colorIndex = widget.existing?.colorIndex ?? -1;
  }

  @override
  void dispose() {
    _name.dispose();
    _nickname.dispose();
    super.dispose();
  }

  Future<(String, int, String?)?> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      snack(context, 'Vyplň název oddílu.');
      return null;
    }
    final nickname = _nickname.text.trim();
    return (name, _colorIndex, nickname.isEmpty ? null : nickname);
  }

  @override
  Widget build(BuildContext context) {
    final siteName = widget.existing?.siteName;
    final example = (siteName ?? widget.existing?.name ?? '').trim();
    return FormDialog<(String, int, String?)>(
      title: widget.existing == null ? 'Přidat oddíl' : 'Upravit oddíl',
      onSave: _save,
      children: [
        TextField(
          controller: _name,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'Název',
            helperText: siteName == null ? null : 'Na webu ČKA: $siteName',
            helperMaxLines: 2,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _nickname,
          maxLength: 30,
          decoration: InputDecoration(
            labelText: 'Přezdívka',
            helperText: example.isEmpty
                ? 'Krátké jméno, které appka ukazuje místo názvu — i v '
                      'názvech družstev.'
                : 'Krátké jméno, které appka ukazuje místo názvu — i v '
                      'názvech družstev: „$example B“ → „přezdívka B“. '
                      'Prázdná = celý název.',
            helperMaxLines: 3,
          ),
        ),
        const SizedBox(height: 8),
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

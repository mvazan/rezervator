import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/rental_groups.dart';
import 'color_picker.dart';
import 'form_dialog.dart';

/// Name and colour of a nepravidelný pronájem. A grouped one edits its
/// rental_groups row (the server propagates); a lone one-time rental has
/// no group row yet, so its own row is updated in place — date, lanes,
/// times and note unchanged. Pops `true` after a save.
class RentalGroupDialog extends StatefulWidget {
  const RentalGroupDialog({super.key, required this.group});

  final RentalGroup group;

  @override
  State<RentalGroupDialog> createState() => _RentalGroupDialogState();
}

class _RentalGroupDialogState extends State<RentalGroupDialog> {
  final _renterName = TextEditingController();
  var _color = -2;

  @override
  void initState() {
    super.initState();
    _renterName.text = widget.group.renterName;
    _color = widget.group.color;
  }

  @override
  void dispose() {
    _renterName.dispose();
    super.dispose();
  }

  Future<bool?> _save() async {
    final name = _renterName.text.trim();
    if (name.isEmpty) {
      snack(context, 'Vyplň nájemce.');
      return null;
    }
    final id = widget.group.id;
    final ok = await tryAction(
      context,
      () {
        if (id != null) {
          return Api.saveRentalGroup(id: id, renterName: name, color: _color);
        }
        final only = widget.group.dates.single;
        return Api.saveRental(
          id: only.id,
          renterName: name,
          lanes: only.lanes,
          date: only.date,
          startsAt: only.startsAt,
          endsAt: only.endsAt,
          note: only.note,
          color: _color,
        );
      },
      success: 'Pronájem uložen.',
      errorText: friendlyDbError,
    );
    return ok ? true : null;
  }

  @override
  Widget build(BuildContext context) {
    return FormDialog<bool>(
      title: 'Upravit pronájem',
      onSave: _save,
      children: [
        TextField(
          controller: _renterName,
          decoration: const InputDecoration(labelText: 'Nájemce'),
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

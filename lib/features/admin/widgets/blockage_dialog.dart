import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/models.dart';
import 'form_dialog.dart';
import 'form_fields.dart';

/// Add/edit dialog for a BLOCKAGE (any non-match priority slot): type
/// picker (šablóny — name, color, lane scope), date and two time pickers.
/// Matches have their own dialog ([MatchDialog] in match_dialog.dart).
class BlockageDialog extends StatefulWidget {
  const BlockageDialog({super.key, this.existing, required this.types});

  final PrioritySlot? existing;
  final List<PrioritySlotType> types;

  @override
  State<BlockageDialog> createState() => _BlockageDialogState();
}

class _BlockageDialogState extends State<BlockageDialog> {
  Day? _date;
  HourMinute? _start;
  HourMinute? _end;
  String? _typeId;
  final _description = TextEditingController();

  List<PrioritySlotType> get _types =>
      [for (final t in widget.types) if (!t.isMatch) t];

  PrioritySlotType? get _type =>
      _types.where((t) => t.id == _typeId).firstOrNull;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _date = existing?.date;
    _start = existing?.startsAt;
    _end = existing?.endsAt;
    _typeId = existing?.type.id ?? _types.firstOrNull?.id;
    _description.text = existing?.description ?? '';
  }

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    // Blockages allow retro entries: a year back, a year ahead.
    final now = today();
    final picked = await pickDay(
      context,
      initial: _date,
      first: now.addDays(-365),
      last: now.addDays(365),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _pickStart() async {
    final picked = await pickTime(context, initial: _start);
    if (picked == null) return;
    setState(() {
      _start = picked;
      if (_end == null) {
        final endMinutes = picked.minutesFromMidnight + 60;
        _end = HourMinute((endMinutes ~/ 60) % 24, endMinutes % 60);
      }
    });
  }

  Future<void> _pickEnd() async {
    final picked = await pickTime(context, initial: _end);
    if (picked != null) setState(() => _end = picked);
  }

  /// Validates and saves; null keeps the dialog open (the snack said why).
  Future<bool?> _save() async {
    final date = _date;
    final start = _start;
    final end = _end;
    final type = _type;
    if (type == null) {
      snack(context, 'Vyber typ.');
      return null;
    }
    if (date == null || start == null || end == null) {
      snack(context, 'Vyber datum a čas.');
      return null;
    }
    if (end.compareTo(start) <= 0) {
      snack(context, 'Konec musí být po začátku.');
      return null;
    }

    final ok = await tryAction(
      context,
      () => Api.savePrioritySlot(
        id: widget.existing?.id,
        date: date,
        startsAt: start,
        endsAt: end,
        typeId: type.id,
        description: _description.text.trim(),
      ),
      success: 'Uloženo. Kolidující rezervace byly zrušeny.',
      errorText: friendlyDbError,
    );
    return ok ? true : null;
  }

  @override
  Widget build(BuildContext context) {
    return FormDialog<bool>(
      title: widget.existing == null ? 'Přidat blokaci' : 'Upravit blokaci',
      onSave: _save,
      children: [
        DropdownButtonFormField<String>(
          initialValue: _typeId,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Typ'),
          items: [
            for (final t in _types)
              DropdownMenuItem(
                value: t.id,
                child: Text(
                  t.lanes == null
                      ? t.name
                      : '${t.name} (dráhy ${t.lanes!.join(', ')})',
                ),
              ),
          ],
          onChanged: (id) => setState(() => _typeId = id),
        ),
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
        TextField(
          controller: _description,
          decoration: const InputDecoration(labelText: 'Popis'),
        ),
      ],
    );
  }
}

import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/models.dart';

/// Add/edit dialog for a BLOCKAGE (any non-match priority slot): type
/// picker (šablóny — name, color, lane scope), date and two time pickers.
/// Matches have their own dialog in the Zápasy screen.
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
  bool _saving = false;

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
    final now = today();
    final initial = _date ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(initial.year, initial.month, initial.day),
      firstDate: DateTime(now.year, now.month, now.day)
          .subtract(const Duration(days: 365)),
      lastDate:
          DateTime(now.year, now.month, now.day).add(const Duration(days: 365)),
      locale: const Locale('cs'),
    );
    if (picked != null) setState(() => _date = Day.fromDateTime(picked));
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

  Future<void> _save() async {
    final date = _date;
    final start = _start;
    final end = _end;
    final type = _type;
    if (type == null) {
      snack(context, 'Vyber typ.');
      return;
    }
    if (date == null || start == null || end == null) {
      snack(context, 'Vyber datum a čas.');
      return;
    }
    if (end.compareTo(start) <= 0) {
      snack(context, 'Konec musí být po začátku.');
      return;
    }

    setState(() => _saving = true);
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
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title:
          Text(widget.existing == null ? 'Přidat blokaci' : 'Upravit blokaci'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Datum'),
              trailing: Text(_date == null ? 'Vybrat' : dayFull(_date!)),
              onTap: _pickDate,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Začátek'),
              trailing: Text(_start?.display() ?? '--:--'),
              onTap: _pickStart,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Konec'),
              trailing: Text(_end?.display() ?? '--:--'),
              onTap: _pickEnd,
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _description,
              decoration: const InputDecoration(labelText: 'Popis'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Zrušit'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Ukládám…' : 'Uložit'),
        ),
      ],
    );
  }
}

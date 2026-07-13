import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import 'widgets/admin_body.dart';

/// Admin: manage MATCHES. A match blocks the whole alley for its window;
/// its lane prep is the linked "Úklid před zápasem" child slot the server
/// maintains from the dialog's prep field (hidden here — it lives and dies
/// with the match). Other blockages moved to Výjimky dnů.
class MatchesScreen extends ConsumerWidget {
  const MatchesScreen({super.key});

  Future<void> _delete(BuildContext context, PrioritySlot slot) async {
    final confirmed = await confirmDialog(
      context,
      title: 'Smazat zápas?',
      message: 'Opravdu smazat „${slot.title}" (${dayLabel(slot.date)})?',
    );
    if (!confirmed) return;
    if (!context.mounted) return;

    await tryAction(
      context,
      () => Api.deletePrioritySlot(slot.id),
      errorText: friendlyDbError,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider).value;
    if (profile?.isAdmin != true) {
      return Scaffold(
        appBar: AppBar(title: const Text('Zápasy')),
        body: const Center(child: Text('Jen pro správce.')),
      );
    }

    final slots = ref.watch(prioritySlotsProvider);
    final sorted = [
      for (final s in slots)
        if (s.type.isMatch && s.parentId == null) s,
    ]..sort((a, b) => b.date.compareTo(a.date));
    final types = ref.watch(slotTypesProvider).value ?? const [];

    return Scaffold(
      appBar: AppBar(title: const Text('Zápasy')),
      body: AdminBody(
        child: sorted.isEmpty
            ? const Center(child: Text('Zatím žádné zápasy.'))
            : ListView(
                children: [
                  for (final slot in sorted)
                    ListTile(
                      title: Text(
                        '${dayLabel(slot.date)} · '
                        '${slot.startsAt.display()}–${slot.endsAt.display()} · '
                        '${slot.title}',
                      ),
                      subtitle: switch ([
                        if (slot.prepMinutes > 0)
                          'úklid ${slot.prepMinutes} min před',
                        if (slot.description.isNotEmpty) slot.description,
                      ].join(' · ')) {
                        '' => null,
                        final sub => Text(sub),
                      },
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () => showDialog<void>(
                              context: context,
                              builder: (_) => _SlotDialog(
                                  existing: slot, types: types),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _delete(context, slot),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showDialog<void>(
          context: context,
          builder: (_) => _SlotDialog(types: types),
        ),
        icon: const Icon(Icons.add),
        label: const Text('Přidat zápas'),
      ),
    );
  }
}

/// Prep-minute presets shown as SegmentedButton segments; anything else
/// selects the "Jiná…" (custom) segment.
const _prepPresets = [0, 30, 60];

/// Add/edit dialog for a MATCH: date + two time pickers (end defaults to
/// start + 3h), teams, and the úklid duration (the server maintains the
/// linked child slot from it).
class _SlotDialog extends StatefulWidget {
  const _SlotDialog({this.existing, required this.types});

  final PrioritySlot? existing;
  final List<PrioritySlotType> types;

  @override
  State<_SlotDialog> createState() => _SlotDialogState();
}

class _SlotDialogState extends State<_SlotDialog> {
  Day? _date;
  HourMinute? _start;
  HourMinute? _end;
  String? _typeId;
  final _homeTeam = TextEditingController();
  final _awayTeam = TextEditingController();
  final _description = TextEditingController();
  int _prepMinutes = 0;
  bool _saving = false;

  PrioritySlotType? get _type =>
      widget.types.where((t) => t.id == _typeId).firstOrNull;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _date = existing?.date;
    _start = existing?.startsAt;
    _end = existing?.endsAt;
    _typeId = existing?.type.id ??
        widget.types.where((t) => t.isMatch && t.builtin).firstOrNull?.id;
    _homeTeam.text = existing?.homeTeam ?? '';
    _awayTeam.text = existing?.awayTeam ?? '';
    _description.text = existing?.description ?? '';
    _prepMinutes = existing?.prepMinutes ?? 0;
  }

  @override
  void dispose() {
    _homeTeam.dispose();
    _awayTeam.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = today();
    final initial = _date ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(initial.year, initial.month, initial.day),
      firstDate: DateTime(
        now.year,
        now.month,
        now.day,
      ).subtract(const Duration(days: 365)),
      lastDate: DateTime(
        now.year,
        now.month,
        now.day,
      ).add(const Duration(days: 365)),
      locale: const Locale('cs'),
    );
    if (picked != null) setState(() => _date = Day.fromDateTime(picked));
  }

  Future<void> _pickStart() async {
    final picked = await pickTime(context, initial: _start);
    if (picked == null) return;
    setState(() {
      _start = picked;
      // Default a 3h span the first time a start is picked.
      if (_end == null) {
        final endMinutes = picked.minutesFromMidnight + 180;
        _end = HourMinute((endMinutes ~/ 60) % 24, endMinutes % 60);
      }
    });
  }

  Future<void> _pickEnd() async {
    final picked = await pickTime(context, initial: _end);
    if (picked != null) setState(() => _end = picked);
  }

  Future<void> _pickCustomPrep() async {
    final input = await promptText(
      context,
      title: 'Úklid před zápasem',
      hint: '0–240',
      initial: _prepMinutes.toString(),
      keyboardType: TextInputType.number,
      suffixText: 'min',
    );
    if (input == null) return;
    final minutes = int.tryParse(input);
    if (minutes == null || minutes < 0 || minutes > 240) {
      if (mounted) snack(context, 'Zadej 0–240 minut.');
      return;
    }
    setState(() => _prepMinutes = minutes);
  }

  Future<void> _save() async {
    final date = _date;
    final start = _start;
    final end = _end;
    final type = _type;
    if (type == null) {
      snack(context, 'Typ Zápas se ještě načítá — zkus to za chvíli.');
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
    final awayTeam = _awayTeam.text.trim();
    if (type.isMatch && awayTeam.isEmpty) {
      snack(context, 'Vyplň hosty.');
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
        homeTeam: type.isMatch ? _homeTeam.text.trim() : '',
        awayTeam: type.isMatch ? awayTeam : '',
        prepMinutes: type.isMatch ? _prepMinutes : 0,
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
    const isMatch = true;
    return AlertDialog(
      title: Text(widget.existing == null ? 'Přidat zápas' : 'Upravit zápas'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
            if (isMatch) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _homeTeam,
                decoration: const InputDecoration(labelText: 'Domácí'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _awayTeam,
                decoration: const InputDecoration(labelText: 'Hosté'),
              ),
            ],
            const SizedBox(height: 8),
            TextField(
              controller: _description,
              decoration: const InputDecoration(labelText: 'Popis'),
            ),
            if (isMatch) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Úklid před zápasem',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
              const SizedBox(height: 4),
              SegmentedButton<int>(
                segments: [
                  for (final preset in _prepPresets)
                    ButtonSegment(value: preset, label: Text('$preset min')),
                  ButtonSegment(
                    value: -1,
                    label: Text(
                      _prepPresets.contains(_prepMinutes)
                          ? 'Jiná…'
                          : '$_prepMinutes min',
                    ),
                  ),
                ],
                selected: {
                  _prepPresets.contains(_prepMinutes) ? _prepMinutes : -1,
                },
                onSelectionChanged: (selected) {
                  final value = selected.first;
                  if (value == -1) {
                    _pickCustomPrep();
                  } else {
                    setState(() => _prepMinutes = value);
                  }
                },
              ),
            ],
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

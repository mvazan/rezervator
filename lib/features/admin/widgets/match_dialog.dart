import 'package:flutter/material.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/limits.dart';
import '../../../domain/models.dart';
import 'form_dialog.dart';
import 'form_fields.dart';

/// Prep-minute presets shown as SegmentedButton segments; anything else
/// selects the "Jiná…" (custom) segment.
const _prepPresets = [0, 30, 60];

/// Add/edit dialog for a MATCH: date + two time pickers (end defaults to
/// start + 3h), teams, and the úklid duration (the server maintains the
/// linked child slot from it). Opened from the Zápasy screen and from the
/// calendar (tapping a match or its úklid band).
class MatchDialog extends StatefulWidget {
  const MatchDialog({super.key, this.existing, required this.types});

  final PrioritySlot? existing;
  final List<PrioritySlotType> types;

  @override
  State<MatchDialog> createState() => _MatchDialogState();
}

class _MatchDialogState extends State<MatchDialog> {
  Day? _date;
  HourMinute? _start;
  HourMinute? _end;
  String? _typeId;
  final _homeTeam = TextEditingController();
  final _awayTeam = TextEditingController();
  final _description = TextEditingController();
  int _prepMinutes = 0;
  bool _isAway = false;

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
    _isAway = existing?.isAway ?? false;
  }

  @override
  void dispose() {
    _homeTeam.dispose();
    _awayTeam.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    // Matches allow retro entries: a year back, a year ahead.
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
      hint: '${Limits.prepMinutes.min}–${Limits.prepMinutes.max}',
      initial: _prepMinutes.toString(),
      keyboardType: TextInputType.number,
      suffixText: 'min',
    );
    if (input == null) return;
    // Unparsable input fails the range check like an out-of-range number.
    final minutes = int.tryParse(input) ?? -1;
    final error = validatePrepMinutes(minutes);
    if (error != null) {
      if (mounted) snack(context, error);
      return;
    }
    setState(() => _prepMinutes = minutes);
  }

  /// Validates and saves; null keeps the dialog open (the snack said why).
  Future<bool?> _save() async {
    final date = _date;
    final start = _start;
    final end = _end;
    final type = _type;
    if (type == null) {
      snack(context, 'Typ Zápas se ještě načítá — zkus to za chvíli.');
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
    final awayTeam = _awayTeam.text.trim();
    if (awayTeam.isEmpty) {
      snack(context, 'Vyplň hosty.');
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
        homeTeam: _homeTeam.text.trim(),
        awayTeam: awayTeam,
        prepMinutes: _isAway ? 0 : _prepMinutes,
        description: _description.text.trim(),
        isAway: _isAway,
      ),
      success: _isAway
          ? 'Uloženo.'
          : 'Uloženo. Kolidující rezervace byly zrušeny.',
      errorText: friendlyDbError,
    );
    return ok ? true : null;
  }

  @override
  Widget build(BuildContext context) {
    return FormDialog<bool>(
      title: widget.existing == null ? 'Přidat zápas' : 'Upravit zápas',
      // Centred column (the prep SegmentedButton sits mid-dialog; its
      // label aligns itself left below).
      crossAxisAlignment: CrossAxisAlignment.center,
      onSave: _save,
      children: [
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
          controller: _homeTeam,
          decoration: const InputDecoration(labelText: 'Domácí'),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _awayTeam,
          decoration: const InputDecoration(labelText: 'Hosté'),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _description,
          decoration: const InputDecoration(labelText: 'Popis'),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Venkovní zápas'),
          subtitle: const Text('Hraje se jinde — neblokuje kuželnu.'),
          value: _isAway,
          onChanged: (value) => setState(() => _isAway = value),
        ),
        if (!_isAway) ...[
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
    );
  }
}

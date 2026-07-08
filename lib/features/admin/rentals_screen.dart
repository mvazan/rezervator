import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import 'widgets/color_picker.dart';

/// One-time rentals first (sorted by date, ascending), then weekly rentals
/// (sorted by weekday, Monday..Sunday).
int _compareRentals(Rental a, Rental b) {
  final aDate = a.date;
  final bDate = b.date;
  if (aDate != null && bDate != null) return aDate.compareTo(bDate);
  if (aDate != null) return -1;
  if (bDate != null) return 1;
  return a.weekday!.compareTo(b.weekday!);
}

/// Admin: manage lane rentals (one-time or weekly-recurring) that block
/// reservations for the rented lanes/time.
class RentalsScreen extends ConsumerWidget {
  const RentalsScreen({super.key});

  Future<void> _delete(BuildContext context, Rental rental) async {
    final confirmed = await confirmDialog(
      context,
      title: 'Smazat pronájem?',
      message: 'Opravdu smazat pronájem pro ${rental.renterName}?',
    );
    if (!confirmed) return;
    if (!context.mounted) return;

    await tryAction(
      context,
      () => Api.deleteRental(rental.id),
      errorText: friendlyDbError,
    );
  }

  String _subtitle(Rental rental) {
    final lines = <String>[];
    final date = rental.date;
    if (date != null) {
      lines.add('jednorázově ${dayLabel(date)}');
    } else {
      lines.add(
        'každý ${weekdayFull(rental.weekday!)} '
        '${rental.startsAt.display()}–${rental.endsAt.display()}',
      );
    }
    lines.add('dráhy ${rental.lanes.join(', ')}');
    final validFrom = rental.validFrom;
    final validUntil = rental.validUntil;
    if (validFrom != null && validUntil != null) {
      lines.add('platí ${rangeLabel(validFrom, validUntil)}');
    } else if (validFrom != null) {
      lines.add('platí od ${dayLabel(validFrom)}');
    } else if (validUntil != null) {
      lines.add('platí do ${dayLabel(validUntil)}');
    }
    var subtitle = lines.join('\n');
    if (rental.note.isNotEmpty) subtitle += ' · ${rental.note}';
    return subtitle;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider).value;
    if (profile?.isAdmin != true) {
      return Scaffold(
        appBar: AppBar(title: const Text('Pronájmy')),
        body: const Center(child: Text('Jen pro správce.')),
      );
    }

    final rentals = ref.watch(rentalsProvider).value ?? const <Rental>[];
    final sorted = [...rentals]..sort(_compareRentals);
    final laneCount =
        ref.watch(settingsProvider).value?.laneCount ??
        ScheduleSettings.defaults.laneCount;

    return Scaffold(
      appBar: AppBar(title: const Text('Pronájmy')),
      body: sorted.isEmpty
          ? const Center(child: Text('Zatím žádné pronájmy.'))
          : ListView(
              children: [
                for (final rental in sorted)
                  ListTile(
                    title: Text(rental.renterName),
                    subtitle: Text(_subtitle(rental)),
                    isThreeLine:
                        rental.validFrom != null || rental.validUntil != null,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit_outlined),
                          onPressed: () => showDialog<void>(
                            context: context,
                            builder: (_) => _RentalDialog(
                              existing: rental,
                              laneCount: laneCount,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => _delete(context, rental),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showDialog<void>(
          context: context,
          builder: (_) => _RentalDialog(laneCount: laneCount),
        ),
        icon: const Icon(Icons.add),
        label: const Text('Přidat pronájem'),
      ),
    );
  }
}

enum _RentalMode { oneTime, weekly }

/// Add/edit dialog. The mode radio (Jednorázový / Týdenní) structurally
/// guarantees date XOR weekday: only the field for the active mode is ever
/// read when saving, so the other is always sent as null.
class _RentalDialog extends StatefulWidget {
  const _RentalDialog({this.existing, required this.laneCount});

  final Rental? existing;
  final int laneCount;

  @override
  State<_RentalDialog> createState() => _RentalDialogState();
}

class _RentalDialogState extends State<_RentalDialog> {
  final _renterName = TextEditingController();
  final _note = TextEditingController();
  _RentalMode _mode = _RentalMode.oneTime;
  Day? _date;
  int _weekday = DateTime.monday;
  Day? _validFrom;
  Day? _validUntil;
  HourMinute? _start;
  HourMinute? _end;
  final Set<int> _lanes = {};
  int _color = -2;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _renterName.text = existing?.renterName ?? '';
    _note.text = existing?.note ?? '';
    _start = existing?.startsAt;
    _end = existing?.endsAt;
    _lanes.addAll(existing?.lanes ?? const []);
    _color = existing?.color ?? -2;
    if (existing == null) {
      _mode = _RentalMode.oneTime;
    } else if (existing.date != null) {
      _mode = _RentalMode.oneTime;
      _date = existing.date;
    } else {
      _mode = _RentalMode.weekly;
      _weekday = existing.weekday!;
      _validFrom = existing.validFrom;
      _validUntil = existing.validUntil;
    }
  }

  @override
  void dispose() {
    _renterName.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDate({
    required Day? initial,
    required Day firstDate,
    required void Function(Day) onPicked,
  }) async {
    final base = initial ?? today();
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(base.year, base.month, base.day),
      firstDate: DateTime(firstDate.year, firstDate.month, firstDate.day),
      lastDate: DateTime(
        firstDate.year,
        firstDate.month,
        firstDate.day,
      ).add(const Duration(days: 365 * 2)),
      locale: const Locale('cs'),
    );
    if (picked != null) onPicked(Day.fromDateTime(picked));
  }

  Future<void> _pickStart() async {
    final picked = await pickTime(context, initial: _start);
    if (picked != null) setState(() => _start = picked);
  }

  Future<void> _pickEnd() async {
    final picked = await pickTime(context, initial: _end);
    if (picked != null) setState(() => _end = picked);
  }

  Future<void> _save() async {
    final renterName = _renterName.text.trim();
    if (renterName.isEmpty) {
      snack(context, 'Vyplň nájemce.');
      return;
    }
    final start = _start;
    final end = _end;
    if (start == null || end == null) {
      snack(context, 'Vyber začátek i konec.');
      return;
    }
    if (end.compareTo(start) <= 0) {
      snack(context, 'Konec musí být po začátku.');
      return;
    }
    if (_mode == _RentalMode.oneTime && _date == null) {
      snack(context, 'Vyber datum.');
      return;
    }
    if (_lanes.isEmpty) {
      snack(context, 'Vyber aspoň jednu dráhu.');
      return;
    }
    final validFrom = _mode == _RentalMode.weekly ? _validFrom : null;
    final validUntil = _mode == _RentalMode.weekly ? _validUntil : null;
    if (validFrom != null &&
        validUntil != null &&
        validUntil.isBefore(validFrom)) {
      snack(context, '„Platí od" musí být před „Platí do".');
      return;
    }

    setState(() => _saving = true);
    final lanes = _lanes.toList()..sort();
    final ok = await tryAction(
      context,
      () => Api.saveRental(
        id: widget.existing?.id,
        renterName: renterName,
        lanes: lanes,
        date: _mode == _RentalMode.oneTime ? _date : null,
        weekday: _mode == _RentalMode.weekly ? _weekday : null,
        startsAt: start,
        endsAt: end,
        validFrom: validFrom,
        validUntil: validUntil,
        note: _note.text.trim(),
        color: _color,
      ),
      success: 'Pronájem uložen. Kolidující rezervace byly zrušeny.',
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
    final now = today();
    // Matches/rentals allow retro entries (unlike overrides, which are
    // future-only).
    final earliestDate = now.addDays(-365);

    return AlertDialog(
      title: Text(
        widget.existing == null ? 'Přidat pronájem' : 'Upravit pronájem',
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _renterName,
              decoration: const InputDecoration(labelText: 'Nájemce'),
            ),
            const SizedBox(height: 8),
            RadioGroup<_RentalMode>(
              groupValue: _mode,
              onChanged: (v) => setState(() => _mode = v!),
              child: const Column(
                children: [
                  RadioListTile<_RentalMode>(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Jednorázový'),
                    value: _RentalMode.oneTime,
                  ),
                  RadioListTile<_RentalMode>(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Týdenní'),
                    value: _RentalMode.weekly,
                  ),
                ],
              ),
            ),
            if (_mode == _RentalMode.oneTime)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Datum'),
                trailing: Text(_date == null ? 'Vybrat' : dayFull(_date!)),
                onTap: () => _pickDate(
                  initial: _date,
                  firstDate: earliestDate,
                  onPicked: (d) => setState(() => _date = d),
                ),
              )
            else ...[
              DropdownButtonFormField<int>(
                initialValue: _weekday,
                decoration: const InputDecoration(labelText: 'Den v týdnu'),
                items: [
                  for (var w = DateTime.monday; w <= DateTime.sunday; w++)
                    DropdownMenuItem(value: w, child: Text(weekdayFull(w))),
                ],
                onChanged: (v) => setState(() => _weekday = v!),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Platí od'),
                trailing: Text(
                  _validFrom == null ? 'Nenastaveno' : dayFull(_validFrom!),
                ),
                onTap: () => _pickDate(
                  initial: _validFrom,
                  firstDate: earliestDate,
                  onPicked: (d) => setState(() => _validFrom = d),
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Platí do'),
                trailing: Text(
                  _validUntil == null ? 'Nenastaveno' : dayFull(_validUntil!),
                ),
                onTap: () => _pickDate(
                  initial: _validUntil,
                  firstDate: _validFrom ?? earliestDate,
                  onPicked: (d) => setState(() => _validUntil = d),
                ),
              ),
            ],
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
            Wrap(
              spacing: 8,
              children: [
                for (var lane = 1; lane <= widget.laneCount; lane++)
                  FilterChip(
                    label: Text('Dráha $lane'),
                    selected: _lanes.contains(lane),
                    onSelected: (selected) => setState(() {
                      if (selected) {
                        _lanes.add(lane);
                      } else {
                        _lanes.remove(lane);
                      }
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _note,
              decoration: const InputDecoration(labelText: 'Poznámka'),
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

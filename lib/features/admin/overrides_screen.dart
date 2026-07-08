import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/blocks.dart';
import '../../domain/models.dart';

/// Admin: manage per-day overrides (closures and custom block sets) that
/// take precedence over the weekly training-day rule.
class OverridesScreen extends ConsumerWidget {
  const OverridesScreen({super.key});

  Future<void> _delete(BuildContext context, DayOverride override) async {
    final confirmed = await confirmDialog(
      context,
      title: 'Smazat výjimku?',
      message: 'Den se vrátí k týdennímu pravidlu.',
    );
    if (!confirmed) return;
    if (!context.mounted) return;

    await tryAction(
      context,
      () => Api.deleteDayOverride(override.date),
      errorText: friendlyDbError,
    );
  }

  String _subtitle(DayOverride override, List<TimeBlock> blocks) {
    if (override.closed) {
      return 'Zavřeno — ${override.reason}';
    }
    final blockIds = override.blockIds;
    if (blockIds == null) {
      return 'Otevřeno (výchozí bloky)';
    }
    final blockById = {for (final b in blocks) b.id: b};
    final times = [
      for (final id in blockIds)
        if (blockById[id] != null) blockById[id]!.label,
    ];
    return times.isEmpty ? 'Vlastní časy' : times.join(' · ');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider).value;
    if (profile?.isAdmin != true) {
      return Scaffold(
        appBar: AppBar(title: const Text('Výjimky dnů')),
        body: const Center(child: Text('Jen pro správce.')),
      );
    }

    final overrides =
        ref.watch(dayOverridesProvider).value ?? const <DayOverride>[];
    final sorted = [...overrides]..sort((a, b) => a.date.compareTo(b.date));
    final blocks = ref.watch(timeBlocksProvider).value ?? const <TimeBlock>[];

    return Scaffold(
      appBar: AppBar(title: const Text('Výjimky dnů')),
      body: sorted.isEmpty
          ? const Center(child: Text('Zatím žádné výjimky.'))
          : ListView(
              children: [
                for (final override in sorted)
                  ListTile(
                    title: Text(dayFull(override.date)),
                    subtitle: Text(_subtitle(override, blocks)),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _delete(context, override),
                    ),
                  ),
              ],
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showDialog<void>(
          context: context,
          builder: (_) => const _OverrideDialog(),
        ),
        icon: const Icon(Icons.add),
        label: const Text('Přidat výjimku'),
      ),
    );
  }
}

/// Add/edit-override dialog: date picker, closed/open mode radio, and —
/// when open — a custom-times rows editor (od–do), prefilled from the day's
/// effective blocks (an existing override's blocks, or else the default
/// active set). Picking a date that already has an override edits it in
/// place ([Api.setDayOverride] upserts by date).
class _OverrideDialog extends ConsumerStatefulWidget {
  const _OverrideDialog();

  @override
  ConsumerState<_OverrideDialog> createState() => _OverrideDialogState();
}

class _OverrideDialogState extends ConsumerState<_OverrideDialog> {
  Day? _date;
  bool _closed = true;
  final _reason = TextEditingController();
  final List<(HourMinute?, HourMinute?)> _rows = [];
  bool _saving = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  /// The blocks that apply to [date] today: an existing override's blocks
  /// when it has a custom set (or all active blocks when it's open with the
  /// default set), otherwise the default active blocks.
  List<TimeBlock> _effectiveBlocksFor(Day date) {
    final blocks = ref.read(timeBlocksProvider).value ?? const <TimeBlock>[];
    final overrides =
        ref.read(dayOverridesProvider).value ?? const <DayOverride>[];
    final override =
        overrides.where((o) => o.date == date && !o.closed).firstOrNull;
    final blockById = {for (final b in blocks) b.id: b};
    if (override?.blockIds != null) {
      return [
        for (final id in override!.blockIds!)
          if (blockById[id] != null) blockById[id]!,
      ];
    }
    return blocks.where((b) => b.active).toList();
  }

  Future<void> _pickDate() async {
    final now = today();
    final initial = _date ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(initial.year, initial.month, initial.day),
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(
        now.year,
        now.month,
        now.day,
      ).add(const Duration(days: 365)),
      locale: const Locale('cs'),
    );
    if (picked == null) return;
    final date = Day.fromDateTime(picked);
    final overrides =
        ref.read(dayOverridesProvider).value ?? const <DayOverride>[];
    final existing = overrides.where((o) => o.date == date).firstOrNull;
    setState(() {
      _date = date;
      _closed = existing?.closed ?? true;
      _reason.text = existing?.reason ?? '';
      _rows
        ..clear()
        ..addAll([
          for (final block in _effectiveBlocksFor(date))
            (block.startsAt, block.endsAt),
        ]);
    });
  }

  Future<void> _pickRowStart(int index) async {
    final picked = await pickTime(context, initial: _rows[index].$1);
    if (picked != null) {
      setState(() => _rows[index] = (picked, _rows[index].$2));
    }
  }

  Future<void> _pickRowEnd(int index) async {
    final picked = await pickTime(context, initial: _rows[index].$2);
    if (picked != null) {
      setState(() => _rows[index] = (_rows[index].$1, picked));
    }
  }

  void _addRow() => setState(() => _rows.add((null, null)));

  void _removeRow(int index) => setState(() => _rows.removeAt(index));

  /// Validates the rows (all times set, end>start, no pairwise overlap, at
  /// least one row); returns the error message, or null when valid.
  String? _rowsError() {
    if (_rows.isEmpty) return 'Přidej aspoň jeden čas.';
    final ranges = <(HourMinute, HourMinute)>[];
    for (final row in _rows) {
      final start = row.$1;
      final end = row.$2;
      if (start == null || end == null) return 'Vyplň všechny časy.';
      if (end.compareTo(start) <= 0) return 'Konec musí být po začátku.';
      ranges.add((start, end));
    }
    for (var i = 0; i < ranges.length; i++) {
      for (var j = i + 1; j < ranges.length; j++) {
        final a = ranges[i];
        final b = ranges[j];
        final overlaps = a.$1.compareTo(b.$2) < 0 && b.$1.compareTo(a.$2) < 0;
        if (overlaps) return 'Časy se nesmí překrývat.';
      }
    }
    return null;
  }

  Future<void> _save() async {
    final date = _date;
    if (date == null) {
      snack(context, 'Vyber datum.');
      return;
    }
    if (_closed && _reason.text.trim().isEmpty) {
      snack(context, 'Vyplň důvod.');
      return;
    }
    List<(HourMinute, HourMinute)>? ranges;
    if (!_closed) {
      final error = _rowsError();
      if (error != null) {
        snack(context, error);
        return;
      }
      ranges = [for (final row in _rows) (row.$1!, row.$2!)];
    }

    setState(() => _saving = true);
    final ok = await tryAction(
      context,
      () async {
        List<String>? blockIds;
        if (ranges != null) {
          final existingInactive = (ref.read(timeBlocksProvider).value ??
                  const <TimeBlock>[])
              .where((b) => !b.active)
              .toList();
          final result = matchSpecialBlocks(
            existingInactive: existingInactive,
            requested: ranges,
          );
          final createdIds = [
            for (final range in result.toCreate)
              await Api.addSpecialTimeBlock(range.$1, range.$2),
          ];
          blockIds = [...result.reuseIds, ...createdIds];
        }
        await Api.setDayOverride(
          date: date,
          closed: _closed,
          reason: _closed ? _reason.text.trim() : '',
          blockIds: blockIds,
        );
      },
      success: 'Výjimka uložena. Kolidující rezervace byly zrušeny.',
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
      title: const Text('Přidat výjimku'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Datum'),
              trailing: Text(_date == null ? 'Vybrat' : dayFull(_date!)),
              onTap: _pickDate,
            ),
            RadioGroup<bool>(
              groupValue: _closed,
              onChanged: (v) => setState(() => _closed = v!),
              child: const Column(
                children: [
                  RadioListTile<bool>(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Zavřeno'),
                    value: true,
                  ),
                  RadioListTile<bool>(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Otevřeno — vlastní časy'),
                    value: false,
                  ),
                ],
              ),
            ),
            if (_closed)
              Padding(
                padding: const EdgeInsets.only(left: 16, bottom: 8),
                child: TextField(
                  controller: _reason,
                  decoration: const InputDecoration(
                    labelText: 'Důvod',
                    hintText: 'Malování drah',
                  ),
                ),
              ),
            if (!_closed)
              Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < _rows.length; i++)
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => _pickRowStart(i),
                              child: Text(_rows[i].$1?.display() ?? '--:--'),
                            ),
                          ),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 4),
                            child: Text('–'),
                          ),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => _pickRowEnd(i),
                              child: Text(_rows[i].$2?.display() ?? '--:--'),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close),
                            tooltip: 'Odebrat',
                            onPressed: () => _removeRow(i),
                          ),
                        ],
                      ),
                    TextButton.icon(
                      onPressed: _addRow,
                      icon: const Icon(Icons.add),
                      label: const Text('Přidat čas'),
                    ),
                  ],
                ),
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

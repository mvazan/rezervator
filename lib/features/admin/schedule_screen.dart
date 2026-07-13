import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/block_generator.dart';
import '../../domain/models.dart';
import 'widgets/admin_body.dart';
import 'widgets/block_dialog.dart';

/// Admin: one screen for the whole schedule shape — the `schedule_settings`
/// singleton (lane count, training days, horizon, per-player cap) on top and
/// the time-block list (add/edit/generate/deactivate/delete) below.
class ScheduleAdminScreen extends ConsumerStatefulWidget {
  const ScheduleAdminScreen({super.key});

  @override
  ConsumerState<ScheduleAdminScreen> createState() =>
      _ScheduleAdminScreenState();
}

class _ScheduleAdminScreenState extends ConsumerState<ScheduleAdminScreen> {
  final _laneCount = TextEditingController();
  final _horizonDays = TextEditingController();
  final _maxReservations = TextEditingController();
  Set<int> _trainingWeekdays = {};
  bool _saving = false;
  bool _initialized = false;

  @override
  void dispose() {
    _laneCount.dispose();
    _horizonDays.dispose();
    _maxReservations.dispose();
    super.dispose();
  }

  void _initFrom(ScheduleSettings settings) {
    _laneCount.text = '${settings.laneCount}';
    _horizonDays.text = '${settings.bookingHorizonDays}';
    _maxReservations.text = '${settings.maxActiveReservations}';
    _trainingWeekdays = {...settings.trainingWeekdays};
    _initialized = true;
  }

  /// Returns an error message on failure, or null when valid.
  String? _validate(int laneCount, int horizonDays, int maxReservations) {
    if (laneCount < 1 || laneCount > 12) {
      return 'Počet drah musí být 1–12.';
    }
    if (horizonDays < 1 || horizonDays > 90) {
      return 'Rezervace dopředu musí být 1–90 dní.';
    }
    if (maxReservations < 1 || maxReservations > 50) {
      return 'Max. aktivních rezervací musí být 1–50.';
    }
    return null;
  }

  /// Fetches future live reservations and counts those that would fall
  /// outside the grid under [newLaneCount]/[newWeekdays]. This is a
  /// conservative upper bound: a day override with custom blocks may keep
  /// some of these visible even off the regular weekday set, but the admin
  /// still gets warned rather than silently orphaning anyone.
  Future<int> _countStranded(int newLaneCount, Set<int> newWeekdays) async {
    final reservations = await Api.futureLiveReservations(today());
    return reservations
        .where(
          (r) => r.lane > newLaneCount || !newWeekdays.contains(r.date.weekday),
        )
        .length;
  }

  Future<void> _save() async {
    final laneCount = int.tryParse(_laneCount.text);
    final horizonDays = int.tryParse(_horizonDays.text);
    final maxReservations = int.tryParse(_maxReservations.text);
    if (laneCount == null || horizonDays == null || maxReservations == null) {
      snack(context, 'Zkontroluj vyplněná čísla.');
      return;
    }
    final error = _validate(laneCount, horizonDays, maxReservations);
    if (error != null) {
      snack(context, error);
      return;
    }

    final current = ref.read(settingsProvider).value;
    if (current == null) {
      // The settings row hasn't loaded (or errored): tenant_id — the update
      // key — is unknown, so saving now could not target the right row.
      snack(context, 'Nastavení se ještě načítá — zkus to za chvíli.');
      return;
    }
    final shrinksGrid = laneCount < current.laneCount ||
        !_trainingWeekdays.containsAll(current.trainingWeekdays);
    if (shrinksGrid) {
      final stranded = await _countStranded(laneCount, _trainingWeekdays);
      if (stranded > 0) {
        if (!mounted) return;
        final confirmed = await confirmDialog(
          context,
          title: 'Pozor — osiřelé rezervace',
          message:
              '$stranded budoucích rezervací zůstane mimo rozvrh (nezobrazí se a nepůjdou zrušit z mřížky). Opravdu uložit?',
          confirmLabel: 'Uložit i tak',
        );
        if (!confirmed) return;
      }
    }

    if (!mounted) return;
    setState(() => _saving = true);
    await tryAction(
      context,
      () => Api.updateSettings(
        tenantId: current.tenantId,
        laneCount: laneCount,
        trainingWeekdays: _trainingWeekdays,
        bookingHorizonDays: horizonDays,
        maxActiveReservations: maxReservations,
      ),
      success: 'Uloženo.',
      errorText: friendlyDbError,
    );
    if (mounted) setState(() => _saving = false);
  }

  // --- blocks section -------------------------------------------------------

  Future<void> _setBlockActive(TimeBlock block, bool active) async {
    if (!active) {
      final ok = await confirmIfBlockStrands(context, block.id);
      if (!ok || !mounted) return;
    }
    if (!mounted) return;
    await tryAction(
      context,
      () => Api.updateTimeBlock(block.id, active: active),
      errorText: friendlyDbError,
    );
  }

  Future<void> _deleteBlock(TimeBlock block) async {
    final confirmed = await confirmDialog(
      context,
      title: 'Smazat blok?',
      message: 'Opravdu smazat blok ${block.label}?',
    );
    if (!confirmed || !mounted) return;

    try {
      await Api.deleteTimeBlock(block.id);
      if (mounted) snack(context, 'Blok smazán.');
      return;
    } on PostgrestException catch (e) {
      if (e.code != '23503') {
        if (mounted) snack(context, friendlyDbError(e));
        return;
      }
      // FK restrict: block already has reservations — deactivate instead.
    }

    if (!mounted) return;
    final ok = await confirmIfBlockStrands(context, block.id);
    if (!ok || !mounted) return;
    await tryAction(
      context,
      () => Api.updateTimeBlock(block.id, active: false),
      success: 'Blok už má rezervace — místo smazání deaktivován.',
      errorText: friendlyDbError,
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(myProfileProvider).value;
    if (profile?.isAdmin != true) {
      return Scaffold(
        appBar: AppBar(title: const Text('Rozvrh')),
        body: const Center(child: Text('Jen pro správce.')),
      );
    }

    final settingsAsync = ref.watch(settingsProvider);
    final blocks = ref.watch(timeBlocksProvider).value ?? const <TimeBlock>[];

    return Scaffold(
      appBar: AppBar(title: const Text('Rozvrh')),
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(friendlyDbError(e))),
        data: (settings) {
          if (settings == null) {
            return const Center(
              child: Text('Nastavení zatím není k dispozici.'),
            );
          }
          if (!_initialized) _initFrom(settings);

          return AdminBody(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TextField(
                  controller: _laneCount,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Počet drah',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'Tréninkové dny',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (var i = 0; i < 7; i++)
                      FilterChip(
                        label: Text(weekdaysShort[i]),
                        selected: _trainingWeekdays.contains(i + 1),
                        onSelected: (selected) => setState(() {
                          if (selected) {
                            _trainingWeekdays.add(i + 1);
                          } else {
                            _trainingWeekdays.remove(i + 1);
                          }
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _horizonDays,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Rezervace dopředu (dní)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _maxReservations,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Max. aktivních rezervací na hráče',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? 'Ukládám…' : 'Uložit'),
                ),
                const SizedBox(height: 24),
                const Divider(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Tréninkové bloky',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.auto_awesome_motion_outlined),
                          tooltip: 'Vygenerovat bloky',
                          onPressed: () => showDialog<void>(
                            context: context,
                            builder: (_) => _GeneratorDialog(blocks: blocks),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.add),
                          tooltip: 'Přidat blok',
                          onPressed: () => showDialog<void>(
                            context: context,
                            builder: (_) =>
                                BlockDialog(existing: null, blocks: blocks),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                if (blocks.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('Zatím žádné bloky.'),
                  )
                else
                  for (final block in blocks)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(block.label),
                      subtitle: Text('Pozice ${block.position}'),
                      leading: Switch(
                        value: block.active,
                        onChanged: (active) => _setBlockActive(block, active),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () => showDialog<void>(
                              context: context,
                              builder: (_) =>
                                  BlockDialog(existing: block, blocks: blocks),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _deleteBlock(block),
                          ),
                        ],
                      ),
                    ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// "Vygenerovat bloky": start + délka + pauza + počet with a live preview of
/// the resulting series; saving appends the blocks (positions continue after
/// the current maximum). Overlaps with existing ACTIVE blocks disable save.
class _GeneratorDialog extends ConsumerStatefulWidget {
  const _GeneratorDialog({required this.blocks});

  final List<TimeBlock> blocks;

  @override
  ConsumerState<_GeneratorDialog> createState() => _GeneratorDialogState();
}

class _GeneratorDialogState extends ConsumerState<_GeneratorDialog> {
  HourMinute? _start;
  int _duration = 60;
  int _pause = 0;
  int _count = 4;
  bool _saving = false;

  List<(HourMinute, HourMinute)>? get _times => _start == null
      ? null
      : generateBlockTimes(
          start: _start!,
          durationMinutes: _duration,
          pauseMinutes: _pause,
          count: _count,
        );

  List<String> get _conflicts =>
      _times == null ? const [] : generatorConflicts(_times!, widget.blocks);

  Future<void> _pickStart() async {
    final picked = await pickTime(context, initial: _start);
    if (picked != null) setState(() => _start = picked);
  }

  Future<void> _save() async {
    final times = _times;
    if (times == null) {
      snack(context, 'Vyber začátek.');
      return;
    }
    setState(() => _saving = true);
    var position = widget.blocks.isEmpty
        ? 0
        : widget.blocks.map((b) => b.position).reduce((a, b) => a > b ? a : b) +
              1;
    final ok = await tryAction(
      context,
      () async {
        for (final (start, end) in times) {
          await Api.addTimeBlock(start, end, position++);
        }
      },
      success: 'Vytvořeno ${times.length} bloků.',
      errorText: friendlyDbError,
    );
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() => _saving = false);
    }
  }

  Widget _stepperRow(
    String label,
    int value,
    ValueChanged<int> onChanged, {
    required int min,
    required int max,
    int step = 1,
  }) {
    return Row(
      children: [
        Expanded(child: Text(label)),
        IconButton(
          icon: const Icon(Icons.remove),
          onPressed: value - step >= min ? () => onChanged(value - step) : null,
        ),
        SizedBox(width: 40, child: Text('$value', textAlign: TextAlign.center)),
        IconButton(
          icon: const Icon(Icons.add),
          onPressed: value + step <= max ? () => onChanged(value + step) : null,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final times = _times;
    final conflicts = _conflicts;
    final scheme = Theme.of(context).colorScheme;

    return AlertDialog(
      title: const Text('Vygenerovat bloky'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Začátek'),
              trailing: Text(_start?.display() ?? '--:--'),
              onTap: _pickStart,
            ),
            _stepperRow(
              'Délka (min)',
              _duration,
              (v) => setState(() => _duration = v),
              min: 15,
              max: 240,
              step: 15,
            ),
            _stepperRow(
              'Pauza (min)',
              _pause,
              (v) => setState(() => _pause = v),
              min: 0,
              max: 60,
              step: 5,
            ),
            _stepperRow(
              'Počet bloků',
              _count,
              (v) => setState(() => _count = v),
              min: 1,
              max: 12,
            ),
            const SizedBox(height: 12),
            if (_start != null && times == null)
              Text(
                'Série přesahuje půlnoc — zkrať ji.',
                style: TextStyle(color: scheme.error),
              )
            else if (times != null) ...[
              Text(
                [
                  for (final (s, e) in times) '${s.display()}–${e.display()}',
                ].join(', '),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (conflicts.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Koliduje s existujícími bloky: ${conflicts.join(', ')}',
                    style: TextStyle(color: scheme.error),
                  ),
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
          onPressed: _saving || times == null || conflicts.isNotEmpty
              ? null
              : _save,
          child: Text(_saving ? 'Ukládám…' : 'Vytvořit'),
        ),
      ],
    );
  }
}

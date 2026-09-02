import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/day_edit.dart';
import '../../domain/limits.dart';
import '../../domain/models.dart';
import 'widgets/admin_scaffold.dart';
import 'widgets/block_dialog.dart';
import 'widgets/generator_dialog.dart';

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

  /// True once the admin has edited a field: the live settings stream then
  /// leaves the form alone (a change from another device would otherwise
  /// wipe the edit). Cleared by a successful save.
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    // Settings loaded before this screen opened: the stream only reports
    // changes, so seed from the current value once. ref.listen in build
    // covers data arriving later — and every later change.
    final settings = ref.read(settingsProvider).value;
    if (settings != null) _initFrom(settings);
  }

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
  }

  void _markDirty(String _) => _dirty = true;

  /// Future live reservations the new grid would cancel (server cascade,
  /// 0018) — the pre-flight warning before the save.
  Future<int> _countStranded(int newLaneCount, Set<int> newWeekdays) async =>
      strandedByGrid(
        await Api.futureLiveReservations(today()),
        laneCount: newLaneCount,
        trainingWeekdays: newWeekdays,
      );

  Future<void> _save() async {
    final laneCount = int.tryParse(_laneCount.text);
    final horizonDays = int.tryParse(_horizonDays.text);
    final maxReservations = int.tryParse(_maxReservations.text);
    if (laneCount == null || horizonDays == null || maxReservations == null) {
      snack(context, 'Zkontroluj vyplněná čísla.');
      return;
    }
    final error = validateScheduleSettings(
      laneCount: laneCount,
      horizonDays: horizonDays,
      maxReservations: maxReservations,
    );
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
          title: 'Pozor — rezervace se zruší',
          message:
              '$stranded budoucích rezervací se tímto zruší (hráči dostanou upozornění). Opravdu uložit?',
          confirmLabel: 'Uložit i tak',
        );
        if (!confirmed) return;
      }
    }

    if (!mounted) return;
    setState(() => _saving = true);
    final ok = await tryAction(
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
    if (mounted) {
      setState(() {
        _saving = false;
        if (ok) _dirty = false;
      });
    }
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
    var deleted = false;
    final ok = await confirmDelete(
      context,
      title: 'Smazat blok?',
      message: 'Opravdu smazat blok ${block.label}?',
      action: () async => deleted = await Api.deleteTimeBlock(block.id),
    );
    if (!ok || !mounted) return;
    if (deleted) {
      snack(context, 'Blok smazán.');
      return;
    }
    // Block already has reservations — deactivate instead.
    final proceed = await confirmIfBlockStrands(context, block.id);
    if (!proceed || !mounted) return;
    await tryAction(
      context,
      () => Api.updateTimeBlock(block.id, active: false),
      success: 'Blok už má rezervace — místo smazání deaktivován.',
      errorText: friendlyDbError,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Settings arriving (or changed on another device) re-seed the untouched
    // form. No setState: the ref.watch below rebuilds the chips for the very
    // same change, and the controllers repaint their fields themselves.
    ref.listen(settingsProvider, (_, next) {
      final settings = next.value;
      if (settings != null && !_dirty) _initFrom(settings);
    });
    final settingsAsync = ref.watch(settingsProvider);
    // position < 0 marks day-scoped "special" blocks (calendar edits) —
    // they belong to day overrides, not the weekly template, so the Rozvrh
    // list hides them (activating or globally editing one would silently
    // mutate the days referencing it).
    final blocks = [
      for (final b
          in ref.watch(timeBlocksProvider).value ?? const <TimeBlock>[])
        if (b.position >= 0) b,
    ];

    return AdminScaffold(
      title: 'Rozvrh',
      body: AsyncBody<ScheduleSettings?>(
        value: settingsAsync,
        onRetry: () => ref.invalidate(settingsProvider),
        builder: (settings) {
          if (settings == null) {
            return const Center(
              child: Text('Nastavení zatím není k dispozici.'),
            );
          }

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextField(
                controller: _laneCount,
                keyboardType: TextInputType.number,
                onChanged: _markDirty,
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
                        _dirty = true;
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
                onChanged: _markDirty,
                decoration: const InputDecoration(
                  labelText: 'Rezervace dopředu (dní)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _maxReservations,
                keyboardType: TextInputType.number,
                onChanged: _markDirty,
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
                          builder: (_) => GeneratorDialog(blocks: blocks),
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
          );
        },
      ),
    );
  }
}

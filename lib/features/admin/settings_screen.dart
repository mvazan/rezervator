import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';

/// Admin: edit the `schedule_settings` singleton (lane count, training days,
/// booking horizon, per-player reservation cap).
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
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

    setState(() => _saving = true);
    await tryAction(
      context,
      () => Api.updateSettings(
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

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(myProfileProvider).value;
    if (profile?.isAdmin != true) {
      return Scaffold(
        appBar: AppBar(title: const Text('Nastavení rozvrhu')),
        body: const Center(child: Text('Jen pro správce.')),
      );
    }

    final settingsAsync = ref.watch(settingsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Nastavení rozvrhu')),
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(friendlyDbError(e))),
        data: (settings) {
          if (settings == null) {
            return const Center(child: Text('Nastavení zatím není k dispozici.'));
          }
          if (!_initialized) _initFrom(settings);

          return ListView(
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
              Text('Tréninkové dny', style: Theme.of(context).textTheme.titleMedium),
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
            ],
          );
        },
      ),
    );
  }
}

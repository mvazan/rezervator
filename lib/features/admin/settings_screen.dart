import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import '../../domain/palette.dart';
import 'widgets/color_picker.dart';

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

  /// Fetches future live reservations and counts those that would fall
  /// outside the grid under [newLaneCount]/[newWeekdays]. This is a
  /// conservative upper bound: a day override with custom blocks may keep
  /// some of these visible even off the regular weekday set, but the admin
  /// still gets warned rather than silently orphaning anyone.
  Future<int> _countStranded(int newLaneCount, Set<int> newWeekdays) async {
    final reservations = await Api.futureLiveReservations(today());
    return reservations
        .where((r) =>
            r.lane > newLaneCount || !newWeekdays.contains(r.date.weekday))
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
    final shrinksGrid = current != null &&
        (laneCount < current.laneCount ||
            !_trainingWeekdays.containsAll(current.trainingWeekdays));
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
              const SizedBox(height: 32),
              const Divider(),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Kiosk: tmavý režim'),
                subtitle: const Text('Vypnuto = kiosková obrazovka světlá.'),
                value: settings.kioskDark,
                onChanged: (value) => tryAction(
                  context,
                  () => Api.setKioskDark(value),
                  errorText: friendlyDbError,
                ),
              ),
              const SizedBox(height: 16),
              const _ClubsSection(),
            ],
          );
        },
      ),
    );
  }
}

/// „Oddíly" (clubs) subsection of the settings screen: list + add/edit/
/// delete, each backed by [Api.upsertClub]/[Api.deleteClub].
class _ClubsSection extends ConsumerWidget {
  const _ClubsSection();

  Future<void> _addOrEdit(BuildContext context, WidgetRef ref, {Club? existing}) async {
    final result = await showDialog<(String, int)>(
      context: context,
      builder: (_) => _ClubDialog(existing: existing),
    );
    if (result == null || !context.mounted) return;
    final (name, colorIndex) = result;
    await tryAction(
      context,
      () => Api.upsertClub(id: existing?.id, name: name, colorIndex: colorIndex),
      success: 'Uloženo.',
      errorText: friendlyDbError,
    );
  }

  Future<void> _delete(BuildContext context, Club club) async {
    final confirmed = await confirmDialog(
      context,
      title: 'Smazat oddíl?',
      message: 'Opravdu smazat oddíl „${club.name}"? Hráči zůstanou bez oddílu.',
    );
    if (!confirmed || !context.mounted) return;
    await tryAction(
      context,
      () => Api.deleteClub(club.id),
      success: 'Smazáno.',
      errorText: friendlyDbError,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final clubs = ref.watch(clubsProvider).value ?? const <Club>[];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Oddíly', style: Theme.of(context).textTheme.titleMedium),
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: 'Přidat oddíl',
              onPressed: () => _addOrEdit(context, ref),
            ),
          ],
        ),
        if (clubs.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('Zatím žádné oddíly.'),
          )
        else
          for (final club in clubs)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: _ClubSwatch(colorIndex: club.colorIndex),
              title: Text(club.name),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => _addOrEdit(context, ref, existing: club),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _delete(context, club),
                  ),
                ],
              ),
            ),
      ],
    );
  }
}

/// Small circular color swatch shown next to a club's name in the list.
class _ClubSwatch extends StatelessWidget {
  const _ClubSwatch({required this.colorIndex});

  final int colorIndex;

  @override
  Widget build(BuildContext context) {
    final color = ClubColors.of(colorIndex, Brightness.dark)?.$1 ??
        Theme.of(context).colorScheme.surfaceContainerHighest;
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// Add/edit dialog for a club: name field + [ColorPickerGrid].
class _ClubDialog extends StatefulWidget {
  const _ClubDialog({this.existing});

  final Club? existing;

  @override
  State<_ClubDialog> createState() => _ClubDialogState();
}

class _ClubDialogState extends State<_ClubDialog> {
  final _name = TextEditingController();
  late int _colorIndex;

  @override
  void initState() {
    super.initState();
    _name.text = widget.existing?.name ?? '';
    _colorIndex = widget.existing?.colorIndex ?? -1;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) {
      snack(context, 'Vyplň název oddílu.');
      return;
    }
    Navigator.of(context).pop((name, _colorIndex));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? 'Přidat oddíl' : 'Upravit oddíl'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Název'),
            ),
            const SizedBox(height: 16),
            ColorPickerGrid(
              selected: _colorIndex,
              noneValue: -1,
              noneLabel: 'Žádná',
              onChanged: (index) => setState(() => _colorIndex = index),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Zrušit'),
        ),
        FilledButton(onPressed: _save, child: const Text('Uložit')),
      ],
    );
  }
}

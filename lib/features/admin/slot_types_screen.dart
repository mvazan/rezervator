import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import '../../domain/palette.dart';
import 'widgets/admin_body.dart';
import 'widgets/color_picker.dart';

/// Admin: the priority-slot types (šablóny) — name, color, and lane scope.
/// The built-in 'Zápas' kind can be renamed/recolored but never deleted (its
/// match fields and prep window are hardwired to it).
class SlotTypesScreen extends ConsumerWidget {
  const SlotTypesScreen({super.key});

  Future<void> _addOrEdit(
    BuildContext context, {
    PrioritySlotType? existing,
    required int laneCount,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _TypeDialog(existing: existing, laneCount: laneCount),
    );
  }

  Future<void> _delete(BuildContext context, PrioritySlotType type) async {
    final confirmed = await confirmDialog(
      context,
      title: 'Smazat typ?',
      message:
          'Opravdu smazat typ „${type.name}"? Nesmí ho používat žádná blokace.',
    );
    if (!confirmed || !context.mounted) return;
    await tryAction(
      context,
      () => Api.deleteSlotType(type.id),
      success: 'Smazáno.',
      errorText: friendlyDbError,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider).value;
    if (profile?.isAdmin != true) {
      return Scaffold(
        appBar: AppBar(title: const Text('Typy blokací')),
        body: const Center(child: Text('Jen pro správce.')),
      );
    }

    final types = ref.watch(slotTypesProvider).value ?? const [];
    final laneCount = ref.watch(settingsProvider).value?.laneCount ??
        ScheduleSettings.defaults.laneCount;

    return Scaffold(
      appBar: AppBar(title: const Text('Typy blokací')),
      body: AdminBody(
        child: types.isEmpty
            ? const Center(child: Text('Zatím žádné typy.'))
            : ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  for (final type in types)
                    ListTile(
                      leading: _TypeSwatch(colorIndex: type.colorIndex),
                      title: Text(type.name),
                      subtitle: Text(
                        [
                          type.lanes == null
                              ? 'celá kuželna'
                              : 'dráhy ${type.lanes!.join(', ')}',
                          if (type.isMatch) 'zápas (týmy + příprava drah)',
                        ].join(' · '),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () => _addOrEdit(context,
                                existing: type, laneCount: laneCount),
                          ),
                          if (!type.builtin)
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => _delete(context, type),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addOrEdit(context, laneCount: laneCount),
        icon: const Icon(Icons.add),
        label: const Text('Přidat typ'),
      ),
    );
  }
}

class _TypeSwatch extends StatelessWidget {
  const _TypeSwatch({required this.colorIndex});

  final int colorIndex;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = ClubColors.of(colorIndex, Brightness.dark)?.$1 ??
        scheme.errorContainer;
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

/// Add/edit dialog: name + color + whole-alley switch/lane chips. is_match
/// and builtin are server-guarded (column grants) and never editable here.
class _TypeDialog extends StatefulWidget {
  const _TypeDialog({this.existing, required this.laneCount});

  final PrioritySlotType? existing;
  final int laneCount;

  @override
  State<_TypeDialog> createState() => _TypeDialogState();
}

class _TypeDialogState extends State<_TypeDialog> {
  final _name = TextEditingController();
  late int _colorIndex;
  late bool _wholeAlley;
  final Set<int> _lanes = {};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _name.text = existing?.name ?? '';
    _colorIndex = existing?.colorIndex ?? -1;
    _wholeAlley = existing?.lanes == null;
    _lanes.addAll(existing?.lanes ?? const []);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      snack(context, 'Vyplň název.');
      return;
    }
    if (!_wholeAlley && _lanes.isEmpty) {
      snack(context, 'Vyber aspoň jednu dráhu.');
      return;
    }
    setState(() => _saving = true);
    final ok = await tryAction(
      context,
      () => Api.upsertSlotType(
        id: widget.existing?.id,
        name: name,
        colorIndex: _colorIndex,
        lanes: _wholeAlley ? null : (_lanes.toList()..sort()),
      ),
      success: 'Uloženo.',
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
      title: Text(widget.existing == null ? 'Přidat typ' : 'Upravit typ'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: widget.existing == null,
              decoration: const InputDecoration(labelText: 'Název'),
            ),
            const SizedBox(height: 16),
            ColorPickerGrid(
              selected: _colorIndex,
              noneValue: -1,
              noneLabel: 'Výchozí',
              onChanged: (index) => setState(() => _colorIndex = index),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Celá kuželna'),
              subtitle: const Text('Vypnuto = blokuje jen vybrané dráhy.'),
              value: _wholeAlley,
              onChanged: (v) => setState(() => _wholeAlley = v),
            ),
            if (!_wholeAlley)
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

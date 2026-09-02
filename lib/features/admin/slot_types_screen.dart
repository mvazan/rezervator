import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import 'widgets/admin_scaffold.dart';
import 'widgets/form_fields.dart';
import 'widgets/slot_type_dialog.dart';

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
    await showDialog<bool>(
      context: context,
      builder: (_) => SlotTypeDialog(existing: existing, laneCount: laneCount),
    );
  }

  Future<void> _delete(BuildContext context, PrioritySlotType type) =>
      confirmDelete(
        context,
        title: 'Smazat typ?',
        message:
            'Opravdu smazat typ „${type.name}"? Nesmí ho používat žádná blokace.',
        action: () => Api.deleteSlotType(type.id),
        success: 'Smazáno.',
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final laneCount = ref.watch(settingsProvider).value?.laneCount ??
        ScheduleSettings.defaults.laneCount;
    final scheme = Theme.of(context).colorScheme;

    return AdminScaffold(
      title: 'Typy blokací',
      body: AsyncBody(
        value: ref.watch(slotTypesProvider),
        onRetry: () => ref.invalidate(slotTypesProvider),
        builder: (types) => types.isEmpty
            ? const Center(child: Text('Zatím žádné typy.'))
            : ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  for (final type in types)
                    ListTile(
                      leading: ColorDot(
                        colorIndex: type.colorIndex,
                        fallback: scheme.errorContainer,
                      ),
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

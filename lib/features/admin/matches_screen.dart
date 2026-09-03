import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import 'widgets/admin_scaffold.dart';
import 'widgets/match_dialog.dart';

/// Admin: manage MATCHES. A match blocks the whole alley for its window;
/// its lane prep is the linked "Úklid před zápasem" child slot the server
/// maintains from the dialog's prep field (hidden here — it lives and dies
/// with the match). Other blockages moved to Výjimky dnů.
class MatchesScreen extends ConsumerWidget {
  const MatchesScreen({super.key});

  Future<void> _delete(BuildContext context, PrioritySlot slot) =>
      confirmDelete(
        context,
        title: 'Smazat zápas?',
        message: 'Opravdu smazat „${slot.title}" (${dayLabel(slot.date)})?',
        action: () => Api.deletePrioritySlot(slot.id),
      );

  static int _bySchedule(PrioritySlot a, PrioritySlot b) =>
      compareDayTime(a.date, a.startsAt, b.date, b.startsAt);

  Widget _tile(
      BuildContext context, PrioritySlot slot, List<PrioritySlotType> types) {
    return ListTile(
      title: Text(
        '${dayLabel(slot.date)} · '
        '${slot.startsAt.display()}–${slot.endsAt.display()} · '
        '${slot.title}',
      ),
      subtitle: switch ([
        if (slot.isAway) 'venku — neblokuje kuželnu',
        if (!slot.isAway && slot.prepMinutes > 0)
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
              builder: (_) => MatchDialog(existing: slot, types: types),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _delete(context, slot),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final slots = ref.watch(prioritySlotsProvider);
    final matches = [
      for (final s in slots)
        if (s.type.isMatch && s.parentId == null) s,
    ];
    // Chronological: upcoming first (today included), played ones collapsed
    // at the bottom, most recent first — like Výjimky dnů.
    final now = today();
    final upcoming = matches.where((s) => !s.date.isBefore(now)).toList()
      ..sort(_bySchedule);
    final past = matches.where((s) => s.date.isBefore(now)).toList()
      ..sort((a, b) => _bySchedule(b, a));
    // The slots themselves are a plain derived list; the types stream is
    // what can still be loading (or failing) — the dialog needs it too.
    final typesValue = ref.watch(slotTypesProvider);

    return AdminScaffold(
      title: 'Zápasy',
      body: AsyncBody(
        value: typesValue,
        onRetry: () => ref.invalidate(slotTypesProvider),
        builder: (types) => matches.isEmpty
            ? const Center(child: Text('Zatím žádné zápasy.'))
            : ListView(
                children: [
                  for (final slot in upcoming) _tile(context, slot, types),
                  if (past.isNotEmpty)
                    ExpansionTile(
                      title: Text('Odehrané (${past.length})'),
                      children: [
                        for (final slot in past) _tile(context, slot, types),
                      ],
                    ),
                ],
              ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showDialog<void>(
          context: context,
          builder: (_) => MatchDialog(types: typesValue.value ?? const []),
        ),
        icon: const Icon(Icons.add),
        label: const Text('Přidat zápas'),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import 'widgets/admin_scaffold.dart';
import 'widgets/club_dialog.dart';
import 'widgets/form_fields.dart';

/// Admin: manage clubs (oddíly) — list + add/edit/delete, each backed by
/// [Api.upsertClub]/[Api.deleteClub].
class ClubsScreen extends ConsumerWidget {
  const ClubsScreen({super.key});

  Future<void> _addOrEdit(BuildContext context, {Club? existing}) async {
    final result = await showDialog<(String, int)>(
      context: context,
      builder: (_) => ClubDialog(existing: existing),
    );
    if (result == null || !context.mounted) return;
    final (name, colorIndex) = result;
    await tryAction(
      context,
      () =>
          Api.upsertClub(id: existing?.id, name: name, colorIndex: colorIndex),
      success: 'Uloženo.',
      errorText: friendlyDbError,
    );
  }

  Future<void> _delete(BuildContext context, Club club) => confirmDelete(
        context,
        title: 'Smazat oddíl?',
        message:
            'Opravdu smazat oddíl „${club.name}"? Hráči zůstanou bez oddílu.',
        action: () => Api.deleteClub(club.id),
        success: 'Smazáno.',
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AdminScaffold(
      title: 'Oddíly',
      body: AsyncBody(
        value: ref.watch(clubsProvider),
        onRetry: () => ref.invalidate(clubsProvider),
        builder: (clubs) => clubs.isEmpty
            ? const Center(child: Text('Zatím žádné oddíly.'))
            : ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  for (final club in clubs)
                    ListTile(
                      leading: ColorDot(colorIndex: club.colorIndex),
                      title: Text(club.name),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () =>
                                _addOrEdit(context, existing: club),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _delete(context, club),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addOrEdit(context),
        icon: const Icon(Icons.add),
        label: const Text('Přidat oddíl'),
      ),
    );
  }
}

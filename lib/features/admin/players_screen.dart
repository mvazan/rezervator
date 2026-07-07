import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';

/// Admin: approve pending registrations, see the member list.
/// (Role management and richer admin tools arrive in Phase 2.)
class PlayersScreen extends ConsumerWidget {
  const PlayersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(profilesProvider).value ?? const <Profile>[];
    final pending =
        profiles.where((p) => p.status == ProfileStatus.pending).toList();
    final approved = profiles
        .where((p) =>
            p.status == ProfileStatus.approved && p.role != Role.kiosk)
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Hráči')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (pending.isNotEmpty) ...[
            Text('Čekají na schválení',
                style: Theme.of(context).textTheme.titleMedium),
            for (final p in pending)
              Card(
                child: ListTile(
                  title: Text(p.displayName),
                  subtitle: p.club.isEmpty ? null : Text(p.club),
                  trailing: FilledButton(
                    onPressed: () => tryAction(
                        context, () => Api.approvePlayer(p.id),
                        success: 'Schváleno.'),
                    child: const Text('Schválit'),
                  ),
                ),
              ),
            const SizedBox(height: 16),
          ],
          Text('Hráči (${approved.length})',
              style: Theme.of(context).textTheme.titleMedium),
          for (final p in approved)
            ListTile(
              title: Text(p.displayName),
              subtitle: p.club.isEmpty ? null : Text(p.club),
              trailing: p.role == Role.admin ? const Chip(label: Text('admin')) : null,
            ),
        ],
      ),
    );
  }
}

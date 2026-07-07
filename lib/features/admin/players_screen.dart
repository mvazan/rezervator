import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';

/// Admin: approve pending registrations, see the member list, manage roles.
class PlayersScreen extends ConsumerWidget {
  const PlayersScreen({super.key});

  Future<void> _setRole(BuildContext context, Profile p, Role role) =>
      tryAction(
        context,
        () => Api.setRole(p.id, role),
        success: 'Hotovo.',
        errorText: friendlyDbError,
      );

  Future<void> _makeKiosk(BuildContext context, Profile p) async {
    final confirmed = await confirmDialog(
      context,
      title: 'Nastavit jako kiosk?',
      message:
          'Účet se změní na kioskový — po přihlášení uvidí jen kioskovou obrazovku.',
      confirmLabel: 'Nastavit',
    );
    if (!confirmed || !context.mounted) return;
    await _setRole(context, p, Role.kiosk);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(profilesProvider).value ?? const <Profile>[];
    final pending =
        profiles.where((p) => p.status == ProfileStatus.pending).toList();
    final approved = profiles
        .where((p) =>
            p.status == ProfileStatus.approved && p.role != Role.kiosk)
        .toList();
    final kiosks = profiles.where((p) => p.role == Role.kiosk).toList();

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
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (p.role == Role.admin)
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: Chip(label: Text('admin')),
                    ),
                  PopupMenuButton<String>(
                    onSelected: (action) {
                      switch (action) {
                        case 'make_admin':
                          _setRole(context, p, Role.admin);
                        case 'remove_admin':
                          _setRole(context, p, Role.player);
                        case 'make_kiosk':
                          _makeKiosk(context, p);
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: p.role == Role.admin
                            ? 'remove_admin'
                            : 'make_admin',
                        child: Text(p.role == Role.admin
                            ? 'Odebrat správce'
                            : 'Udělat správcem'),
                      ),
                      const PopupMenuItem(
                        value: 'make_kiosk',
                        child: Text('Nastavit jako kiosk'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          if (kiosks.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Kiosk', style: Theme.of(context).textTheme.titleMedium),
            for (final p in kiosks)
              ListTile(
                title: Text(p.displayName),
                subtitle: p.club.isEmpty ? null : Text(p.club),
              ),
          ],
        ],
      ),
    );
  }
}

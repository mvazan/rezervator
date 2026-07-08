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

  Future<void> _returnToPlayer(BuildContext context, Profile p) => tryAction(
        context,
        () => Api.setRole(p.id, Role.player),
        success: 'Účet vrácen mezi hráče.',
        errorText: friendlyDbError,
      );

  Future<void> _editNick(BuildContext context, Profile p) async {
    final input = await promptText(
      context,
      title: 'Zkratka na tabuli',
      hint: 'Tom P.',
      initial: p.nick,
    );
    if (input == null || !context.mounted) return;
    await tryAction(
      context,
      () => Api.setNick(p.id, input),
      success: 'Uloženo.',
      errorText: friendlyDbError,
    );
  }

  Future<void> _setClub(BuildContext context, Profile p, String? clubId) =>
      tryAction(
        context,
        () => Api.setPlayerClub(p.id, clubId),
        success: 'Uloženo.',
        errorText: friendlyDbError,
      );

  /// "club · „nick“" (either half may be absent).
  String? _subtitle(Profile p) {
    final parts = [
      if (p.club.isNotEmpty) p.club,
      if (p.nick.isNotEmpty) '„${p.nick}“',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider).value;
    if (profile?.isAdmin != true) {
      return Scaffold(
        appBar: AppBar(title: const Text('Hráči')),
        body: const Center(child: Text('Jen pro správce.')),
      );
    }

    final profiles = ref.watch(profilesProvider).value ?? const <Profile>[];
    final clubs = ref.watch(clubsProvider).value ?? const <Club>[];
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
              subtitle: _subtitle(p) == null ? null : Text(_subtitle(p)!),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (p.role == Role.admin)
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: Chip(label: Text('admin')),
                    ),
                  DropdownButton<String?>(
                    value: clubs.any((c) => c.id == p.clubId)
                        ? p.clubId
                        : null,
                    onChanged: (clubId) => _setClub(context, p, clubId),
                    items: [
                      const DropdownMenuItem(
                          value: null, child: Text('Bez oddílu')),
                      for (final club in clubs)
                        DropdownMenuItem(
                            value: club.id, child: Text(club.name)),
                    ],
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
                        case 'edit_nick':
                          _editNick(context, p);
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
                      const PopupMenuItem(
                        value: 'edit_nick',
                        child: Text('Zkratka na tabuli…'),
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
                trailing: TextButton(
                  onPressed: () => _returnToPlayer(context, p),
                  child: const Text('Vrátit mezi hráče'),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

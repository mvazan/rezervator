import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/grouping.dart';
import '../../domain/models.dart';
import 'widgets/admin_scaffold.dart';
import 'widgets/merge_players_dialog.dart';
import 'widgets/no_account_player_dialog.dart';
import 'widgets/profile_picker_sheet.dart';

/// Admin: approve pending registrations, see the member list, manage roles,
/// and keep the hand-made "hráči bez účtu" (0022) — add or edit them, merge
/// one into the account its owner eventually registers, or delete it.
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

  /// Bottom sheet with a radio list of clubs; picking one saves immediately.
  Future<void> _pickClub(
    BuildContext context,
    Profile p,
    List<Club> clubs,
  ) async {
    final current = clubs.any((c) => c.id == p.clubId) ? p.clubId : null;
    final picked = await showModalBottomSheet<(String?,)>(
      context: context,
      builder: (sheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(
                'Oddíl — ${p.displayName}',
                style: Theme.of(sheet).textTheme.titleMedium,
              ),
            ),
            RadioGroup<String?>(
              groupValue: current,
              onChanged: (v) => Navigator.of(sheet).pop((v,)),
              child: Column(
                children: [
                  const RadioListTile<String?>(
                    value: null,
                    title: Text('Bez oddílu'),
                  ),
                  for (final club in clubs)
                    RadioListTile<String?>(
                      value: club.id,
                      title: Text(club.name),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (picked == null || !context.mounted) return;
    if (picked.$1 != current) await _setClub(context, p, picked.$1);
  }

  /// Add (no [existing]) or edit a hráč bez účtu. The kiosk roster is a
  /// view that cannot stream, so it re-reads itself after a save.
  Future<void> _addOrEditPlaceholder(
    BuildContext context,
    WidgetRef ref,
    List<Club> clubs, {
    Profile? existing,
  }) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => NoAccountPlayerDialog(existing: existing, clubs: clubs),
    );
    if (saved == true && context.mounted) ref.invalidate(playersProvider);
  }

  Future<void> _deletePlaceholder(
    BuildContext context,
    WidgetRef ref,
    Profile p,
  ) async {
    final ok = await confirmDelete(
      context,
      title: 'Smazat hráče?',
      message: 'Opravdu smazat hráče bez účtu „${p.displayName}“?',
      action: () => Api.deletePlaceholderPlayer(p.id),
      success: 'Smazáno.',
    );
    if (ok && context.mounted) ref.invalidate(playersProvider);
  }

  /// [placeholder]'s reservations move into [target] (a pending registrant
  /// or an approved member) — see [MergePlayersDialog].
  Future<void> _merge(
    BuildContext context,
    WidgetRef ref, {
    required Profile placeholder,
    required Profile target,
    required List<Club> clubs,
  }) async {
    final merged = await showDialog<bool>(
      context: context,
      builder: (_) => MergePlayersDialog(
        placeholder: placeholder,
        target: target,
        clubs: clubs,
      ),
    );
    if (merged == true && context.mounted) ref.invalidate(playersProvider);
  }

  /// Pending card: which hand-made row is this registrant?
  Future<void> _mergePendingWithPlaceholder(
    BuildContext context,
    WidgetRef ref,
    Profile pending,
    List<Profile> profiles,
    List<Club> clubs,
  ) async {
    final placeholders = profiles.where((p) => !p.hasAccount).toList();
    if (placeholders.isEmpty) {
      snack(context, 'Žádný hráč bez účtu k sloučení.');
      return;
    }
    final picked = await showProfilePicker(
      context,
      title: 'Sloučit s hráčem bez účtu — ${pending.displayName}',
      candidates: placeholders,
      clubs: clubs,
    );
    if (picked == null || !context.mounted) return;
    await _merge(context, ref,
        placeholder: picked, target: pending, clubs: clubs);
  }

  /// Placeholder row: whose account is this? Approved members and pending
  /// registrants alike; a kiosk account is never a person.
  Future<void> _mergePlaceholderIntoAccount(
    BuildContext context,
    WidgetRef ref,
    Profile placeholder,
    List<Profile> profiles,
    List<Club> clubs,
  ) async {
    final accounts =
        profiles.where((p) => p.hasAccount && p.role != Role.kiosk).toList();
    final picked = await showProfilePicker(
      context,
      title: 'Sloučit do účtu — ${placeholder.displayName}',
      candidates: accounts,
      clubs: clubs,
    );
    if (picked == null || !context.mounted) return;
    await _merge(context, ref,
        placeholder: placeholder, target: picked, clubs: clubs);
  }

  /// Club name for rows outside the club sections (pending, kiosk).
  Widget? _clubSubtitle(Profile p, List<Club> clubs) {
    final name = clubNameOf(p.clubId, clubs);
    return name.isEmpty ? null : Text(name);
  }

  /// "bez účtu · správce · „nick“" (any part may be absent). The club is
  /// shown by the section header, so it stays out of the row.
  String? _subtitle(Profile p) {
    final parts = [
      if (!p.hasAccount) 'bez účtu',
      if (p.role == Role.admin) 'správce',
      if (p.nick.isNotEmpty) '„${p.nick}“',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// The member menu: roles, kiosk, club, nick.
  List<PopupMenuEntry<String>> _memberMenu(Profile p) => [
        const PopupMenuItem(value: 'club', child: Text('Oddíl…')),
        PopupMenuItem(
          value: p.role == Role.admin ? 'remove_admin' : 'make_admin',
          child: Text(
            p.role == Role.admin ? 'Odebrat správce' : 'Udělat správcem',
          ),
        ),
        const PopupMenuItem(
          value: 'make_kiosk',
          child: Text('Nastavit jako kiosk'),
        ),
        const PopupMenuItem(
          value: 'edit_nick',
          child: Text('Zkratka na tabuli…'),
        ),
      ];

  /// A hráč bez účtu is never an admin or a kiosk; instead it is edited
  /// whole, merged into an account, or deleted.
  List<PopupMenuEntry<String>> _placeholderMenu() => const [
        PopupMenuItem(value: 'edit', child: Text('Upravit…')),
        PopupMenuItem(value: 'club', child: Text('Oddíl…')),
        PopupMenuItem(value: 'edit_nick', child: Text('Zkratka na tabuli…')),
        PopupMenuItem(value: 'merge', child: Text('Sloučit do účtu…')),
        PopupMenuItem(value: 'delete', child: Text('Smazat')),
      ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The roster drives the loading/error state; the clubs only name the
    // sections, so a not-yet-streamed club list just means "Bez oddílu".
    final clubs = ref.watch(clubsProvider).value ?? const <Club>[];

    return AdminScaffold(
      title: 'Hráči',
      body: AsyncBody(
        value: ref.watch(profilesProvider),
        onRetry: () => ref.invalidate(profilesProvider),
        builder: (roster) {
          // A visiting superadmin (switched into this kuželna, 0015) is
          // inspecting, not playing — keep them out of the member lists.
          final profiles = [
            for (final p in roster)
              if (!p.isVisiting) p,
          ];
          final pending = profiles
              .where((p) => p.status == ProfileStatus.pending)
              .toList();
          final approved = profiles
              .where(
                (p) =>
                    p.status == ProfileStatus.approved && p.role != Role.kiosk,
              )
              .toList();
          final kiosks = profiles.where((p) => p.role == Role.kiosk).toList();
          final sections = playersByClub(approved, clubs);

          return ListView(
            // Room under the last row for the extended FAB.
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
            children: [
              if (pending.isNotEmpty) ...[
                Text(
                  'Čekají na schválení',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                for (final p in pending)
                  Card(
                    child: ListTile(
                      title: Text(p.displayName),
                      subtitle: _clubSubtitle(p, clubs),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          FilledButton(
                            onPressed: () => tryAction(
                              context,
                              () => Api.approvePlayer(p.id),
                              success: 'Schváleno.',
                            ),
                            child: const Text('Schválit'),
                          ),
                          PopupMenuButton<String>(
                            onSelected: (_) => _mergePendingWithPlaceholder(
                              context,
                              ref,
                              p,
                              profiles,
                              clubs,
                            ),
                            itemBuilder: (context) => const [
                              PopupMenuItem(
                                value: 'merge',
                                child: Text('Sloučit s hráčem bez účtu…'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
              ],
              Text(
                'Hráči (${approved.length})',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              for (final (club, members) in sections) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 12, bottom: 2),
                  child: Text(
                    '${club ?? 'Bez oddílu'} (${members.length})',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                for (final p in members)
                  ListTile(
                    title: Text(p.displayName),
                    subtitle:
                        _subtitle(p) == null ? null : Text(_subtitle(p)!),
                    trailing: PopupMenuButton<String>(
                      onSelected: (action) {
                        switch (action) {
                          case 'edit':
                            _addOrEditPlaceholder(context, ref, clubs,
                                existing: p);
                          case 'club':
                            _pickClub(context, p, clubs);
                          case 'make_admin':
                            _setRole(context, p, Role.admin);
                          case 'remove_admin':
                            _setRole(context, p, Role.player);
                          case 'make_kiosk':
                            _makeKiosk(context, p);
                          case 'edit_nick':
                            _editNick(context, p);
                          case 'merge':
                            _mergePlaceholderIntoAccount(
                                context, ref, p, profiles, clubs);
                          case 'delete':
                            _deletePlaceholder(context, ref, p);
                        }
                      },
                      itemBuilder: (context) =>
                          p.hasAccount ? _memberMenu(p) : _placeholderMenu(),
                    ),
                  ),
              ],
              if (kiosks.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('Kiosk', style: Theme.of(context).textTheme.titleMedium),
                for (final p in kiosks)
                  ListTile(
                    title: Text(p.displayName),
                    subtitle: _clubSubtitle(p, clubs),
                    trailing: TextButton(
                      onPressed: () => _returnToPlayer(context, p),
                      child: const Text('Vrátit mezi hráče'),
                    ),
                  ),
              ],
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addOrEditPlaceholder(context, ref, clubs),
        icon: const Icon(Icons.person_add_alt_1_outlined),
        label: const Text('Přidat hráče bez účtu'),
      ),
    );
  }
}

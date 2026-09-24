import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import 'widgets/admin_scaffold.dart';
import 'widgets/club_dialog.dart';
import 'widgets/federation_card.dart';
import 'widgets/form_fields.dart';
import 'widgets/team_dialog.dart';

/// Admin: manage clubs (oddíly) — list + add/edit/delete, each backed by
/// [Api.upsertClub]/[Api.deleteClub] — and, above them, the ČKA results
/// service (0045): its own sync settings plus the teams it discovered,
/// grouped under the club each is assigned to.
class ClubsScreen extends ConsumerWidget {
  const ClubsScreen({
    super.key,
    this.saveFederation = _defaultSaveFederation,
    this.discoverTeams = Api.requestFederationDiscovery,
    this.syncNow = Api.requestFederationSync,
    this.updateTeam = _defaultUpdateTeam,
  });

  /// Injectable so widget tests can drive the ČKA card and team dialog
  /// without the backend — same style as [PublicOverviewScreen.save].
  final Future<void> Function(String venueSlug, bool enabled) saveFederation;
  final Future<void> Function() discoverTeams;
  final Future<void> Function() syncNow;
  final Future<void> Function(Team team,
      {required String name, String? clubId, required bool active}) updateTeam;

  static Future<void> _defaultSaveFederation(String venueSlug, bool enabled) =>
      Api.setFederationSync(venueSlug: venueSlug, enabled: enabled);

  static Future<void> _defaultUpdateTeam(Team team,
          {required String name, String? clubId, required bool active}) =>
      Api.updateTeam(id: team.id, name: name, clubId: clubId, active: active);

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

  Future<void> _toggleTeamActive(
          BuildContext context, Team team, bool active) =>
      tryAction(
        context,
        () => updateTeam(team,
            name: team.name, clubId: team.clubId, active: active),
        errorText: friendlyDbError,
      );

  Future<void> _editTeam(
      BuildContext context, Team team, List<Club> clubs) async {
    final result = await showDialog<(String, String?, bool)>(
      context: context,
      builder: (_) => TeamDialog(team: team, clubs: clubs),
    );
    if (result == null || !context.mounted) return;
    final (name, clubId, active) = result;
    await tryAction(
      context,
      () => updateTeam(team, name: name, clubId: clubId, active: active),
      success: 'Uloženo.',
      errorText: friendlyDbError,
    );
  }

  Widget _teamTile(BuildContext context, Team team, List<Club> clubs) {
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 56, right: 16),
      dense: true,
      title: Text(
        team.name,
        style: team.active
            ? null
            : TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      subtitle: Text(
        team.competitionName.isEmpty ? 'bez soutěže' : team.competitionName,
      ),
      trailing: Switch(
        value: team.active,
        onChanged: (active) => _toggleTeamActive(context, team, active),
      ),
      onTap: () => _editTeam(context, team, clubs),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AdminScaffold(
      title: 'Oddíly',
      body: AsyncBody(
        value: ref.watch(clubsProvider),
        onRetry: () => ref
          ..invalidate(clubsProvider)
          ..invalidate(teamsProvider),
        builder: (clubs) {
          final loadedTeams = ref.watch(teamsProvider);
          final teams = loadedTeams.value ?? const <Team>[];
          final unassigned = [
            for (final team in teams)
              if (team.clubId == null ||
                  !clubs.any((c) => c.id == team.clubId))
                team,
          ];
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              FederationCard(
                saveFederation: saveFederation,
                discoverTeams: discoverTeams,
                syncNow: syncNow,
              ),
              const SizedBox(height: 12),
              if (loadedTeams.hasError && !loadedTeams.hasValue)
                ListTile(
                  title: Text(
                    friendlyDbError(loadedTeams.error!),
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error),
                  ),
                  trailing: TextButton(
                    onPressed: () => ref.invalidate(teamsProvider),
                    child: const Text('Zkusit znovu'),
                  ),
                ),
              if (clubs.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text('Zatím žádné oddíly.'),
                )
              else
                for (final club in clubs) ...[
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
                  for (final team in teams)
                    if (team.clubId == club.id) _teamTile(context, team, clubs),
                ],
              if (unassigned.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(
                    'Nezařazené týmy',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                for (final team in unassigned) _teamTile(context, team, clubs),
              ],
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addOrEdit(context),
        icon: const Icon(Icons.add),
        label: const Text('Přidat oddíl'),
      ),
    );
  }
}

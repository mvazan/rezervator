import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers.dart';
import '../../../domain/models.dart';
import 'team_picker_sheet.dart';

/// Which teams' matches the player sees in Moje tréninky (0029). Its own
/// list — the calendar card keeps a separate one for the Google sync.
class MyTeamsCard extends StatelessWidget {
  const MyTeamsCard({
    super.key,
    required this.profile,
    required this.setFollowedTeams,
  });

  final Profile profile;
  final Future<void> Function(List<String> teams) setFollowedTeams;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: const Icon(Icons.sports_outlined),
            title: const Text('Moje týmy'),
            subtitle: Text(matchTeamsSummary(profile.followedTeams)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonal(
                onPressed: () => showTeamPickerSheet(
                  context,
                  title: 'Moje týmy',
                  hint: 'Jejich domácí i venkovní zápasy uvidíš v Moje '
                      'tréninky. Do Google kalendáře jdou zápasy podle '
                      'vlastního výběru u kalendáře.',
                  chosenOf: (WidgetRef sheetRef) =>
                      sheetRef.watch(myProfileProvider).value?.followedTeams ??
                      const [],
                  onChanged: setFollowedTeams,
                ),
                child: const Text('Vybrat týmy…'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

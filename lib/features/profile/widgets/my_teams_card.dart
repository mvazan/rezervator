import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/providers.dart';
import '../../../domain/models.dart';
import 'team_picker_sheet.dart';

/// Which teams' matches the player sees in Můj přehled (0029), and each
/// one's shared colour (0036, `team_colors`) — the SAME colour shown there
/// and on the Google Calendar event, wherever it was last set. Its own team
/// LIST is separate from the calendar card's; the colour registry is not.
class MyTeamsCard extends StatelessWidget {
  const MyTeamsCard({
    super.key,
    required this.profile,
    required this.setFollowedTeams,
    required this.setTeamColors,
  });

  final Profile profile;
  final Future<void> Function(List<String> teams) setFollowedTeams;
  final Future<void> Function(Map<String, int?> colors) setTeamColors;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: const Icon(Icons.groups_outlined),
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
                  hint: 'Jejich domácí i venkovní zápasy uvidíš v Můj '
                      'přehled. Do Google kalendáře jdou zápasy podle '
                      'vlastního výběru u kalendáře.',
                  chosenOf: (WidgetRef sheetRef) =>
                      sheetRef.watch(myProfileProvider).value?.followedTeams ??
                      const [],
                  onChanged: setFollowedTeams,
                  colorsOf: (WidgetRef sheetRef) =>
                      sheetRef.watch(myTeamColorsProvider).value ?? const {},
                  onColorsChanged: setTeamColors,
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

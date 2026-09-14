import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../config.dart';
import '../../../data/providers.dart';
import '../../../domain/models.dart';
import '../match_exceptions_screen.dart';
import 'my_teams_sheet.dart';

/// The one place teams are set up: which teams' matches show in Můj přehled
/// (0029, `profiles.followed_teams`), which go to Google Calendar (0032,
/// `calendar_teams`) and what colour each wears in both (0036,
/// `team_colors`). The sheet behind "Vybrat týmy…" holds all three — the
/// Google card used to hold the middle one, in a row of its own, and nobody
/// found it there.
class MyTeamsCard extends ConsumerWidget {
  const MyTeamsCard({
    super.key,
    required this.profile,
    required this.setFollowedTeams,
    required this.setCalendarTeams,
    required this.setTeamColors,
  });

  final Profile profile;
  final Future<void> Function(List<String> teams) setFollowedTeams;
  final Future<void> Function(List<CalendarTeam> teams) setCalendarTeams;
  final Future<void> Function(Map<String, int?> colors) setTeamColors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final link = ref.watch(myCalendarLinkProvider).value ?? CalendarLink.none;
    // The same gate the sheet uses for its Kalendář column, and the card
    // for the Google card itself: without one, there is only the overview
    // to sum up.
    final hasCalendar = ref.watch(calendarAvailableProvider) &&
        !AppConfig.isDemoAccount(profile.email) &&
        link.isLinked;
    final exceptions =
        ref.watch(myMatchExceptionsProvider).value ?? const <String>{};
    final routed = hasCalendar
        ? ref.watch(myCalendarTeamsProvider).value ?? const <CalendarTeam>[]
        : const <CalendarTeam>[];
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: const Icon(Icons.groups_outlined),
            title: const Text('Moje týmy'),
            isThreeLine: hasCalendar,
            subtitle: Text(
              hasCalendar
                  ? 'Přehled: ${matchTeamsSummary(profile.followedTeams)}\n'
                      'Kalendář: '
                      '${matchTeamsSummary([for (final t in routed) t.team])}'
                  : matchTeamsSummary(profile.followedTeams),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonal(
                onPressed: () => showMyTeamsSheet(
                  context,
                  onFollowedChanged: setFollowedTeams,
                  onCalendarChanged: setCalendarTeams,
                  onColorsChanged: setTeamColors,
                ),
                child: const Text('Vybrat týmy…'),
              ),
            ),
          ),
          // The rare other half of "whose matches are mine": a single match
          // played for a team one does not follow (0039). Its own screen —
          // it is seldom used and the list it needs is the whole schedule.
          ListTile(
            leading: const Icon(Icons.star_outline),
            title: const Text('Výjimky'),
            subtitle: Text(
              exceptions.isEmpty
                  ? 'Zápasy, které hraješ za jiný tým.'
                  : '${exceptions.length} zápasů navíc',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const MatchExceptionsScreen()),
            ),
          ),
        ],
      ),
    );
  }
}

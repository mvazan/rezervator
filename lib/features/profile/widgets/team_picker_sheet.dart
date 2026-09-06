import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/collation.dart';

/// The checkbox sheet both the calendar card and the Moje týmy card open:
/// every team the schedule knows (home team of a home match, away team of
/// an away match) plus whatever is already chosen, so a team that vanished
/// from the schedule can still be unticked. Each toggle is saved at once by
/// [onChanged]; the chosen list is re-read through [chosenOf] on every
/// build, so the sheet follows the same stream the card watches.
Future<void> showTeamPickerSheet(
  BuildContext context, {
  required String title,
  required String hint,
  required List<String> Function(WidgetRef ref) chosenOf,
  required Future<void> Function(List<String> teams) onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) => Consumer(
      builder: (context, ref, _) {
        final chosen = chosenOf(ref);
        final teams = {...ref.watch(ourTeamsProvider), ...chosen}.toList()
          ..sort(compareCzech);
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child:
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(hint),
              ),
              if (teams.isEmpty)
                const ListTile(
                  leading: Icon(Icons.sports_outlined),
                  title: Text('Zatím žádné zápasy v rozvrhu'),
                ),
              for (final team in teams)
                CheckboxListTile(
                  value: chosen.contains(team),
                  title: Text(team),
                  onChanged: (on) => tryAction(
                    context,
                    () => onChanged([
                      for (final t in chosen)
                        if (t != team) t,
                      if (on == true) team,
                    ]),
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    ),
  );
}

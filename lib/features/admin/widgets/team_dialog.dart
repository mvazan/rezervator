/// Správa → Oddíly: the team edit dialog — rename the app's copy of a
/// federation team, reassign its oddíl, or turn off match downloads for it.
/// See task-5-brief.md.
library;

import 'package:flutter/material.dart';

import '../../../domain/limits.dart';
import '../../../domain/models.dart';
import 'form_dialog.dart';

/// Pops `(name, clubId, active)`; null on cancel.
class TeamDialog extends StatefulWidget {
  const TeamDialog({super.key, required this.team, required this.clubs});

  final Team team;

  /// Czech-sorted, as the caller already holds it (clubsProvider).
  final List<Club> clubs;

  @override
  State<TeamDialog> createState() => _TeamDialogState();
}

class _TeamDialogState extends State<TeamDialog> {
  final _name = TextEditingController();
  String? _clubId;
  bool _active = true;

  @override
  void initState() {
    super.initState();
    final team = widget.team;
    _name.text = team.name;
    // A club deleted since the team was synced reads as "Bez oddílu" — the
    // dropdown has no item for it.
    _clubId = widget.clubs.any((c) => c.id == team.clubId) ? team.clubId : null;
    _active = team.active;
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<(String, String?, bool)?> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return null;
    return (name, _clubId, _active);
  }

  @override
  Widget build(BuildContext context) {
    final team = widget.team;
    return FormDialog<(String, String?, bool)>(
      title: 'Tým',
      onSave: _save,
      saveEnabled: _name.text.trim().isNotEmpty,
      children: [
        TextField(
          controller: _name,
          autofocus: true,
          maxLength: Limits.teamNameLength,
          decoration: const InputDecoration(
            labelText: 'Název v appce',
            helperText: 'Podle názvu se řídí výběr týmů hráčů. Změna platí '
                'od další synchronizace.',
            counterText: '',
          ),
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<String?>(
          initialValue: _clubId,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Oddíl'),
          items: [
            const DropdownMenuItem(value: null, child: Text('Bez oddílu')),
            for (final club in widget.clubs)
              DropdownMenuItem(value: club.id, child: Text(club.name)),
          ],
          onChanged: (id) => setState(() => _clubId = id),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Stahovat zápasy'),
          value: _active,
          onChanged: (v) => setState(() => _active = v),
        ),
        const SizedBox(height: 8),
        Text(
          'Na webu: ${team.siteName} · ${team.competitionName}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

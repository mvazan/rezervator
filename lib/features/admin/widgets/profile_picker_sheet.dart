import 'package:flutter/material.dart';

import '../../../domain/models.dart';

/// A searchable modal sheet over [candidates]; resolves to the tapped
/// profile, or null when dismissed. Each row names the person and, under
/// it, whatever tells them apart: pending status, "bez účtu", the board
/// nick, the club.
Future<Profile?> showProfilePicker(
  BuildContext context, {
  required String title,
  required List<Profile> candidates,
  required List<Club> clubs,
}) =>
    showModalBottomSheet<Profile>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ProfilePickerSheet(
        title: title,
        candidates: candidates,
        clubs: clubs,
      ),
    );

class _ProfilePickerSheet extends StatefulWidget {
  const _ProfilePickerSheet({
    required this.title,
    required this.candidates,
    required this.clubs,
  });

  final String title;
  final List<Profile> candidates;
  final List<Club> clubs;

  @override
  State<_ProfilePickerSheet> createState() => _ProfilePickerSheetState();
}

class _ProfilePickerSheetState extends State<_ProfilePickerSheet> {
  final _query = TextEditingController();

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  /// Case-insensitive substring match on the name or the nick.
  List<Profile> get _matches {
    final q = _query.text.trim().toLowerCase();
    if (q.isEmpty) return widget.candidates;
    return [
      for (final p in widget.candidates)
        if (p.displayName.toLowerCase().contains(q) ||
            p.nick.toLowerCase().contains(q))
          p,
    ];
  }

  Widget? _subtitle(Profile p) {
    final club = clubNameOf(p.clubId, widget.clubs);
    final parts = [
      if (p.status == ProfileStatus.pending) 'čeká na schválení',
      if (!p.hasAccount) 'bez účtu',
      if (p.nick.isNotEmpty) '„${p.nick}“',
      if (club.isNotEmpty) club,
    ];
    return parts.isEmpty ? null : Text(parts.join(' · '));
  }

  @override
  Widget build(BuildContext context) {
    final matches = _matches;
    return Padding(
      // Keeps the list above the keyboard while searching.
      padding:
          EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  widget.title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: _query,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Hledat jméno',
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: matches.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('Nikdo neodpovídá hledání.'),
                      )
                    : ListView(
                        shrinkWrap: true,
                        children: [
                          for (final p in matches)
                            ListTile(
                              title: Text(p.displayName),
                              subtitle: _subtitle(p),
                              onTap: () => Navigator.of(context).pop(p),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

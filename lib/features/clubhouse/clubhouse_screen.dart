/// Klubovna — the third home tab: a hub of team-facing screens (results,
/// venues), the same [HubMenu] Správa kuželny uses.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/hub_menu.dart';
import '../schedule/widgets/home_header.dart';

/// A stand-in for a hub entry whose real screen (Task 3/5) does not exist
/// yet — just enough to prove the entry and the tap wiring. This is the
/// only place that names Výsledky's and Kuželny's eventual targets, so
/// swapping them in later touches one list, not the whole screen.
Widget _placeholder(String label) =>
    Scaffold(appBar: AppBar(title: Text(label)));

class ClubhouseScreen extends ConsumerWidget {
  const ClubhouseScreen({super.key, this.trailing = const []});

  /// The shell's profile/admin icons — parked here so they keep their exact
  /// place when the tabs switch (see [HomeHeader]).
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void open(BuildContext context, String label) => Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => _placeholder(label)));

    return Column(
      children: [
        HomeHeader(trailing: trailing),
        Expanded(
          child: HubMenu(
            entries: [
              (
                label: 'Výsledky',
                icon: Icons.scoreboard_outlined,
                subtitle: 'Zápasy a výsledky našich týmů',
                onTap: () => open(context, 'Výsledky'),
              ),
              (
                label: 'Kuželny',
                icon: Icons.location_on_outlined,
                subtitle: 'Kontakty a vybavení kuželen',
                onTap: () => open(context, 'Kuželny'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

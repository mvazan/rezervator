/// Klubovna — the third home tab: a hub of team-facing screens (results,
/// venues, contacts), the same [HubMenu] Správa kuželny uses.
library;

import 'package:flutter/material.dart';

import '../../core/hub_menu.dart';
import '../schedule/widgets/home_header.dart';
import 'contacts_screen.dart';
import 'results_screen.dart';
import 'venues_screen.dart';

class ClubhouseScreen extends StatelessWidget {
  const ClubhouseScreen({super.key, this.trailing = const []});

  /// The shell's profile/admin icons — parked here so they keep their exact
  /// place when the tabs switch (see [HomeHeader]).
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
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
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ResultsScreen()),
                ),
              ),
              (
                label: 'Kuželny',
                icon: Icons.location_on_outlined,
                subtitle: 'Adresy a vybavení kuželen',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const VenuesScreen()),
                ),
              ),
              (
                label: 'Kontakty',
                icon: Icons.contacts_outlined,
                subtitle: 'Hráči kuželny — e-mail a telefon',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ContactsScreen()),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

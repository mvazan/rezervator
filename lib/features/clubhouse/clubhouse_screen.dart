/// Klubovna — the third home tab: a hub of team-facing screens (contacts,
/// venues, the notice board, canteen duties, results, messages — in Czech
/// alphabetical order), the same [HubMenu] Správa kuželny uses.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/hub_menu.dart';
import '../../data/providers.dart';
import '../../domain/collation.dart';
import '../schedule/widgets/home_header.dart';
import 'contacts_screen.dart';
import 'duties_screen.dart';
import 'messages_screen.dart';
import 'notice_board_screen.dart';
import 'results_screen.dart';
import 'venues_screen.dart';

class ClubhouseScreen extends ConsumerWidget {
  const ClubhouseScreen({super.key, this.trailing = const []});

  /// The shell's profile/admin icons — parked here so they keep their exact
  /// place when the tabs switch (see [HomeHeader]).
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Unread notices and messages — Nástěnka's and Zprávy's badges (0
    // shows none).
    final unreadNotices = ref.watch(
      unreadCountsProvider.select((c) => c.notices),
    );
    final unreadMessages = ref.watch(
      unreadCountsProvider.select((c) => c.messages),
    );
    return Column(
      children: [
        HomeHeader(trailing: trailing),
        Expanded(
          child: HubMenu(
            // Czech alphabetical, so a new entry finds its own place.
            entries: [
              (
                label: 'Výsledky',
                icon: Icons.scoreboard_outlined,
                subtitle: 'Zápasy a výsledky našich týmů',
                badge: null,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ResultsScreen()),
                ),
              ),
              (
                label: 'Kuželny',
                icon: Icons.location_on_outlined,
                subtitle: 'Adresy a vybavení kuželen',
                badge: null,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const VenuesScreen()),
                ),
              ),
              (
                label: 'Služby',
                icon: Icons.local_cafe_outlined,
                subtitle: 'Kdo slouží na kantýně',
                badge: null,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const DutiesScreen()),
                ),
              ),
              (
                label: 'Kontakty',
                icon: Icons.contacts_outlined,
                subtitle: 'Hráči kuželny — e-mail a telefon',
                badge: null,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ContactsScreen()),
                ),
              ),
              (
                label: 'Nástěnka',
                icon: Icons.campaign_outlined,
                subtitle: 'Oznámení správce',
                badge: unreadNotices,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const NoticeBoardScreen()),
                ),
              ),
              (
                label: 'Zprávy',
                icon: Icons.forum_outlined,
                subtitle: 'Zprávy pro tebe a od tebe',
                badge: unreadMessages,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const MessagesScreen()),
                ),
              ),
            ]..sort((a, b) => compareCzech(a.label, b.label)),
          ),
        ),
      ],
    );
  }
}

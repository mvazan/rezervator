import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import 'blocks_screen.dart';
import 'matches_screen.dart';
import 'overrides_screen.dart';
import 'players_screen.dart';
import 'rentals_screen.dart';
import 'report_screen.dart';
import 'settings_screen.dart';

/// Admin hub: entry point to every admin-only screen.
class AdminScreen extends ConsumerWidget {
  const AdminScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider).value;
    if (profile?.isAdmin != true) {
      return Scaffold(
        appBar: AppBar(title: const Text('Správa kuželny')),
        body: const Center(child: Text('Jen pro správce.')),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Správa kuželny')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.group_outlined),
            title: const Text('Hráči'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PlayersScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.fact_check_outlined),
            title: const Text('Docházka'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ReportScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('Nastavení rozvrhu'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.schedule),
            title: const Text('Tréninkové bloky'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const BlocksScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.event_busy),
            title: const Text('Výjimky dnů'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const OverridesScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.emoji_events_outlined),
            title: const Text('Zápasy'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const MatchesScreen()),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.storefront_outlined),
            title: const Text('Pronájmy'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const RentalsScreen()),
            ),
          ),
        ],
      ),
    );
  }
}

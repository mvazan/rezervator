import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../admin/players_screen.dart';
import 'week_screen.dart';

class HomeShell extends ConsumerWidget {
  const HomeShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider).value;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Rezervátor'),
        actions: [
          if (profile?.isAdmin ?? false)
            IconButton(
              icon: const Icon(Icons.group_outlined),
              tooltip: 'Hráči',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PlayersScreen()),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Odhlásit se',
            onPressed: Api.signOut,
          ),
        ],
      ),
      body: const WeekScreen(),
    );
  }
}

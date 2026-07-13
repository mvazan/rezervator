import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../admin/admin_screen.dart';
import '../profile/profile_screen.dart';
import 'week_screen.dart';

class HomeShell extends ConsumerWidget {
  const HomeShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider).value;
    final offline = ref.watch(offlineProvider).value ?? false;
    // No AppBar at all: WeekScreen's week-navigation row doubles as the top
    // bar — title (where width allows), week arrows and these icons share
    // ONE line.
    final actions = [
      if (profile?.isAdmin ?? false)
        IconButton(
          icon: const Icon(Icons.admin_panel_settings_outlined),
          tooltip: 'Správa',
          visualDensity: VisualDensity.compact,
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AdminScreen()),
          ),
        ),
      IconButton(
        icon: const Icon(Icons.account_circle_outlined),
        tooltip: 'Můj profil',
        visualDensity: VisualDensity.compact,
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ProfileScreen()),
        ),
      ),
    ];
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            if (offline)
              MaterialBanner(
                content: const Text('Offline — poslední známý stav'),
                leading: const Icon(Icons.cloud_off_outlined),
                actions: const [SizedBox.shrink()],
              ),
            Expanded(child: WeekScreen(trailing: actions)),
          ],
        ),
      ),
    );
  }
}

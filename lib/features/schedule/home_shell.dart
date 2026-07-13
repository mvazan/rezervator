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
    // Landscape (the week calendar) is height-starved: the AppBar goes away
    // and its action icons move onto WeekScreen's own week-navigation row —
    // one shared line instead of two.
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final actions = [
      if (profile?.isAdmin ?? false)
        IconButton(
          icon: const Icon(Icons.admin_panel_settings_outlined),
          tooltip: 'Správa',
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const AdminScreen()),
          ),
        ),
      IconButton(
        icon: const Icon(Icons.account_circle_outlined),
        tooltip: 'Můj profil',
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ProfileScreen()),
        ),
      ),
    ];
    return Scaffold(
      appBar: landscape
          ? null
          : AppBar(title: const Text('Rezervátor'), actions: actions),
      body: SafeArea(
        child: Column(
          children: [
            if (offline)
              MaterialBanner(
                content: const Text('Offline — poslední známý stav'),
                leading: const Icon(Icons.cloud_off_outlined),
                actions: const [SizedBox.shrink()],
              ),
            Expanded(
              child: WeekScreen(trailing: landscape ? actions : const []),
            ),
          ],
        ),
      ),
    );
  }
}

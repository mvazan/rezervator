import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../admin/admin_screen.dart';
import '../profile/profile_screen.dart';
import 'week_screen.dart';

class HomeShell extends ConsumerWidget {
  const HomeShell({super.key});

  /// Superadmin's way back from a foreign kuželna (0015): switch the
  /// membership home and re-create every tenant-scoped stream.
  Future<void> _goHome(
      BuildContext context, WidgetRef ref, String homeTenantId) async {
    final ok = await tryAction(
      context,
      () => Api.switchTenant(homeTenantId),
      success: 'Přepnuto zpět domů.',
      errorText: friendlyDbError,
    );
    if (!ok || !context.mounted) return;
    resetTenantScopedProviders(ref);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider).value;
    final offline = ref.watch(offlineProvider).value ?? false;
    // A superadmin switched into someone else's kuželna sees ONLY foreign
    // data — keep that on screen permanently, with one tap back home.
    final visiting = profile?.isVisiting ?? false;
    final visitingName = visiting
        ? ref.watch(tenantNameProvider(profile!.tenantId)).value
        : null;
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
            if (visiting)
              MaterialBanner(
                content: Text(
                  visitingName == null
                      ? 'Prohlížíš cizí kuželnu'
                      : 'Prohlížíš kuželnu $visitingName',
                ),
                leading: const Icon(Icons.visibility_outlined),
                backgroundColor:
                    Theme.of(context).colorScheme.tertiaryContainer,
                actions: [
                  TextButton(
                    onPressed: () =>
                        _goHome(context, ref, profile!.homeTenantId),
                    child: const Text('Zpět domů'),
                  ),
                ],
              ),
            Expanded(child: WeekScreen(trailing: actions)),
          ],
        ),
      ),
    );
  }
}

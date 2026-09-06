import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import '../admin/admin_screen.dart';
import '../profile/profile_screen.dart';
import 'my_trainings_screen.dart';
import 'week_screen.dart';

/// The signed-in home: two views — the calendar and Moje tréninky — behind
/// bottom tabs on a phone and a rail on a wide screen. Which one opens at
/// launch is the profile's choice; a tap changes it for this run only. Both
/// views stay mounted (an IndexedStack, not a switch) so paging the calendar
/// forward and glancing at the list never loses the week/day position — the
/// hidden view keeps rebuilding on the minute tick, which is cheap enough to
/// leave running offstage.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  /// Tapped in this run — wins over the profile's launch choice.
  HomeView? _chosen;

  /// The profile's choice as it stood when the shell first saw a profile.
  /// Captured once on purpose: changing it in Můj profil must not yank the
  /// running app to the other view.
  HomeView? _atLaunch;

  /// Superadmin's way back from a foreign kuželna (0015): switch the
  /// membership home and re-create every tenant-scoped stream.
  Future<void> _goHome(BuildContext context, String homeTenantId) async {
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
  Widget build(BuildContext context) {
    final profile = ref.watch(myProfileProvider).value;
    _atLaunch ??= profile?.defaultView;
    final view = _chosen ?? _atLaunch ?? HomeView.calendar;
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

    // IndexedStack (not a switch swapping widgets in and out): both views
    // keep their State — WeekScreen's week offset and day index survive a
    // glance at Moje tréninky and back. children[i]'s index must line up
    // with HomeView's declaration order (see view.index below).
    final content = IndexedStack(
      index: view.index,
      children: [
        WeekScreen(trailing: actions),
        MyTrainingsScreen(
          trailing: actions,
          onOpenCalendar: () => setState(() => _chosen = HomeView.calendar),
        ),
      ],
    );
    final body = Column(
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
            backgroundColor: Theme.of(context).colorScheme.tertiaryContainer,
            actions: [
              TextButton(
                onPressed: () => _goHome(context, profile!.homeTenantId),
                child: const Text('Zpět domů'),
              ),
            ],
          ),
        Expanded(child: content),
      ],
    );

    // A phone in either orientation gets tabs; a tablet or the desktop web
    // a rail on the left — same two destinations.
    final compact = MediaQuery.sizeOf(context).shortestSide < 600;
    void select(int index) => setState(() => _chosen = HomeView.values[index]);

    // A back gesture/button away from the calendar returns to it instead of
    // popping the route (there is nothing to pop to from the home screen
    // anyway) — the same "back = calendar" behaviour a tab bar's own back
    // stack would give for free if the two views were separate routes.
    return PopScope(
      canPop: view == HomeView.calendar,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        setState(() => _chosen = HomeView.calendar);
      },
      child: Scaffold(
        body: SafeArea(
          child: compact
              ? body
              : Row(
                  children: [
                    NavigationRail(
                      selectedIndex: view.index,
                      onDestinationSelected: select,
                      labelType: NavigationRailLabelType.all,
                      destinations: const [
                        NavigationRailDestination(
                          icon: Icon(Icons.calendar_month_outlined),
                          selectedIcon: Icon(Icons.calendar_month),
                          label: Text('Kalendář'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.event_available_outlined),
                          selectedIcon: Icon(Icons.event_available),
                          label: Text('Moje tréninky'),
                        ),
                      ],
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: body),
                  ],
                ),
        ),
        bottomNavigationBar: compact
            ? NavigationBar(
                selectedIndex: view.index,
                onDestinationSelected: select,
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.calendar_month_outlined),
                    selectedIcon: Icon(Icons.calendar_month),
                    label: 'Kalendář',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.event_available_outlined),
                    selectedIcon: Icon(Icons.event_available),
                    label: 'Moje tréninky',
                  ),
                ],
              )
            : null,
      ),
    );
  }
}

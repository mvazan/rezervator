import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import 'clubs_screen.dart';
import 'kiosk_screen.dart';
import 'matches_screen.dart';
import 'overrides_screen.dart';
import 'players_screen.dart';
import 'rentals_screen.dart';
import 'report_screen.dart';
import 'schedule_screen.dart';
import 'tenants_screen.dart';

/// One admin hub entry: label + icon + target screen.
typedef _Entry = ({String label, IconData icon, Widget Function() screen});

const double _wideBreakpoint = 840;

/// Admin hub: entry point to every admin-only screen. Narrow windows get a
/// list; wide (web/desktop) windows a card grid.
class AdminScreen extends ConsumerWidget {
  const AdminScreen({super.key});

  static final List<_Entry> _entries = [
    (
      label: 'Hráči',
      icon: Icons.group_outlined,
      screen: () => const PlayersScreen(),
    ),
    (
      label: 'Oddíly',
      icon: Icons.diversity_3_outlined,
      screen: () => const ClubsScreen(),
    ),
    (
      label: 'Docházka',
      icon: Icons.fact_check_outlined,
      screen: () => const ReportScreen(),
    ),
    (
      label: 'Rozvrh',
      icon: Icons.tune,
      screen: () => const ScheduleAdminScreen(),
    ),
    (
      label: 'Výjimky dnů',
      icon: Icons.event_busy,
      screen: () => const OverridesScreen(),
    ),
    (
      label: 'Zápasy',
      icon: Icons.emoji_events_outlined,
      screen: () => const MatchesScreen(),
    ),
    (
      label: 'Pronájmy',
      icon: Icons.storefront_outlined,
      screen: () => const RentalsScreen(),
    ),
    (
      label: 'Kiosk',
      icon: Icons.tablet_mac_outlined,
      screen: () => const KioskSettingsScreen(),
    ),
  ];

  void _open(BuildContext context, _Entry entry) => Navigator.of(
    context,
  ).push(MaterialPageRoute(builder: (_) => entry.screen()));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider).value;
    if (profile?.isAdmin != true) {
      return Scaffold(
        appBar: AppBar(title: const Text('Správa kuželny')),
        body: const Center(child: Text('Jen pro správce.')),
      );
    }

    // The kuželny approval/switching hub is superadmin-only (0014) and
    // renders as its OWN visually distinct section — tinted tile under a
    // "Správce aplikace" divider, never mixed among the kuželna admin
    // tiles.
    const superEntry = (
      label: 'Kuželny',
      icon: Icons.apartment_outlined,
    );
    final isSuperadmin = profile?.isSuperadmin == true;
    final scheme = Theme.of(context).colorScheme;
    void openTenants() => Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const TenantsScreen()));

    return Scaffold(
      appBar: AppBar(title: const Text('Správa kuželny')),
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < _wideBreakpoint) {
            return ListView(
              children: [
                for (final entry in _entries)
                  ListTile(
                    leading: _AdminIcon(entry.icon),
                    title: Text(entry.label),
                    onTap: () => _open(context, entry),
                  ),
                if (isSuperadmin) ...[
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Text(
                      'Správce aplikace',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                            color: scheme.tertiary,
                          ),
                    ),
                  ),
                  ListTile(
                    tileColor: scheme.tertiaryContainer.withValues(alpha: 0.35),
                    leading: _AdminIcon(superEntry.icon, tinted: true),
                    title: Text(superEntry.label),
                    subtitle: const Text('schvalování a přepínání kuželen'),
                    onTap: openTenants,
                  ),
                ],
              ],
            );
          }
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: GridView(
                padding: const EdgeInsets.all(24),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 300,
                  mainAxisExtent: 96,
                  crossAxisSpacing: 16,
                  mainAxisSpacing: 16,
                ),
                children: [
                  for (final entry in _entries)
                    Card(
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => _open(context, entry),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              _AdminIcon(entry.icon),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Text(
                                  entry.label,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (isSuperadmin)
                    Card(
                      clipBehavior: Clip.antiAlias,
                      color: scheme.tertiaryContainer.withValues(alpha: 0.4),
                      child: InkWell(
                        onTap: openTenants,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              _AdminIcon(superEntry.icon, tinted: true),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      superEntry.label,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium,
                                    ),
                                    Text(
                                      'správce aplikace',
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelSmall
                                          ?.copyWith(color: scheme.tertiary),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Admin hub leading icon: tonal 40×40 rounded square around the glyph.
class _AdminIcon extends StatelessWidget {
  const _AdminIcon(this.icon, {this.tinted = false});

  final IconData icon;

  /// Tertiary treatment for the superadmin section — visually apart from
  /// the regular (primary-tinted) kuželna admin tiles.
  final bool tinted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tinted ? scheme.tertiary : scheme.primaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(
        icon,
        color: tinted ? scheme.onTertiary : scheme.onPrimaryContainer,
        size: 22,
      ),
    );
  }
}

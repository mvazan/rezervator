/// The card-grid/list hub layout shared by every screen that is really just
/// a menu of other screens (Správa kuželny, Klubovna): a ListView below the
/// wide breakpoint, a centred GridView of Cards at or above it.
library;

import 'package:flutter/material.dart';

/// One hub tile: label + icon + optional subtitle + what a tap does.
typedef HubEntry = ({
  String label,
  IconData icon,
  String? subtitle,
  VoidCallback onTap,
});

const double hubWideBreakpoint = 840;

/// No extra section — the default for a hub with nothing beyond its entries.
List<Widget> _noExtra(bool wide) => const [];

/// A hub's leading icon: tonal 40×40 rounded square around the glyph.
class HubIcon extends StatelessWidget {
  const HubIcon(this.icon, {super.key, this.tinted = false});

  final IconData icon;

  /// Tertiary treatment for a visually-set-apart section (the superadmin
  /// tiles on Správa) — apart from the regular (primary-tinted) entries.
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

/// A menu of [entries]: narrow windows get a list, wide (web/desktop)
/// windows a card grid — same breakpoint and measurements Správa kuželny
/// has always used.
class HubMenu extends StatelessWidget {
  const HubMenu({super.key, required this.entries, this.extra = _noExtra});

  final List<HubEntry> entries;

  /// A caller-built section appended after [entries] — e.g. Správa's
  /// superadmin/visiting tiles. Called once per layout (`wide` says which)
  /// so the caller can render it as ListTiles in the list and Cards in the
  /// grid, exactly as that layout already looks.
  final List<Widget> Function(bool wide) extra;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < hubWideBreakpoint) {
            return ListView(
              children: [
                for (final entry in entries)
                  ListTile(
                    leading: HubIcon(entry.icon),
                    title: Text(entry.label),
                    subtitle:
                        entry.subtitle == null ? null : Text(entry.subtitle!),
                    onTap: entry.onTap,
                  ),
                ...extra(false),
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
                  for (final entry in entries) _HubCard(entry: entry),
                  ...extra(true),
                ],
              ),
            ),
          );
        },
      );
}

class _HubCard extends StatelessWidget {
  const _HubCard({required this.entry});

  final HubEntry entry;

  @override
  Widget build(BuildContext context) {
    final subtitle = entry.subtitle;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: entry.onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              HubIcon(entry.icon),
              const SizedBox(width: 16),
              Expanded(
                child: subtitle == null
                    ? Text(entry.label, style: Theme.of(context).textTheme.titleMedium)
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            entry.label,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

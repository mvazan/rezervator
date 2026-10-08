/// Můj profil → „Detail zápasu“: how the match detail draws a match when
/// the device is held upright and when sideways ([matchLayoutPrefsProvider],
/// device-local). The same three drawings the kiosk's admin picks from —
/// the cards, the compact blocks, the table — and the Zápis: upright the
/// score sheet in place of the duels, sideways full screen the moment the
/// phone turns.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/local_prefs.dart';
import '../../../domain/models.dart';

/// The layouts offered, in the order they are offered: least to most
/// dense, the Zápis last.
const matchLayoutChoices = MatchLayout.values;

/// The chip's label of [layout] (the admin's kiosk dropdown spells the
/// same three out longer).
String matchLayoutLabel(MatchLayout layout) => switch (layout) {
  MatchLayout.full => 'Karty',
  MatchLayout.compact => 'Kompaktně',
  MatchLayout.table => 'Tabulka',
  MatchLayout.zapis => 'Zápis',
};

class MatchLayoutCard extends ConsumerWidget {
  const MatchLayoutCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(matchLayoutPrefsProvider);
    final notifier = ref.read(matchLayoutPrefsProvider.notifier);
    final theme = Theme.of(context);
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ListTile(
            title: Text('Detail zápasu'),
            subtitle: Text(
              'Jak se zápas vykreslí: karty soubojů pod sebou, kompaktně '
              'nebo jako tabulka tak, aby se celý zápas vešel na obrazovku, '
              'anebo rovnou zápis. Na šířku zápis po otočení telefonu '
              'naskočí na celou obrazovku.',
            ),
          ),
          _OrientationRow(
            label: 'Na výšku',
            icon: Icons.stay_current_portrait,
            layouts: matchLayoutChoices,
            selected: prefs.portrait,
            onSelected: (l) => notifier.set(portrait: l),
          ),
          _OrientationRow(
            label: 'Na šířku',
            icon: Icons.stay_current_landscape,
            layouts: matchLayoutChoices,
            selected: prefs.landscape,
            onSelected: (l) => notifier.set(landscape: l),
          ),
          if (prefs.landscape == MatchLayout.zapis)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                'Otočením telefonu na šířku se otevře zápis; otočením zpět '
                'se zavře.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

/// „Na výšku“ / „Na šířku“ with one chip per layout; the chips wrap, so a
/// narrow phone with large text still fits every one.
class _OrientationRow extends StatelessWidget {
  const _OrientationRow({
    required this.label,
    required this.icon,
    required this.layouts,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final IconData icon;
  final List<MatchLayout> layouts;
  final MatchLayout selected;
  final ValueChanged<MatchLayout> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Text(label, style: theme.textTheme.titleSmall),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final layout in layouts)
                ChoiceChip(
                  label: Text(matchLayoutLabel(layout)),
                  selected: layout == selected,
                  onSelected: (_) => onSelected(layout),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

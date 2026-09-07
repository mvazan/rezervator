/// The "Vzhled" (appearance) card on Můj profil: theme and text size, each
/// a row that opens a dialog of radio choices. Both are device-local (see
/// data/local_prefs.dart) — about how the screen looks, not about the team
/// or a reservation, which is why the card sits right under the name card
/// and above everything reservation-related.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/text_size.dart';
import '../../../core/theme_choice.dart';
import '../../../data/local_prefs.dart';

/// A "title / current choice" row that opens a [SimpleDialog] of
/// [RadioListTile]s on tap. Shared shape for both rows below — generic over
/// the choice type so the same tile serves [ThemeChoice] and
/// [TextSizeChoice].
class _ChoiceTile<T> extends StatelessWidget {
  const _ChoiceTile({
    required this.icon,
    required this.title,
    required this.value,
    required this.labels,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final T value;
  final Map<T, String> labels;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(labels[value]!),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => showDialog<void>(
        context: context,
        builder: (dialogCtx) => SimpleDialog(
          title: Text(title),
          children: [
            RadioGroup<T>(
              groupValue: value,
              onChanged: (v) {
                Navigator.pop(dialogCtx);
                if (v != null) onChanged(v);
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final entry in labels.entries)
                    RadioListTile<T>(
                      value: entry.key,
                      title: Text(entry.value),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Theme row: system, forced light/dark, or either at Material's own
/// maximum contrast (contrast is its own axis here — see
/// core/theme_choice.dart).
class _ThemeTile extends ConsumerWidget {
  const _ThemeTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) => _ChoiceTile(
        icon: Icons.palette_outlined,
        title: 'Motiv',
        value: ref.watch(themeChoiceProvider),
        labels: const {
          ThemeChoice.system: 'Podle systému',
          ThemeChoice.light: 'Světlý',
          ThemeChoice.dark: 'Tmavý',
          ThemeChoice.lightContrast: 'Světlý — vysoký kontrast',
          ThemeChoice.darkContrast: 'Tmavý — vysoký kontrast',
        },
        onChanged: (v) => ref.read(themeChoiceProvider.notifier).set(v),
      );
}

/// Text-size row: an extra multiplier on top of the phone's own system
/// scale (see core/text_size.dart).
class _TextSizeTile extends ConsumerWidget {
  const _TextSizeTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) => _ChoiceTile(
        icon: Icons.format_size,
        title: 'Velikost písma',
        value: ref.watch(textSizeProvider),
        labels: const {
          TextSizeChoice.normal: 'Normální — jako v telefonu',
          TextSizeChoice.large: 'Větší (115 %)',
          TextSizeChoice.largest: 'Největší (130 %)',
        },
        onChanged: (v) => ref.read(textSizeProvider.notifier).set(v),
      );
}

/// Appearance settings: theme and text size. Placed directly under the
/// name card on Můj profil — appearance is the first thing a player can
/// change and has nothing to do with reservations, so it sits above the
/// reservation-colour card.
class AppearanceCard extends StatelessWidget {
  const AppearanceCard({super.key});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'Vzhled',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const _ThemeTile(),
          const _TextSizeTile(),
        ],
      ),
    );
  }
}

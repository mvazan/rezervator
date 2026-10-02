/// Klubovna's "Kuželny" list (Task 5): the alleys our teams play at, Czech-
/// sorted, searchable — the read-only counterpart to Výsledky's own list of
/// matches. No pinning of our own alley: alphabetical only.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/local_prefs.dart';
import '../../data/providers.dart';
import '../../domain/collation.dart';
import '../../domain/results.dart';
import 'venue_detail_screen.dart';
import '../../core/push_screen.dart';

class VenuesScreen extends ConsumerStatefulWidget {
  const VenuesScreen({super.key});

  @override
  ConsumerState<VenuesScreen> createState() => _VenuesScreenState();
}

class _VenuesScreenState extends ConsumerState<VenuesScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final venuesAsync = ref.watch(venuesProvider);
    final venues = venuesAsync.value ?? const [];
    final loading = venuesAsync.isLoading && !venuesAsync.hasValue;
    final byVenue = ref.watch(venueCompetitionsProvider);
    final competitions = ({for (final c in byVenue.values) ...c}.toList()
      ..sort(compareCzech));
    // The remembered competition, unless no alley has it any more.
    final saved = ref.watch(venueCompetitionFilterProvider);
    final competition = competitions.contains(saved) ? saved : null;
    final filtered = [
      for (final v in venuesMatching(venues, _query))
        if (competition == null ||
            (byVenue[v.slug]?.contains(competition) ?? false))
          v,
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Kuželny')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Hledat kuželnu',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          if (competitions.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: [
                  ChoiceChip(
                    label: const Text('Vše'),
                    selected: competition == null,
                    onSelected: (_) => ref
                        .read(venueCompetitionFilterProvider.notifier)
                        .set(null),
                  ),
                  for (final c in competitions) ...[
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: Text(c),
                      selected: competition == c,
                      onSelected: (_) => ref
                          .read(venueCompetitionFilterProvider.notifier)
                          .set(c),
                    ),
                  ],
                ],
              ),
            ),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : venues.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Zatím žádné kuželny — objeví se po první '
                        'synchronizaci zápasů.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : filtered.isEmpty
                ? const Center(child: Text('Žádná kuželna neodpovídá hledání.'))
                : ListView.builder(
                    itemCount: filtered.length,
                    itemBuilder: (context, i) {
                      final venue = filtered[i];
                      return ListTile(
                        title: Text(venue.name),
                        subtitle: venue.address == null
                            ? null
                            : Text(venue.address!),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => pushScreen(context, (_) =>
                                VenueDetailScreen(slug: venue.slug)),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

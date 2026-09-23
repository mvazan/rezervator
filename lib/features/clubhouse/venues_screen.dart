/// Klubovna's "Kuželny" list (Task 5): the alleys our teams play at, Czech-
/// sorted, searchable — the read-only counterpart to Výsledky's own list of
/// matches. No pinning of our own alley: alphabetical only.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';
import '../../domain/results.dart';
import 'venue_detail_screen.dart';

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
    final filtered = venuesMatching(venues, _query);

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
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                VenueDetailScreen(slug: venue.slug),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

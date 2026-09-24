/// Klubovna's venue detail (Task 5): one alley's contacts, address and
/// technical info off the site's own venue page — Call/E-mail/Navigate
/// actions plus the same data as a read-only list, one Card per section.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';

class VenueDetailScreen extends ConsumerWidget {
  const VenueDetailScreen({
    super.key,
    required this.slug,
    this.callPhone = launchPhone,
    this.sendEmail = launchEmail,
    this.openUrl = launchWeb,
  });

  final String slug;

  /// Injectable so widget tests never reach the platform.
  final void Function(String number) callPhone;
  final void Function(String address) sendEmail;
  final void Function(String url) openUrl;

  Widget _actionsRow(Venue venue) {
    final buttons = [
      if (venue.phone != null)
        FilledButton.tonalIcon(
          onPressed: () => callPhone(venue.phone!),
          icon: const Icon(Icons.call),
          label: const Text('Zavolat'),
        ),
      if (venue.email != null)
        FilledButton.tonalIcon(
          onPressed: () => sendEmail(venue.email!),
          icon: const Icon(Icons.mail_outline),
          label: const Text('Napsat e-mail'),
        ),
      if (venue.mapsUrl != null)
        FilledButton.tonalIcon(
          onPressed: () => openUrl(venue.mapsUrl!),
          icon: const Icon(Icons.directions),
          label: const Text('Navigovat'),
        ),
    ];
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Wrap(spacing: 8, runSpacing: 8, children: buttons),
    );
  }

  List<Widget> _contactTiles(Venue venue) => [
    if (venue.address != null)
      ListTile(
        title: const Text('Adresa'),
        subtitle: Text(venue.address!),
        onTap: venue.mapsUrl == null ? null : () => openUrl(venue.mapsUrl!),
      ),
    if (venue.phone != null)
      ListTile(
        title: const Text('Telefon'),
        subtitle: Text(venue.phone!),
        onTap: () => callPhone(venue.phone!),
      ),
    if (venue.email != null)
      ListTile(
        title: const Text('E-mail'),
        subtitle: Text(venue.email!),
        onTap: () => sendEmail(venue.email!),
      ),
  ];

  Widget _sectionCard(BuildContext context, VenueSection section) => Card(
    margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(section.title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          for (final item in section.items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: LayoutBuilder(
                builder: (context, constraints) => Row(
                  children: [
                    Expanded(child: Text(item.label)),
                    // A value wider than half the card wraps rather than
                    // overflowing it (large text sizes, long dates).
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: constraints.maxWidth / 2,
                      ),
                      child: Text(item.value, textAlign: TextAlign.end),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    ),
  );

  Widget _clubsCard(BuildContext context, Venue venue) {
    if (venue.clubs.isEmpty) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Kluby', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final club in venue.clubs) Text(club),
          ],
        ),
      ),
    );
  }

  Widget _footer(BuildContext context, Venue venue) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Údaje z vysledky.kuzelky.cz · aktualizováno '
          '${dayLabel(Day.fromDateTime(venue.fetchedAt.toLocal()))}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        TextButton(
          onPressed: () => openUrl(
            'https://vysledky.kuzelky.cz/detail-kuzelny/${venue.slug}',
          ),
          child: const Text('Na webu ČKA'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final venuesAsync = ref.watch(venuesProvider);
    final loading = venuesAsync.isLoading && !venuesAsync.hasValue;
    final venues = venuesAsync.value ?? const <Venue>[];

    Venue? venue;
    for (final v in venues) {
      if (v.slug == slug) {
        venue = v;
        break;
      }
    }

    return Scaffold(
      appBar: AppBar(title: Text(venue?.name ?? 'Kuželna')),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : venue == null
          ? const Center(child: Text('Kuželna nenalezena.'))
          : ListView(
              padding: const EdgeInsets.only(bottom: 8),
              children: [
                _actionsRow(venue),
                ..._contactTiles(venue),
                for (final section in venue.sections)
                  _sectionCard(context, section),
                _clubsCard(context, venue),
                _footer(context, venue),
              ],
            ),
    );
  }
}

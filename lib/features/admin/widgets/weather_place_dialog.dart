/// The admin picks the place for the kiosk's weather (0067): the alley's
/// own venue when the federation knows where it is, or a town found by
/// name (Open-Meteo's geocoding). Resolves to the place, null when
/// cancelled.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/open_meteo.dart';
import '../../../domain/collation.dart';
import '../../../domain/models.dart';
import '../../../domain/weather.dart';

/// The alley's venue as a weather place — null without coordinates.
WeatherPlace? venueWeatherPlace(Venue? venue) {
  final lat = venue?.lat;
  final lng = venue?.lng;
  if (venue == null || lat == null || lng == null) return null;
  final address = venue.address;
  return WeatherPlace(
    label: address == null || address.isEmpty
        ? venue.name
        : '${venue.name}, $address',
    lat: lat,
    lon: lng,
  );
}

Future<WeatherPlace?> showWeatherPlaceDialog(
  BuildContext context, {
  WeatherPlace? alley,
}) => showDialog<WeatherPlace>(
  context: context,
  builder: (_) => WeatherPlaceDialog(alley: alley),
);

class WeatherPlaceDialog extends ConsumerStatefulWidget {
  const WeatherPlaceDialog({super.key, this.alley});

  /// The alley's own venue, offered first.
  final WeatherPlace? alley;

  @override
  ConsumerState<WeatherPlaceDialog> createState() =>
      _WeatherPlaceDialogState();
}

class _WeatherPlaceDialogState extends ConsumerState<WeatherPlaceDialog> {
  final _query = TextEditingController();
  List<WeatherPlace>? _results;
  bool _searching = false;
  String? _error;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _query.text;
    if (query.trim().length < 2) return;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final found = await searchWeatherPlaces(
        ref.read(openMeteoClientProvider),
        query,
      );
      if (!mounted) return;
      setState(() {
        _results = [...found]..sort((a, b) => compareCzech(a.label, b.label));
        _searching = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Hledání se nepovedlo — zkontroluj připojení a zkus to znovu.';
        _searching = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final alley = widget.alley;
    final results = _results;
    return AlertDialog(
      title: const Text('Místo pro počasí'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (alley != null) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.place_outlined),
                title: const Text('Kuželna'),
                subtitle: Text(alley.label),
                onTap: () => Navigator.pop(context, alley),
              ),
              const Divider(),
            ],
            TextField(
              controller: _query,
              autofocus: alley == null,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                labelText: 'Hledat obec nebo město',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: 'Hledat',
                  icon: const Icon(Icons.search),
                  onPressed: _searching ? null : _search,
                ),
              ),
              onSubmitted: (_) => _search(),
            ),
            const SizedBox(height: 8),
            if (_searching) const LinearProgressIndicator(),
            if (_error case final error?)
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (results != null && results.isEmpty && !_searching)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Nic nenalezeno.'),
              ),
            if (results != null && results.isNotEmpty)
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final p in results)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(p.label),
                        onTap: () => Navigator.pop(context, p),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Zrušit'),
        ),
      ],
    );
  }
}

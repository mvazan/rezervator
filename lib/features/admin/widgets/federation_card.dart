/// Správa → Oddíly: the ČKA results-service card — the alley's kuželna on
/// vysledky.kuzelky.cz (read-only, changed behind a pencil), automatic sync
/// on/off (saved at once), and a one-off team discovery or sync run.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/models.dart';
import 'venue_slug_field.dart';

class FederationCard extends ConsumerStatefulWidget {
  const FederationCard({
    super.key,
    this.saveFederation = _defaultSave,
    this.discoverTeams = Api.requestFederationDiscovery,
    this.syncNow = Api.requestFederationSync,
  });

  /// Injectable so a widget test can drive the card without the backend.
  final Future<void> Function(String venueSlug, bool enabled) saveFederation;
  final Future<void> Function() discoverTeams;
  final Future<void> Function() syncNow;

  static Future<void> _defaultSave(String venueSlug, bool enabled) =>
      Api.setFederationSync(venueSlug: venueSlug, enabled: enabled);

  @override
  ConsumerState<FederationCard> createState() => _FederationCardState();
}

class _FederationCardState extends ConsumerState<FederationCard> {
  /// The switch's value from a tap until the row echoes it — the save runs
  /// at once, the echo comes over Realtime a moment later. null: the row's.
  bool? _enabledWanted;
  bool _savingEnabled = false;

  Future<void> _setEnabled(FederationSync sync, bool enabled) async {
    setState(() {
      _enabledWanted = enabled;
      _savingEnabled = true;
    });
    final ok = await tryAction(
      context,
      () => widget.saveFederation(sync.venueSlug, enabled),
      errorText: friendlyDbError,
    );
    if (!mounted) return;
    setState(() {
      _savingEnabled = false;
      if (!ok) _enabledWanted = null;
    });
  }

  Future<void> _editSlug(FederationSync sync, bool enabled) =>
      showDialog<bool>(
        context: context,
        builder: (_) => VenueSlugDialog(
          initial: sync.venueSlug,
          save: (slug) => widget.saveFederation(slug, enabled),
        ),
      );

  Future<void> _discover() => tryAction(
        context,
        widget.discoverTeams,
        success: 'Týmy se načítají — za chvíli se objeví níže.',
        errorText: friendlyDbError,
      );

  Future<void> _sync() => tryAction(
        context,
        widget.syncNow,
        success: 'Synchronizace spuštěna.',
        errorText: friendlyDbError,
      );

  /// "čt 23.4. 9:05" — local time, reusing core/ui.dart's date label and
  /// [HourMinute]'s own display instead of hand-rolling another format.
  String _lastSuccessLabel(DateTime? at) {
    if (at == null) return 'Zatím neproběhla';
    final local = at.toLocal();
    final day = Day.fromDateTime(local);
    final time = HourMinute(local.hour, local.minute);
    return '${dayLabel(day)} ${time.display()}';
  }

  @override
  Widget build(BuildContext context) {
    final loaded = ref.watch(federationSyncProvider);
    final sync = loaded.value;
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Výsledkový servis ČKA', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            if (sync != null)
              ..._settings(sync)
            else if (loaded.hasError)
              Text(
                friendlyDbError(loaded.error!),
                style: TextStyle(color: theme.colorScheme.error),
              )
            else
              const Text('Načítám…'),
          ],
        ),
      ),
    );
  }

  List<Widget> _settings(FederationSync sync) {
    // The tapped value stays until the row catches up with it.
    if (_enabledWanted == sync.enabled) _enabledWanted = null;
    final enabled = _enabledWanted ?? sync.enabled;
    final theme = Theme.of(context);
    return [
      const Text(
        'Zápasy a výsledky týmů, které hrají na této kuželně, se stahují '
        'z vysledky.kuzelky.cz.',
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Kuželna na webu', style: theme.textTheme.labelMedium),
                Text(sync.configured
                    ? 'detail-kuzelny/${sync.venueSlug}'
                    : 'Zatím nenastavená'),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Změnit kuželnu',
            onPressed: () => _editSlug(sync, enabled),
          ),
        ],
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Stahovat automaticky'),
        value: enabled,
        onChanged: _savingEnabled || !sync.configured
            ? null
            : (v) => _setEnabled(sync, v),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton(
            onPressed: sync.configured ? _discover : null,
            child: const Text('Přenačíst týmy z webu'),
          ),
          OutlinedButton(
            onPressed: sync.configured && enabled ? _sync : null,
            child: const Text('Synchronizovat teď'),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Text('Poslední synchronizace: ${_lastSuccessLabel(sync.lastSuccessAt)}'),
      if (sync.lastError != null)
        Text(
          'Chyba: ${sync.lastError}',
          style: TextStyle(color: theme.colorScheme.error),
        ),
    ];
  }
}

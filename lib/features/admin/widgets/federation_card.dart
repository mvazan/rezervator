/// Správa → Oddíly: the ČKA results-service card — where the admin sets the
/// alley's slug on vysledky.kuzelky.cz, turns automatic sync on/off, and
/// kicks off a one-off team discovery or sync run. See task-5-brief.md.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/models.dart';

class FederationCard extends ConsumerStatefulWidget {
  const FederationCard({
    super.key,
    this.saveFederation = _defaultSave,
    this.discoverTeams = Api.requestFederationDiscovery,
    this.syncNow = Api.requestFederationSync,
  });

  /// Injectable so a widget test can drive the buttons without the backend.
  final Future<void> Function(String venueSlug, bool enabled) saveFederation;
  final Future<void> Function() discoverTeams;
  final Future<void> Function() syncNow;

  static Future<void> _defaultSave(String venueSlug, bool enabled) =>
      Api.setFederationSync(venueSlug: venueSlug, enabled: enabled);

  @override
  ConsumerState<FederationCard> createState() => _FederationCardState();
}

class _FederationCardState extends ConsumerState<FederationCard> {
  final _slug = TextEditingController();
  bool _enabled = false;

  /// The form follows the row until the admin touches it — the provider
  /// replays the on-disk snapshot before the live row, so a one-shot seed
  /// would pin a stale slug that Uložit then writes back. From the first
  /// edit it is the admin's until a successful Uložit hands it back to the
  /// (echoed) row.
  bool _dirty = false;

  /// The row values the form was last filled from — a rebuild with the same
  /// row (a new lastRunAt, say) must not reset the text field.
  (String, bool)? _seededFrom;

  @override
  void dispose() {
    _slug.dispose();
    super.dispose();
  }

  void _seed(FederationSync sync) {
    final from = (sync.venueSlug, sync.enabled);
    if (_dirty || from == _seededFrom) return;
    _seededFrom = from;
    _slug.text = sync.venueSlug.isEmpty ? 'tj-sokol-brno-iv' : sync.venueSlug;
    _enabled = sync.enabled;
  }

  Future<void> _save() async {
    final ok = await tryAction(
      context,
      () => widget.saveFederation(_slug.text.trim(), _enabled),
      success: 'Uloženo.',
      errorText: friendlyDbError,
    );
    if (ok) _dirty = false;
  }

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
    // Until the row is here the form stays disabled and unseeded — Uložit
    // on the defaults would overwrite the real row.
    final ready = loaded.hasValue;
    final sync = loaded.value ?? FederationSync.none;
    if (ready) _seed(sync);
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Výsledkový servis ČKA', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              'Zápasy a výsledky týmů, které hrají na této kuželně, se '
              'stahují z vysledky.kuzelky.cz.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _slug,
              enabled: ready,
              autocorrect: false,
              onChanged: (_) => _dirty = true,
              decoration: const InputDecoration(
                labelText: 'Kuželna na webu',
                prefixText: 'detail-kuzelny/',
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Stahovat automaticky'),
              value: _enabled,
              onChanged: ready
                  ? (v) => setState(() {
                        _enabled = v;
                        _dirty = true;
                      })
                  : null,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: ready ? _save : null,
                  child: const Text('Uložit'),
                ),
                OutlinedButton(
                  onPressed: sync.configured ? _discover : null,
                  child: const Text('Načíst týmy z webu'),
                ),
                OutlinedButton(
                  onPressed: sync.configured && sync.enabled ? _sync : null,
                  child: const Text('Synchronizovat teď'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Poslední synchronizace: '
              '${_lastSuccessLabel(sync.lastSuccessAt)}',
            ),
            if (loaded.hasError && !ready)
              Text(
                friendlyDbError(loaded.error!),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            if (sync.lastError != null)
              Text(
                'Chyba: ${sync.lastError}',
                style: TextStyle(color: theme.colorScheme.error),
              ),
          ],
        ),
      ),
    );
  }
}

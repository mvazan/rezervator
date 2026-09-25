/// Správa → Oddíly: the ČKA results-service card. Until the alley was first
/// synced it is the setup wizard ([FederationWizard]); after that the
/// kuželna on vysledky.kuzelky.cz (read-only, changed behind a pencil),
/// automatic sync on/off (saved at once), a one-off team discovery or sync
/// run, and while federation jobs are still to run, a spinning line that
/// says what is left (0046 `federation_sync_progress`).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/labels.dart';
import '../../../domain/models.dart';
import 'federation_wizard.dart';
import 'venue_slug_field.dart';

class FederationCard extends ConsumerStatefulWidget {
  const FederationCard({
    super.key,
    this.saveFederation = _defaultSave,
    this.discoverTeams = Api.requestFederationDiscovery,
    this.syncNow = Api.requestFederationSync,
    this.syncProgress = Api.federationSyncProgress,
  });

  /// Injectable so a widget test can drive the card without the backend.
  final Future<void> Function(String venueSlug, bool enabled) saveFederation;
  final Future<void> Function() discoverTeams;
  final Future<void> Function() syncNow;
  final Future<FederationSyncProgress> Function() syncProgress;

  static Future<void> _defaultSave(String venueSlug, bool enabled) =>
      Api.setFederationSync(venueSlug: venueSlug, enabled: enabled);

  @override
  ConsumerState<FederationCard> createState() => _FederationCardState();
}

class _FederationCardState extends ConsumerState<FederationCard>
    with WidgetsBindingObserver {
  static const _pollEvery = Duration(seconds: 5);

  /// Looks after a request even while nothing is pending yet — its jobs may
  /// not be due, or be done before the first look: 12 × 5 s = 60 s.
  static const _graceLooks = 12;

  /// Looks after a discovery's jobs are done, while its report is on its
  /// way to the row: 2 × 5 s.
  static const _reportLooks = 2;

  FederationSyncProgress _progress = FederationSyncProgress.idle;
  Timer? _timer;
  bool _looking = false;
  bool _foreground = true;
  int _graceLeft = 0;

  /// A request since the row was last fetched: it is fetched again at 0
  /// even when no look saw the run pending.
  bool _refreshAtZero = false;

  /// A discovery ran since the last fetch: its teams and clubs are fetched
  /// again with the row.
  bool _discoveryRan = false;

  /// A discovery was asked for and the row still holds the report from
  /// before it ([_reportBefore] is that report's `at`).
  bool _awaitingDiscovery = false;
  DateTime? _reportBefore;

  /// The discovery the looks count is a failed one waiting to retry, seen
  /// next to its error in the row. It stays that after a move to another
  /// kuželna drops the error (0046's set_federation_sync), until the count
  /// is 0 or a new request.
  bool _failedRetry = false;

  /// The switch's value from a tap until the row echoes it — the save runs
  /// at once, the echo comes over Realtime a moment later. null: the row's.
  bool? _enabledWanted;
  bool _savingEnabled = false;

  /// The wizard's last step switched the sync on: the normal view from now
  /// on, without waiting for the row's echo.
  bool _setupDone = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // One look on opening: an admin coming back to a running first sync
    // sees it still going.
    _look();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  /// No looks behind the admin's back: the background stops them, the
  /// foreground looks again at once.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (_foreground) return;
        _foreground = true;
        _look();
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        _foreground = false;
        _timer?.cancel();
        _timer = null;
      case AppLifecycleState.inactive:
        break;
    }
  }

  /// A run was just requested: look now, then every 5 s for up to a minute
  /// even while nothing is pending yet.
  void _afterRequest({bool discovery = false}) {
    _graceLeft = _graceLooks;
    _refreshAtZero = true;
    if (discovery) {
      _discoveryRan = true;
      _failedRetry = false;
      setState(() {
        _awaitingDiscovery = true;
        _reportBefore = ref.read(federationSyncProvider).value?.discover?.at;
      });
    }
    _look();
  }

  Future<void> _look() async {
    _timer?.cancel();
    _timer = null;
    // A look already under way schedules the next one itself.
    if (_looking || !_foreground) return;
    _looking = true;
    FederationSyncProgress? next;
    try {
      next = await widget.syncProgress();
    } catch (_) {
      // Offline for a moment: the line stays, the next look asks again.
    }
    _looking = false;
    if (!mounted) return;
    if (_graceLeft > 0) _graceLeft--;
    if (next != null) {
      if (next.discover > 0) _discoveryRan = true;
      if (next.pending) {
        // Seen running: from here on the looks stop at 0.
        _graceLeft = 0;
      } else if (_progress.pending || _refreshAtZero) {
        _refreshAtZero = false;
        if (_awaitingDiscovery && _graceLeft < _reportLooks) {
          _graceLeft = _reportLooks;
        }
        ref.invalidate(federationSyncProvider);
        if (_discoveryRan) {
          _discoveryRan = false;
          ref
            ..invalidate(teamsProvider)
            ..invalidate(clubsProvider);
        }
      }
      if (next != _progress) setState(() => _progress = next!);
    }
    if (_awaitingDiscovery && _graceLeft == 0 && !_progress.pending) {
      setState(() => _awaitingDiscovery = false);
    }
    if (_foreground && (_progress.pending || _graceLeft > 0)) {
      _timer = Timer(_pollEvery, _look);
    }
  }

  /// A discovery is running, or its report is not in the row yet. A failed
  /// discovery's job only waits to retry: jobOutcome re-arms it at +1, +2,
  /// +4 and +8 min, and federation_sync_progress counts each as leased. So
  /// once the row holds its error, that error shows, not a quarter of an
  /// hour's loader. Nor does it once another kuželna drops that error
  /// ([_failedRetry]): the count is still the old retry, not a request of
  /// the admin's. A newer request still waits for its own report.
  bool _discovering(FederationSync sync) {
    final report = sync.discover;
    if (_awaitingDiscovery && report?.at != _reportBefore) {
      _awaitingDiscovery = false;
    }
    if (_awaitingDiscovery) return true;
    final failed = report?.failed ?? false;
    if (failed) _failedRetry = _progress.discover > 0;
    if (_progress.discover == 0) _failedRetry = false;
    return _progress.discover > 0 && !failed && !_failedRetry;
  }

  /// What the progress line counts: the discovery only while
  /// [_discovering] — a failed one waiting to retry is left out.
  FederationSyncProgress _shownProgress(bool discovering) =>
      discovering || _progress.discover == 0
          ? _progress
          : FederationSyncProgress(
              competitions: _progress.competitions,
              matches: _progress.matches,
              venues: _progress.venues,
            );

  Future<bool> _requestDiscovery() async {
    final ok = await tryAction(
      context,
      widget.discoverTeams,
      errorText: friendlyDbError,
    );
    if (ok && mounted) _afterRequest(discovery: true);
    return ok;
  }

  Future<void> _sync() async {
    final ok = await tryAction(
      context,
      widget.syncNow,
      success: 'Synchronizace spuštěna.',
      errorText: friendlyDbError,
    );
    if (ok && mounted) _afterRequest();
  }

  /// The wizard's last step: the sync on, then the first run.
  Future<bool> _enable(FederationSync sync) async {
    final ok = await tryAction(
      context,
      () async {
        await widget.saveFederation(sync.venueSlug, true);
        await widget.syncNow();
      },
      errorText: friendlyDbError,
    );
    if (ok && mounted) {
      setState(() {
        _setupDone = true;
        _enabledWanted = true;
      });
      _afterRequest();
    }
    return ok;
  }

  /// Never synced and never switched on: the setup is not finished. Once
  /// on, or ever synced, the normal view stays — even with the sync
  /// switched off later.
  bool _inSetup(FederationSync sync) =>
      !_setupDone && !sync.enabled && sync.lastRunAt == null;

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
            if (sync != null && _inSetup(sync))
              _wizard(sync)
            else if (sync != null)
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

  Widget _wizard(FederationSync sync) {
    final teams = ref.watch(teamsProvider);
    if (!teams.hasValue && !teams.hasError) return const Text('Načítám…');
    return FederationWizard(
      sync: sync,
      teams: teams.value ?? const [],
      discovering: _discovering(sync),
      saveSlug: (slug) => tryAction(
        context,
        () => widget.saveFederation(slug, false),
        errorText: friendlyDbError,
      ),
      discover: _requestDiscovery,
      enable: () => _enable(sync),
    );
  }

  List<Widget> _settings(FederationSync sync) {
    // The tapped value stays until the row catches up with it.
    if (_enabledWanted == sync.enabled) _enabledWanted = null;
    final enabled = _enabledWanted ?? sync.enabled;
    final discovering = _discovering(sync);
    final progress = _shownProgress(discovering);
    final busy = discovering || progress.pending;
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
            onPressed: busy ? null : () => _editSlug(sync, enabled),
          ),
        ],
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Stahovat automaticky'),
        value: enabled,
        onChanged: busy || _savingEnabled || !sync.configured
            ? null
            : (v) => _setEnabled(sync, v),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton(
            onPressed: !busy && sync.configured ? _requestDiscovery : null,
            child: const Text('Přenačíst týmy z webu'),
          ),
          OutlinedButton(
            onPressed: !busy && sync.configured && enabled ? _sync : null,
            child: const Text('Synchronizovat teď'),
          ),
        ],
      ),
      const SizedBox(height: 8),
      if (busy)
        Row(
          children: [
            const SizedBox.square(
              dimension: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(discovering
                  ? teamsLoadingLabel
                  : federationProgressLabel(progress)),
            ),
          ],
        ),
      Text(
        'Poslední synchronizace: ${_lastSuccessLabel(sync.lastSuccessAt)}',
        style: busy
            ? theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)
            : null,
      ),
      if (sync.lastError != null)
        Text(
          'Chyba: ${sync.lastError}',
          style: TextStyle(color: theme.colorScheme.error),
        ),
    ];
  }
}

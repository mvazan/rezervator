/// Klubovna's match detail (Task 4): one federation match's score, team
/// stats, players with a per-lane breakdown, video/web links and a live
/// refresh — pushed from `results_screen.dart`'s row tap.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/clock.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import '../../domain/results.dart';
import 'venue_detail_screen.dart';
import 'widgets/match_players.dart';

class MatchDetailScreen extends ConsumerStatefulWidget {
  const MatchDetailScreen({
    super.key,
    required this.matchId,
    this.refresh = _defaultRefresh,
    this.launch = _defaultLaunch,
  });

  final String matchId;

  /// Injectable so widget tests never reach Supabase or the platform.
  final Future<String> Function(String matchId) refresh;
  final void Function(String url) launch;

  static Future<String> _defaultRefresh(String matchId) =>
      Api.refreshMatch(matchId);
  static void _defaultLaunch(String url) => launchWeb(url);

  @override
  ConsumerState<MatchDetailScreen> createState() => _MatchDetailScreenState();
}

class _MatchDetailScreenState extends ConsumerState<MatchDetailScreen> {
  bool _didOpenRefresh = false;

  /// True while the ⟳ tap's own refresh is outstanding — cleared either by
  /// [_waitTimer] (20s) or, declaratively in [build], the moment the
  /// watched result's `fetchedAt` moves past [_waitingBaseline].
  bool _waiting = false;
  DateTime? _waitingBaseline;
  Timer? _waitTimer;

  /// Set once a manual refresh comes back `not_live` — the button then stays
  /// hidden for the rest of this screen's lifetime even though [isLive]
  /// itself does not know that yet.
  bool _hiddenByNotLive = false;

  @override
  void dispose() {
    _waitTimer?.cancel();
    super.dispose();
  }

  // Same reasoning as results_screen's own _refreshQuietly: a background
  // poke on open, not a user action — errors are logged and swallowed.
  Future<void> _refreshQuietly() async {
    try {
      await widget.refresh(widget.matchId);
    } catch (e) {
      debugPrint('Detail zápasu: auto-refresh of ${widget.matchId} failed: $e');
    }
  }

  Future<void> _onRefreshTap(BuildContext context, DateTime? baseline) async {
    _waitTimer?.cancel();
    setState(() {
      _waiting = true;
      _waitingBaseline = baseline;
    });
    _waitTimer = Timer(const Duration(seconds: 20), () {
      if (mounted) setState(() => _waiting = false);
    });
    try {
      final status = await widget.refresh(widget.matchId);
      if (!context.mounted) return;
      // Both terminal answers mean there is nothing left to wait for: a
      // 'fresh' row is already as new as it gets, and 'not_live' means no
      // fetch will ever land — waiting for a fetchedAt that changes would
      // spin forever.
      if (status == 'fresh') {
        setState(() => _waiting = false);
        snack(context, 'Výsledky jsou čerstvé.');
      } else if (status == 'not_live') {
        setState(() {
          _waiting = false;
          _hiddenByNotLive = true;
        });
      }
    } catch (e) {
      if (context.mounted) snack(context, friendlyDbError(e));
      if (mounted) setState(() => _waiting = false);
    }
  }

  static String _appBarTitle(PrioritySlot? slot) {
    if (slot == null) return 'Zápas';
    final parts = [
      if ((slot.competition ?? '').isNotEmpty) slot.competition!,
      if (slot.round != null) '${slot.round}. kolo',
    ];
    return parts.isEmpty ? slot.title : parts.join(' · ');
  }

  static String _statusLabel(MatchStatus status) => switch (status) {
    MatchStatus.scheduled => 'Naplánováno',
    MatchStatus.preparation => 'Příprava',
    MatchStatus.inProgress => 'Probíhá',
    MatchStatus.finished => 'Dokončeno',
    MatchStatus.forfeit => 'Kontumace',
  };

  Widget _headerCard(PrioritySlot slot, MatchResult? result, Venue? venueMatch) {
    final theme = Theme.of(context);
    final format = formatLabel(result?.matchType ?? '', result?.discipline ?? '');
    final status = _statusLabel(result?.status ?? MatchStatus.scheduled);
    final pins = result == null ? '' : pinsLabel(result.homeTotal, result.awayTotal);
    final setPoints = result == null
        ? '–'
        : pointsLabel(result.homeSetPoints, result.awaySetPoints);
    final venue = slot.venue;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${dayFull(slot.date)} · ${slot.startsAt.display()}',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(slot.homeTeam, textAlign: TextAlign.end),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    pointsLabel(result?.homePoints, result?.awayPoints),
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Expanded(child: Text(slot.awayTeam)),
              ],
            ),
            if (pins.isNotEmpty || result != null) ...[
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (pins.isNotEmpty) ...[
                    Text(pins, style: theme.textTheme.bodySmall),
                    const SizedBox(width: 12),
                  ],
                  Text('SB $setPoints', style: theme.textTheme.bodySmall),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Text(
              [if (format.isNotEmpty) format, status].join(' · '),
              style: theme.textTheme.bodySmall,
            ),
            if (venue != null && venue.isNotEmpty) ...[
              const SizedBox(height: 4),
              if (venueMatch == null)
                Text('Kuželna: $venue', style: theme.textTheme.bodySmall)
              else
                InkWell(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => VenueDetailScreen(slug: venueMatch.slug),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Kuželna: $venue', style: theme.textTheme.bodySmall),
                      Icon(
                        Icons.chevron_right,
                        size: 16,
                        color: theme.textTheme.bodySmall?.color,
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buttonsRow(BuildContext context, PrioritySlot slot) {
    final videoUrl = slot.videoUrl;
    final siteUrl = slot.siteUrl;
    if (videoUrl == null && siteUrl == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Wrap(
        spacing: 8,
        children: [
          if (videoUrl != null)
            OutlinedButton.icon(
              onPressed: () => widget.launch(videoUrl),
              icon: const Icon(Icons.play_circle_outline),
              label: const Text('Video'),
            ),
          if (siteUrl != null)
            OutlinedButton.icon(
              onPressed: () => widget.launch(siteUrl),
              icon: const Icon(Icons.open_in_new),
              label: const Text('Na webu ČKA'),
            ),
        ],
      ),
    );
  }

  Widget _statsTable(BuildContext context, MatchResult? result) {
    final theme = Theme.of(context);
    final rows = [
      ('Plné', result?.homeFulls, result?.awayFulls),
      ('Dorážka', result?.homeSpares, result?.awaySpares),
      ('Chyby', result?.homeErrors, result?.awayErrors),
      ('Výkon', result?.homeTotal, result?.awayTotal),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Table(
        columnWidths: const {
          0: FlexColumnWidth(2),
          1: FlexColumnWidth(1),
          2: FlexColumnWidth(1),
        },
        children: [
          for (final row in rows)
            TableRow(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(row.$1, style: theme.textTheme.bodyMedium),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(numLabel(row.$2), textAlign: TextAlign.center),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(numLabel(row.$3), textAlign: TextAlign.center),
                ),
              ],
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final now = ref.watch(nowProvider).value ?? DateTime.now();
    final slots = ref.watch(prioritySlotsProvider);
    final slotsLoading = ref.watch(prioritySlotsLoadingProvider);
    final resultsAsync = ref.watch(matchResultsProvider);
    final results = resultsAsync.value ?? const <String, MatchResult>{};
    final result = results[widget.matchId];
    final players =
        ref.watch(matchPlayerResultsProvider(widget.matchId)).value ??
        const <MatchPlayerResult>[];
    final venues = ref.watch(venuesProvider).value ?? const <Venue>[];

    PrioritySlot? slot;
    for (final s in slots) {
      if (s.id == widget.matchId) {
        slot = s;
        break;
      }
    }

    Venue? venueMatch;
    if (slot?.venueSlug case final slug? when slug.isNotEmpty) {
      for (final v in venues) {
        if (v.slug == slug) {
          venueMatch = v;
          break;
        }
      }
    }

    if (!_didOpenRefresh &&
        !slotsLoading &&
        resultsAsync.hasValue &&
        slot != null) {
      _didOpenRefresh = true;
      if (isLive(slot, result, now)) {
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => unawaited(_refreshQuietly()),
        );
      }
    }

    final resultChanged = _waiting && result?.fetchedAt != _waitingBaseline;
    if (resultChanged) {
      _waitTimer?.cancel();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _waiting) setState(() => _waiting = false);
      });
    }
    final showWaiting = _waiting && !resultChanged;
    final live = slot != null && isLive(slot, result, now);
    final showRefreshButton = live && !_hiddenByNotLive;

    return Scaffold(
      appBar: AppBar(
        title: Text(_appBarTitle(slot)),
        actions: [
          if (showRefreshButton)
            showWaiting
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Obnovit',
                    onPressed: () => _onRefreshTap(context, result?.fetchedAt),
                  ),
        ],
      ),
      body: slotsLoading
          ? const Center(child: CircularProgressIndicator())
          : slot == null
          ? const Center(child: Text('Zápas už v rozpisu není.'))
          : ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                _headerCard(slot, result, venueMatch),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    result == null
                        ? 'Výsledky zatím nejsou.'
                        : 'Výsledky z webu: ${freshnessLabel(result.fetchedAt, now)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                _buttonsRow(context, slot),
                _statsTable(context, result),
                if (players.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Sestavy zatím nejsou k dispozici.'),
                  )
                else ...[
                  MatchPlayerSection(
                    title: 'Domácí — ${slot.homeTeam}',
                    players: [
                      for (final p in players)
                        if (p.side == 'home') p,
                    ],
                  ),
                  MatchPlayerSection(
                    title: 'Hosté — ${slot.awayTeam}',
                    players: [
                      for (final p in players)
                        if (p.side == 'away') p,
                    ],
                  ),
                ],
              ],
            ),
    );
  }
}

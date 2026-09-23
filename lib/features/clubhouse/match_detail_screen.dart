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
import 'widgets/legacy_score_sheet.dart';

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

  Widget _headerCard(
    PrioritySlot slot,
    MatchResult? result,
    Venue? venueMatch,
  ) {
    final theme = Theme.of(context);
    final format = formatLabel(
      result?.matchType ?? '',
      result?.discipline ?? '',
    );
    final status = _statusLabel(result?.status ?? MatchStatus.scheduled);
    final pins = result == null
        ? ''
        : pinsLabel(result.homeTotal, result.awayTotal);
    final setPoints = result == null
        ? '–'
        : pointsLabel(result.homeSetPoints, result.awaySetPoints);
    final venue = slot.venue;
    final winner = winningSide(result?.homePoints, result?.awayPoints);
    // Matches the SAME base style the plain (unwon) name renders in — the
    // Card's own Material sets the ambient DefaultTextStyle to bodyMedium
    // for this subtree, which is what an unstyled `Text(slot.awayTeam)`
    // actually resolves to — rather than bodyLarge's bigger size, so the
    // winner reads heavier at the same baseline as the loser, not bigger.
    // (Not `DefaultTextStyle.of(context)`: `context` here is
    // `_headerCard`'s own parameter — this State's outer context, ABOVE the
    // Scaffold/Card it builds — so it resolves to the app-root ambient
    // style, not the one actually in effect where the Text widgets below
    // render.) FIXED weights on both sides — see MatchTitle's own comment
    // (`widgets/match_title.dart`) for why the loser is explicitly
    // lightened too, not left at bold/w700: w800 alone next to an
    // already-bold base reads as barely-there. w800 is the heaviest
    // Manrope cut this app actually bundles (pubspec.yaml).
    final winnerNameStyle = theme.textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w800,
    );
    final loserNameStyle = theme.textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w400,
    );
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
                  child: Text(
                    slot.homeTeam,
                    textAlign: TextAlign.end,
                    style: winner == null
                        ? null
                        : winner == MatchSide.home
                        ? winnerNameStyle
                        : loserNameStyle,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    pointsLabel(result?.homePoints, result?.awayPoints),
                    style: theme.textTheme.headlineSmall,
                  ),
                ),
                Expanded(
                  child: Text(
                    slot.awayTeam,
                    style: winner == null
                        ? null
                        : winner == MatchSide.away
                        ? winnerNameStyle
                        : loserNameStyle,
                  ),
                ),
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

  Widget _buttonsRow(
    BuildContext context,
    PrioritySlot slot,
    MatchResult? result,
    DateTime now,
  ) {
    final videoUrl = slot.videoUrl;
    final siteUrl = slot.siteUrl;
    if (videoUrl == null && siteUrl == null) return const SizedBox.shrink();
    final live = isLive(slot, result, now);
    final recorded =
        result?.status == MatchStatus.finished ||
        result?.status == MatchStatus.forfeit;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Wrap(
        spacing: 8,
        children: [
          if (videoUrl != null)
            FilledButton.icon(
              onPressed: () => widget.launch(videoUrl),
              icon: live
                  ? Icon(
                      Icons.circle,
                      size: 12,
                      color: Theme.of(context).colorScheme.error,
                    )
                  : const Icon(Icons.play_circle_fill),
              label: Text(
                live ? 'Sledovat živě' : (recorded ? 'Záznam' : 'Video'),
              ),
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
                _buttonsRow(context, slot, result, now),
                if (players.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Sestavy zatím nejsou k dispozici.'),
                  )
                else
                  LegacyScoreSheet(slot: slot, result: result, players: players),
              ],
            ),
    );
  }
}

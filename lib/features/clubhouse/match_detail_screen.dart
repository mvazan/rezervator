/// Klubovna's match detail (Task 4): one federation match's score, team
/// stats, players with a per-lane breakdown, video/web links and a live
/// refresh — pushed from `results_screen.dart`'s row tap.
///
/// Top to bottom: the scoreboard (shared by both views, so the score never
/// jumps), the video and web buttons, a [Souboje | Zápis] switch remembered
/// on the device, and the chosen view — one card per duel and the Družstva
/// card, or the kuzelky.com-style score sheet.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/clock.dart';
import '../../data/local_prefs.dart';
import '../../data/providers.dart';
import '../../domain/duels.dart';
import '../../domain/models.dart';
import '../../domain/palette.dart';
import '../../domain/results.dart';
import 'venue_detail_screen.dart';
import 'widgets/duel_card.dart';
import 'widgets/legacy_score_sheet.dart';
import 'widgets/match_scoreboard.dart';
import 'widgets/team_totals_card.dart';

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

  /// The positions of the duel cards opened to their lane tables. Keyed by
  /// position, not by card, so an opened duel stays open through a live
  /// refresh and a trip to Zápis and back.
  final Set<int> _expanded = {};

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

  /// [Souboje | Zápis] on the left, bound to [matchDetailViewProvider]; in
  /// Souboje „Rozbalit vše“ / „Sbalit vše“ on the right. With large text on
  /// a narrow phone the button drops under the switch instead of
  /// overflowing.
  Widget _switchRow(MatchDetailView view, List<Duel> duels) {
    // A duel nobody has started never opens: it neither needs the button
    // nor keeps it from reading „Sbalit vše“ once the rest are open.
    final openable = [
      for (final duel in duels)
        if (duel.state != DuelState.waiting) duel.position,
    ];
    final allOpen = openable.isNotEmpty && openable.every(_expanded.contains);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 4,
        children: [
          SegmentedButton<MatchDetailView>(
            segments: const [
              ButtonSegment(
                value: MatchDetailView.souboje,
                label: Text('Souboje'),
              ),
              ButtonSegment(value: MatchDetailView.zapis, label: Text('Zápis')),
            ],
            selected: {view},
            onSelectionChanged: (chosen) => unawaited(
              ref.read(matchDetailViewProvider.notifier).set(chosen.first),
            ),
          ),
          if (view == MatchDetailView.souboje && openable.isNotEmpty)
            TextButton(
              onPressed: () => setState(() {
                if (allOpen) {
                  _expanded.clear();
                } else {
                  // Every position, the waiting ones too: a duel that
                  // starts later opens already expanded, as asked.
                  _expanded.addAll(duels.map((duel) => duel.position));
                }
              }),
              child: Text(allOpen ? 'Sbalit vše' : 'Rozbalit vše'),
            ),
        ],
      ),
    );
  }

  /// The Souboje view: one card per duel (12dp from the edges, 8dp apart),
  /// then the Družstva card. Without a lineup the no-lineup line stands in
  /// for the duel cards; the Družstva card still shows the team sums.
  List<Widget> _souboje({
    required List<Duel> duels,
    required MatchResult? result,
    required Color homeColor,
    required Color awayColor,
  }) {
    final scale = diffScale(duels);
    return [
      // No lineup: the scoreboard already says so.
      for (final duel in duels)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: DuelCard(
              duel: duel,
              scale: scale,
              expanded: _expanded.contains(duel.position),
              // A waiting duel has nothing to open; remembering the tap
              // would open it by surprise once it starts.
              onTap: duel.state == DuelState.waiting
                  ? () {}
                  : () => setState(() {
                      if (!_expanded.remove(duel.position)) {
                        _expanded.add(duel.position);
                      }
                    }),
              homeColor: homeColor,
              awayColor: awayColor,
            ),
          ),
      if (result != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: TeamTotalsCard(result: result),
        ),
    ];
  }


  /// [child] as wide as the list but at most 720dp, centred — the Souboje
  /// column until the wide layouts land. Every row but the Zápis sheet,
  /// which keeps the full width.
  static Widget _centred(Widget child) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      // Center loosens the list's full-width constraint; the SizedBox takes
      // the whole (capped) width back, so every row lays out as before
      // instead of shrinking to its content.
      child: SizedBox(width: double.infinity, child: child),
    ),
  );

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
    final view = ref.watch(matchDetailViewProvider);
    final teamColors =
        ref.watch(myTeamColorsProvider).value ?? const <String, int>{};

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
          : _body(
              context,
              slot: slot,
              result: result,
              players: players,
              venueMatch: venueMatch,
              view: view,
              teamColors: teamColors,
              now: now,
              live: live,
              // Pulling is the ⟳ button's twin: gone together once a
              // refresh has answered not_live.
              pullToRefresh: showRefreshButton,
            ),
    );
  }

  /// The scrolling column under the AppBar — see the library comment.
  Widget _body(
    BuildContext context, {
    required PrioritySlot slot,
    required MatchResult? result,
    required List<MatchPlayerResult> players,
    required Venue? venueMatch,
    required MatchDetailView view,
    required Map<String, int> teamColors,
    required DateTime now,
    required bool live,
    required bool pullToRefresh,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // The viewer's own colour for a team (the one Výsledky and the calendar
    // use), else primary for home and tertiary for away.
    final homeColor =
        googleEventColorOf(teamColors[slot.homeTeam]) ?? scheme.primary;
    final awayColor =
        googleEventColorOf(teamColors[slot.awayTeam]) ?? scheme.tertiary;
    final duels = duelsOf(players);

    final children = <Widget>[
      for (final child in [
        MatchScoreboard(
          slot: slot,
          result: result,
          players: players,
          now: now,
          onVenueTap: venueMatch == null
              ? null
              : () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => VenueDetailScreen(slug: venueMatch.slug),
                  ),
                ),
          homeColor: homeColor,
          awayColor: awayColor,
        ),
        // While live the freshness sits in the scoreboard's „Živě“ chip.
        if (result == null || !live)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              result == null
                  ? 'Výsledky zatím nejsou.'
                  : 'Výsledky z webu: ${freshnessLabel(result.fetchedAt, now)}',
              style: theme.textTheme.bodySmall,
            ),
          ),
        _buttonsRow(context, slot, result, now),
        _switchRow(view, duels),
      ])
        _centred(child),
      ...switch (view) {
        MatchDetailView.souboje => [
          for (final child in _souboje(
            duels: duels,
            result: result,
            homeColor: homeColor,
            awayColor: awayColor,
          ))
            _centred(child),
        ],
        MatchDetailView.zapis => [
          // Not centred: the sheet keeps the whole width, as before
          // Souboje. At its natural size (about 1000dp) it fits a wide
          // window whole instead of hiding a third behind a sideways
          // scroll. LegacyScoreSheet shows its team summary row even with
          // no lineup yet (as long as `result` has team-level data) — only
          // the per-player section needs this fallback message.
          LegacyScoreSheet(slot: slot, result: result, players: players),
        ],
      },
    ];

    final list = ListView(
      // Keeps the scroll offset when the pull-to-refresh around the list
      // comes or goes (a match that ends while watched): the list is then
      // rebuilt under a new parent and would start from the top again.
      key: const PageStorageKey('match-detail'),
      // A short list (no lineup yet) still has to pull.
      physics: pullToRefresh ? const AlwaysScrollableScrollPhysics() : null,
      padding: const EdgeInsets.only(bottom: 24),
      children: children,
    );
    if (!pullToRefresh) return list;
    return RefreshIndicator(
      onRefresh: () async {
        await _refreshQuietly();
      },
      child: list,
    );
  }
}

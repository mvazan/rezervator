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
    this.competitionSlug,
    this.siteMatchId,
    this.refresh = _defaultRefresh,
    this.launch = _defaultLaunch,
  });

  final String matchId;

  /// Set for a match no active team of ours plays (0055 — a foreign one, or
  /// one of a switched-off team): it is read from `league_matches` of this
  /// competition instead of the alley's priority slots.
  final String? competitionSlug;

  /// The site's id of the match, when known: a foreign match that becomes
  /// one of ours while this screen is open (a team discovered later) is then
  /// found among our slots instead of reading „už v rozpisu není“.
  final int? siteMatchId;

  /// Injectable so widget tests never reach Supabase or the platform.
  final Future<String> Function(String matchId, {bool force}) refresh;
  final void Function(String url) launch;

  static Future<String> _defaultRefresh(String matchId, {bool force = false}) =>
      Api.refreshMatch(matchId, force: force);
  static void _defaultLaunch(String url) => launchWeb(url);

  @override
  ConsumerState<MatchDetailScreen> createState() => _MatchDetailScreenState();
}

class _MatchDetailScreenState extends ConsumerState<MatchDetailScreen> {
  bool _didOpenRefresh = false;

  /// The id the refresh calls use: the widget's, or — once a foreign match
  /// turned into one of ours — our slot's.
  String? _resolvedId;
  String get _matchId => _resolvedId ?? widget.matchId;

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
      await widget.refresh(_matchId);
    } catch (e) {
      debugPrint('Detail zápasu: auto-refresh of $_matchId failed: $e');
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
      final status = await widget.refresh(_matchId, force: true);
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
    if (videoUrl == null) return const SizedBox.shrink();
    final live = isLive(slot, result, now);
    final recorded =
        result?.status == MatchStatus.finished ||
        result?.status == MatchStatus.forfeit;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Wrap(
        spacing: 8,
        children: [
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
        ],
      ),
    );
  }

  /// „Výsledky z webu: před 5 dny“ on the left and the „Na webu ČKA“ button
  /// on the right, on one row. The button drops under the text, still at the
  /// right, when the row is too narrow.
  Widget _freshnessRow(
    ThemeData theme,
    String? siteUrl,
    MatchResult? result,
    bool live,
    DateTime now,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 0),
      child: OverflowBar(
        alignment: MainAxisAlignment.spaceBetween,
        spacing: 8,
        overflowSpacing: 4,
        overflowAlignment: OverflowBarAlignment.end,
        children: [
          if (result == null || !live)
            Text(
              result == null
                  ? 'Výsledky zatím nejsou.'
                  : 'Výsledky z webu: ${freshnessLabel(result.fetchedAt, now)}',
              style: theme.textTheme.bodySmall,
            )
          else
            const SizedBox.shrink(),
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
  /// Souboje „Rozbalit vše“ / „Sbalit vše“ on the right, on the same row —
  /// the switch has no check icon, so on a 360dp phone both fit up to text
  /// scale 1.3. With larger text the button drops under the switch instead
  /// of overflowing (OverflowBar: a row pushed apart when both fit, else a
  /// column).
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
      child: OverflowBar(
        alignment: MainAxisAlignment.spaceBetween,
        spacing: 8,
        overflowSpacing: 4,
        children: [
          SegmentedButton<MatchDetailView>(
            showSelectedIcon: false,
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
  /// then the Družstva card. Without a lineup there are no duel cards (the
  /// scoreboard says why); the Družstva card still shows the team sums.
  List<Widget> _souboje({
    required List<Duel> duels,
    required MatchResult? result,
    required Color homeColor,
    required Color awayColor,
  }) {
    final scale = diffScale(duels);
    return [
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
            showSetPoints: setPointsMatter(result?.discipline),
          ),
        ),
      if (result != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: TeamTotalsCard(
            result: result,
            homeColor: homeColor,
            awayColor: awayColor,
            showSetPoints: setPointsMatter(result.discipline),
          ),
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
    final leagueSlug = widget.competitionSlug;
    final isLeague = leagueSlug != null;
    // One source of the match: our slots, or (a foreign match) its
    // competition's league matches.
    final slots = ref.watch(prioritySlotsProvider);
    final leagueAsync = isLeague ? ref.watch(leagueMatchesProvider(leagueSlug)) : null;
    LeagueMatch? leagueMatch;
    for (final l in leagueAsync?.value ?? const <LeagueMatch>[]) {
      if (l.id == widget.matchId) leagueMatch = l;
    }
    // A foreign match that meanwhile became one of ours (the league row is
    // gone, a slot with its site id is there): show our slot.
    PrioritySlot? becameOurs;
    if (isLeague && leagueMatch == null && widget.siteMatchId != null) {
      for (final s in slots) {
        if (s.siteMatchId == widget.siteMatchId) becameOurs = s;
      }
    }
    final fromLeague = isLeague && becameOurs == null;
    _resolvedId = becameOurs?.id;
    final slotsLoading = fromLeague
        ? !(leagueAsync?.hasValue ?? false)
        : ref.watch(prioritySlotsLoadingProvider);
    final resultsAsync = ref.watch(matchResultsProvider);
    final results = resultsAsync.value ?? const <String, MatchResult>{};
    final result = fromLeague ? leagueMatch?.result : results[_matchId];
    final playersAsync = fromLeague
        ? ref.watch(leaguePlayerResultsProvider(widget.matchId))
        : ref.watch(matchPlayerResultsProvider(_matchId));
    final players = playersAsync.value ?? const <MatchPlayerResult>[];
    final playersLoading = !playersAsync.hasValue && !playersAsync.hasError;
    final venues = ref.watch(venuesProvider).value ?? const <Venue>[];
    final view = ref.watch(matchDetailViewProvider);
    var teamColors =
        ref.watch(myTeamColorsProvider).value ?? const <String, int>{};
    if (fromLeague) {
      // A side takes the viewer's team colour only when it IS one of our
      // teams (active or not) — a foreign team that shares a followed
      // team's name stays neutral.
      final ours = {
        for (final t in ref.watch(teamsProvider).value ?? const <Team>[])
          t.name,
      };
      teamColors = {
        for (final e in teamColors.entries)
          if (ours.contains(e.key)) e.key: e.value,
      };
    }

    PrioritySlot? slot = leagueMatch?.asSlot() ?? becameOurs;
    if (!isLeague) {
      for (final s in slots) {
        if (s.id == widget.matchId) {
          slot = s;
          break;
        }
      }
    }
    bool liveNow(PrioritySlot slot) => isLive(slot, result, now);
    // A foreign match is not polled: its stored status may be a day behind,
    // so it can be asked for outside the live window too (0055).
    final askable = leagueMatch?.refreshable(now) ?? false;

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
        (fromLeague || resultsAsync.hasValue) &&
        slot != null) {
      _didOpenRefresh = true;
      // Live, or a finished foreign match whose player lines were never
      // fetched: asking is what queues the fetch (refresh_match, 0055).
      if (liveNow(slot) || askable || (leagueMatch?.needsDetail ?? false)) {
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
    final live = slot != null && liveNow(slot);
    final showRefreshButton = (live || askable) && !_hiddenByNotLive;

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
              playersLoading: playersLoading,
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
    required bool playersLoading,
    required Venue? venueMatch,
    required MatchDetailView view,
    required Map<String, int> teamColors,
    required DateTime now,
    required bool live,
    required bool pullToRefresh,
  }) {
    final theme = Theme.of(context);
    // The viewer's own colour for a team (the one Výsledky and the calendar
    // use), else green for home and red for the guests.
    final homeColor =
        googleEventColorOf(teamColors[slot.homeTeam]) ?? homeSideColor;
    final awayColor =
        googleEventColorOf(teamColors[slot.awayTeam]) ?? awaySideColor;
    final duels = duelsOf(players);

    final children = <Widget>[
      for (final child in [
        MatchScoreboard(
          slot: slot,
          result: result,
          players: players,
          playersLoading: playersLoading,
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
        // Na webu ČKA is on the same row, at the right (alone while live).
        if (result == null || !live || slot.siteUrl != null)
          _freshnessRow(theme, slot.siteUrl, result, live, now),
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
          // scroll. Without a lineup it still shows its team summary row
          // (as long as `result` has team-level data).
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

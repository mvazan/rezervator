/// Klubovna's "Výsledky" screen (Task 3): the season's federation matches of
/// our teams, by day, with scores, live state and video — the read-only
/// counterpart to Můj přehled's own-team timeline. „Soutěže“ (0055) lists
/// one whole competition instead, by round, the matches of the other teams
/// included.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/clock.dart';
import '../../data/live_refresh.dart';
import '../../data/local_prefs.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import '../../domain/results.dart';
import '../../domain/upcoming.dart' show matchColorOf;
import '../schedule/my_trainings_screen.dart' show MatchTrophy;
import 'match_detail_screen.dart';
import 'widgets/match_title.dart';
import 'widgets/match_video_icon.dart';
import '../../core/push_screen.dart';

class ResultsScreen extends ConsumerStatefulWidget {
  const ResultsScreen({
    super.key,
    this.refreshMatch = _refreshMatch,
    this.launch = _launch,
  });

  /// Injectable so widget tests never reach Supabase or the platform.
  final Future<String> Function(String matchId, {bool force}) refreshMatch;
  final void Function(String url) launch;

  static Future<String> _refreshMatch(String matchId, {bool force = false}) =>
      Api.refreshMatch(matchId, force: force);
  static void _launch(String url) => launchWeb(url);

  @override
  ConsumerState<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends ConsumerState<ResultsScreen> {
  String? _team;
  bool _scrolledToRecentResults = false;
  bool _didLiveRefreshCheck = false;

  /// Which list the two latches above were set for ('t' = the teams view,
  /// 'c' + the competition's slug). The saved mode and competition are
  /// seeded before runApp ([loadPersistedResultsView]), but the competition
  /// list itself (teams) can still arrive late, so the list can change under
  /// the latches — a new list scrolls and looks for live matches afresh.
  String? _listKey;

  /// The app coming back from the background: the open-time poke of live /
  /// refreshable matches is worth doing again (the server still gates it at
  /// five minutes). Only that latch — the list keeps its scroll position.
  StreamSubscription<void>? _wake;

  @override
  void initState() {
    super.initState();
    _wake = LiveRefresh.stream.listen((_) {
      if (mounted) setState(() => _didLiveRefreshCheck = false);
    });
  }

  @override
  void dispose() {
    unawaited(_wake?.cancel());
    super.dispose();
  }

  // A day (Day) or a round ('round:N') → its header's key.
  final Map<Object, GlobalKey> _sectionKeys = {};
  final Map<String, GlobalKey> _matchKeys = {};

  GlobalKey _keyFor(Object section) =>
      _sectionKeys.putIfAbsent(section, GlobalKey.new);
  GlobalKey _matchKeyFor(String matchId) =>
      _matchKeys.putIfAbsent(matchId, GlobalKey.new);

  /// The same key [_matchKeyFor] hands a match's `ListTile` — a public hook
  /// on this otherwise-private State so a test can locate one match's row
  /// by id via `find.byKey(...)` (rows have no other way to tell two
  /// same-titled fixtures apart) without reaching into a private member.
  @visibleForTesting
  GlobalKey? debugMatchKey(String matchId) => _matchKeys[matchId];

  void _selectAll() => setState(() {
    _team = null;
    _scrolledToRecentResults = false;
  });

  void _selectTeam(String team) => setState(() {
    _team = team;
    _scrolledToRecentResults = false;
  });

  void _selectMode(ResultsMode mode) {
    unawaited(ref.read(resultsModeProvider.notifier).set(mode));
  }

  void _selectCompetition(String slug) {
    unawaited(ref.read(resultsCompetitionProvider.notifier).set(slug));
  }

  static String _dayLabel(Day date, Day today) {
    if (date == today) return 'Dnes';
    if (date == today.addDays(1)) return 'Zítra';
    return dayFull(date);
  }

  /// [competitionSlug]: set for a match of other teams (0055) — the detail
  /// then reads it from `league_matches`.
  static void _openMatch(
    BuildContext context,
    PrioritySlot slot, {
    String? competitionSlug,
  }) => pushScreen(context, (_) => MatchDetailScreen(
        matchId: slot.id,
        competitionSlug: competitionSlug,
        siteMatchId: slot.siteMatchId,
      ));

  /// The matches worth refreshing now: ours while they are live, a league
  /// match ([refreshableForeign] holds their ids) in its refresh window —
  /// nothing polls it, so its stored status may be a day behind.
  static List<PrioritySlot> _liveMatches(
    List<_Section> sections,
    Map<String, MatchResult> results,
    DateTime now, {
    Set<String> foreignIds = const {},
    Set<String> refreshableForeign = const {},
  }) => [
    for (final section in sections)
      for (final slot in section.matches)
        if (foreignIds.contains(slot.id)
            ? refreshableForeign.contains(slot.id)
            : isLive(slot, results[slot.id], now))
          slot,
  ];

  // The open-time auto-refresh is a background poke, not a user action, so
  // its errors are logged and swallowed rather than shown — and a plain
  // try/catch (unlike Future.catchError) never trips over the actual
  // reified Future<T> not matching an onError handler's return type.
  Future<void> _refreshQuietly(String matchId) async {
    try {
      await widget.refreshMatch(matchId);
    } catch (e) {
      debugPrint('Výsledky: auto-refresh of $matchId failed: $e');
    }
  }

  Future<void> _refresh(BuildContext context, List<PrioritySlot> live) async {
    if (live.isEmpty) {
      snack(context, 'Nic právě neprobíhá.');
      return;
    }
    await tryAction(
      context,
      () =>
          Future.wait([
            for (final slot in live) widget.refreshMatch(slot.id, force: true),
          ]),
      errorText: friendlyDbError,
    );
  }

  Widget _modeSwitch(ResultsMode mode) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
    child: SegmentedButton<ResultsMode>(
      showSelectedIcon: false,
      segments: const [
        ButtonSegment(value: ResultsMode.teams, label: Text('Oddíly')),
        ButtonSegment(value: ResultsMode.competitions, label: Text('Soutěže')),
      ],
      selected: {mode},
      onSelectionChanged: (chosen) => _selectMode(chosen.first),
    ),
  );

  Widget _competitionChips(
    List<({String slug, String name})> competitions,
    String selected,
  ) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          for (final (i, c) in competitions.indexed) ...[
            if (i > 0) const SizedBox(width: 8),
            ChoiceChip(
              label: Text(c.name),
              selected: c.slug == selected,
              onSelected: (_) => _selectCompetition(c.slug),
            ),
          ],
        ],
      ),
    );
  }

  Widget _filterChips(List<String> teams) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          ChoiceChip(
            label: const Text('Vše'),
            selected: _team == null,
            onSelected: (_) => _selectAll(),
          ),
          for (final team in teams) ...[
            const SizedBox(width: 8),
            ChoiceChip(
              label: Text(team),
              selected: _team == team,
              onSelected: (_) => _selectTeam(team),
            ),
          ],
        ],
      ),
    );
  }

  Widget _matchTile(
    BuildContext context,
    PrioritySlot slot,
    MatchResult? result,
    DateTime now,
    List<String> followedTeams,
    List<String> calendarTeams,
    Map<String, int> teamColors,
    Map<String, bool> exceptions, {
    // Competition view: the round is in the header; a league match
    // (foreign) has no home/away for us, and takes a team colour only from
    // a side that is one of OUR teams ([ourTeamNames], active or not).
    bool inCompetition = false,
    Set<String> ourTeamNames = const {},
    bool foreign = false,
    String? competitionSlug,
  }) {
    final theme = Theme.of(context);
    final competitionPart = inCompetition
        ? ''
        : [
            if ((slot.competition ?? '').isNotEmpty) slot.competition!,
            if (slot.round != null) '${slot.round}. kolo',
          ].join(', ');
    final subtitle = [
      slot.timeKnown ? slot.startsAt.display() : 'čas bude upřesněn',
      if (competitionPart.isNotEmpty) competitionPart,
      if (!foreign) slot.isAway ? 'venku' : 'doma',
      if (foreign && (slot.venue ?? '').isNotEmpty) slot.venue!,
    ].join(' · ');
    final pins = result == null
        ? ''
        : pinsLabel(result.homeTotal, result.awayTotal);

    // A foreign team that merely shares a followed / calendar team's name
    // stays neutral: only names of our own teams count on a league tile.
    final colorId = foreign
        ? matchColorOf(
            slot,
            [
              for (final t in followedTeams)
                if (ourTeamNames.contains(t)) t,
            ],
            teamColors,
            calendarTeams: [
              for (final t in calendarTeams)
                if (ourTeamNames.contains(t)) t,
            ],
          )
        : matchColorOf(
            slot,
            followedTeams,
            teamColors,
            calendarTeams: calendarTeams,
            exceptions: exceptions,
          );
    return ListTile(
      key: _matchKeyFor(slot.id),
      leading: MatchLeading(
        slot: slot,
        result: result,
        now: now,
        linksEnabled: true,
        fallback: MatchTrophy(colorId: colorId),
        colorId: colorId,
        launch: widget.launch,
      ),
      title: MatchTitle(slot: slot, winner: displayWinner(result)),
      subtitle: Text(subtitle),
      // Scaled down as one piece when large text makes the score wider than
      // its share of the row (it overflowed at text scale 2.0).
      trailing: ExcludeSemantics(
        // A bare „–“ (no points yet) is not worth reading out.
        excluding:
            result?.homePoints == null && result?.awayPoints == null && pins.isEmpty,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 110),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  pointsLabel(result?.homePoints, result?.awayPoints),
                  style: theme.textTheme.titleMedium,
                ),
                if (pins.isNotEmpty)
                  Text(pins, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ),
      ),
      onTap: () =>
          _openMatch(context, slot, competitionSlug: foreign ? competitionSlug : null),
    );
  }

  @override
  Widget build(BuildContext context) {
    final now = ref.watch(nowProvider).value ?? DateTime.now();
    final today = Day.fromDateTime(now);
    final slots = ref.watch(prioritySlotsProvider);
    final slotsLoading = ref.watch(prioritySlotsLoadingProvider);
    final resultsAsync = ref.watch(matchResultsProvider);
    final results = resultsAsync.value ?? const <String, MatchResult>{};
    final ourTeams = ref.watch(ourTeamsProvider);
    final profile = ref.watch(myProfileProvider).value;
    final followedTeams = profile?.followedTeams ?? const <String>[];
    final teamColors =
        ref.watch(myTeamColorsProvider).value ?? const <String, int>{};
    final calendarTeams = <String>[
      for (final c
          in ref.watch(myCalendarTeamsProvider).value ?? const <CalendarTeam>[])
        c.team,
    ];
    final exceptions =
        ref.watch(myMatchExceptionsProvider).value ?? const <String, bool>{};

    final competitions = ref.watch(leagueCompetitionsProvider);
    final savedMode = ref.watch(resultsModeProvider);
    final mode = competitions.isEmpty ? ResultsMode.teams : savedMode;
    final inCompetitions = mode == ResultsMode.competitions;
    final pickedSlug = ref.watch(resultsCompetitionProvider);
    final slug = !inCompetitions
        ? ''
        : competitions.any((c) => c.slug == pickedSlug)
        ? pickedSlug!
        : competitions.first.slug;
    // Streamed only while looking at it; the teams view watches nothing extra.
    final leagueAsync = inCompetitions
        ? ref.watch(leagueMatchesProvider(slug))
        : const AsyncData<List<LeagueMatch>>([]);
    final league = leagueAsync.value ?? const <LeagueMatch>[];
    // Nothing cached and the stream failed (offline): our own matches of the
    // competition are shown anyway, with a note instead of a spinner.
    final leagueFailed =
        inCompetitions && !leagueAsync.hasValue && leagueAsync.hasError;
    final leagueLoading =
        inCompetitions && !leagueAsync.hasValue && !leagueAsync.hasError;
    // Until the teams are known the switch may still appear above the list
    // (and shift it): nothing scrolls before that.
    final teams = ref.watch(teamsProvider);
    final teamsSettled = teams.hasValue || teams.hasError;
    final ourTeamNames = {for (final t in teams.value ?? const <Team>[]) t.name};
    // A list that changed under the latches (the teams — hence the
    // competitions — arriving late) gets them afresh.
    final listKey = inCompetitions ? 'c:$slug' : 't';
    if (_listKey != listKey) {
      _listKey = listKey;
      _scrolledToRecentResults = false;
      _didLiveRefreshCheck = false;
    }

    // The list, as sections (a day, or a round) of matches — one renderer
    // for both views.
    final bool anyMatches;
    final List<_Section> sections;
    var listResults = results;
    var foreignIds = const <String>{};
    var refreshableForeign = const <String>{};
    if (inCompetitions) {
      final cm = competitionMatches(slots, league, slug);
      foreignIds = cm.foreignIds;
      refreshableForeign = {
        for (final l in league)
          if (l.refreshable(now)) l.id,
      };
      // Our results and the foreign ones (their totals ride on the row).
      listResults = {...results, for (final l in league) l.id: l.result};
      anyMatches = cm.matches.isNotEmpty;
      sections = [
        for (final g in competitionRounds(cm.matches))
          (
            id: 'round:${g.round}',
            label: roundLabel(g),
            date: g.first,
            matches: g.matches,
          ),
      ];
    } else {
      anyMatches = resultsTimeline(
        slots: slots,
        mineOnly: false,
        followedTeams: const [],
        exceptions: const {},
      ).isNotEmpty;
      sections = [
        for (final d in resultsTimeline(
          slots: slots,
          team: _team,
          mineOnly: false,
          followedTeams: const [],
          exceptions: const {},
        ))
          (
            id: d.day,
            label: _dayLabel(d.day, today),
            date: d.day,
            matches: d.matches,
          ),
      ];
    }
    final loading = slotsLoading || leagueLoading;

    // Once per list (and again after the app woke), past the first real snapshot of BOTH inputs
    // — slots is a plain Provider that reads `[]` before its own stream
    // (prioritySlotsLoadingProvider's own signal) has delivered, so gating
    // on the results stream alone would let this latch on an empty list
    // and never see a live match that only shows up once slots catches up.
    if (!_didLiveRefreshCheck &&
        !loading &&
        teamsSettled &&
        resultsAsync.hasValue) {
      _didLiveRefreshCheck = true;
      final live = _liveMatches(
        sections,
        listResults,
        now,
        foreignIds: foreignIds,
        refreshableForeign: refreshableForeign,
      );
      if (live.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          for (final slot in live) {
            unawaited(_refreshQuietly(slot.id));
          }
        });
      }
    }

    // Waits for resultsAsync.hasValue too (not just slots):
    // mostRecentDecidedInOrder reads `results`, so latching this on the
    // pre-stream `{}` snapshot would scroll to the fallback and never
    // revisit once the real results (and any decided match) arrive.
    if (!loading &&
        teamsSettled &&
        resultsAsync.hasValue &&
        !_scrolledToRecentResults) {
      final recentMatchId = mostRecentDecidedInOrder([
        for (final section in sections) ...section.matches,
      ], listResults, today);
      final todayIdx = sections.indexWhere((s) => !s.date.isBefore(today));
      final fallbackIdx = todayIdx >= 0 ? todayIdx : sections.length - 1;
      if (recentMatchId != null) {
        _scrolledToRecentResults = true;
        // Bottom-aligned: the whole viewport fills with recent, decided
        // results — only scrolling DOWN from here reveals what's still
        // ahead, same idea as `alignment: 0` used to top-align the day
        // header, just anchored at the match itself now instead of its day.
        final key = _matchKeyFor(recentMatchId);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final ctx = key.currentContext;
          if (ctx != null) {
            Scrollable.ensureVisible(
              ctx,
              alignment: 1,
              duration: Duration.zero,
            );
          }
        });
      } else if (fallbackIdx >= 0) {
        // Nothing decided yet — same top-aligned fallback as before this
        // feature existed.
        _scrolledToRecentResults = true;
        final key = _keyFor(sections[fallbackIdx].id);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final ctx = key.currentContext;
          if (ctx != null) {
            Scrollable.ensureVisible(
              ctx,
              alignment: 0,
              duration: Duration.zero,
            );
          }
        });
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Výsledky')),
      body: Column(
        children: [
          if (competitions.isNotEmpty) _modeSwitch(mode),
          if (inCompetitions)
            _competitionChips(competitions, slug)
          else
            _filterChips(ourTeams),
          if (leagueFailed)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(
                'Zápasy ostatních družstev se nepodařilo načíst.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : !anyMatches && leagueFailed
                ? const SizedBox.shrink()
                : !anyMatches
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        inCompetitions
                            ? 'Soutěž zatím nemá žádné zápasy.'
                            : 'Zatím žádné zápasy — správce zapne stahování v '
                                  'Správa → Oddíly.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : sections.isEmpty
                ? const Center(child: Text('Žádné zápasy pro tento výběr.'))
                : RefreshIndicator(
                    onRefresh: () {
                      // A failed league stream is re-subscribed at once.
                      if (leagueFailed) {
                        ref.invalidate(leagueMatchesProvider(slug));
                      }
                      return _refresh(
                        context,
                        _liveMatches(
                          sections,
                          listResults,
                          now,
                          foreignIds: foreignIds,
                          refreshableForeign: refreshableForeign,
                        ),
                      );
                    },
                    // A plain, eagerly built scroll view (not a lazy
                    // ListView) — a season's federation matches for one
                    // alley are few enough that building them all is
                    // cheap, and Scrollable.ensureVisible below needs the
                    // target header's element to already exist, which a
                    // lazily built Sliver would not guarantee on the
                    // first frame.
                    child: SingleChildScrollView(
                      key: const Key('results-list'),
                      // Without this, a short list (content shorter than the
                      // viewport) never reports the overscroll RefreshIndicator
                      // needs to arm — a well-known SingleChildScrollView/
                      // RefreshIndicator gotcha.
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final section in sections) ...[
                            Padding(
                              key: _keyFor(section.id),
                              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                              child: Text(
                                section.label,
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                            ),
                            for (final slot in section.matches)
                              _matchTile(
                                context,
                                slot,
                                listResults[slot.id],
                                now,
                                followedTeams,
                                calendarTeams,
                                teamColors,
                                exceptions,
                                inCompetition: inCompetitions,
                                ourTeamNames: ourTeamNames,
                                foreign: foreignIds.contains(slot.id),
                                competitionSlug: slug,
                              ),
                          ],
                        ],
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// A block of the list: a day (teams view) or a round (competition view).
typedef _Section = ({
  Object id,
  String label,
  Day date,
  List<PrioritySlot> matches,
});

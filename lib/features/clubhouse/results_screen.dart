/// Klubovna's "Výsledky" screen (Task 3): the season's federation matches of
/// our teams, by day, with scores, live state and video — the read-only
/// counterpart to Můj přehled's own-team timeline.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/clock.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import '../../domain/results.dart';
import '../../domain/upcoming.dart' show matchColorOf;
import '../schedule/my_trainings_screen.dart' show MatchTrophy;

class ResultsScreen extends ConsumerStatefulWidget {
  const ResultsScreen({
    super.key,
    this.refreshMatch = _refreshMatch,
    this.launch = _launch,
  });

  /// Injectable so widget tests never reach Supabase or the platform.
  final Future<String> Function(String matchId) refreshMatch;
  final void Function(String url) launch;

  static Future<String> _refreshMatch(String matchId) =>
      Api.refreshMatch(matchId);
  static void _launch(String url) => launchWeb(url);

  @override
  ConsumerState<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends ConsumerState<ResultsScreen> {
  bool _mine = false;
  String? _team;
  bool _filterTouched = false;
  bool _scrolledToToday = false;
  bool _didLiveRefreshCheck = false;
  final Map<Day, GlobalKey> _dayKeys = {};

  GlobalKey _keyFor(Day day) => _dayKeys.putIfAbsent(day, GlobalKey.new);

  void _selectMine() => setState(() {
    _filterTouched = true;
    _mine = true;
    _team = null;
  });

  void _selectAll() => setState(() {
    _filterTouched = true;
    _mine = false;
    _team = null;
  });

  void _selectTeam(String team) => setState(() {
    _filterTouched = true;
    _mine = false;
    _team = team;
  });

  static String _dayLabel(Day date, Day today) {
    if (date == today) return 'Dnes';
    if (date == today.addDays(1)) return 'Zítra';
    return dayFull(date);
  }

  static void _openMatch(BuildContext context, PrioritySlot slot) =>
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => Scaffold(appBar: AppBar(title: Text(slot.title))),
        ),
      );

  static List<PrioritySlot> _liveMatches(
    List<({Day day, List<PrioritySlot> matches})> days,
    Map<String, MatchResult> results,
    DateTime now,
  ) => [
    for (final day in days)
      for (final slot in day.matches)
        if (isLive(slot, results[slot.id], now)) slot,
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
          Future.wait([for (final slot in live) widget.refreshMatch(slot.id)]),
    );
  }

  Widget _filterChips(
    bool mineAvailable,
    bool effectiveMine,
    List<String> teams,
  ) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          if (mineAvailable) ...[
            ChoiceChip(
              label: const Text('Moje'),
              selected: effectiveMine && _team == null,
              onSelected: (_) => _selectMine(),
            ),
            const SizedBox(width: 8),
          ],
          ChoiceChip(
            label: const Text('Vše'),
            selected: !effectiveMine && _team == null,
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
    Map<String, int> teamColors,
    Map<String, bool> exceptions,
  ) {
    final theme = Theme.of(context);
    final live = isLive(slot, result, now);
    final competitionPart = [
      if ((slot.competition ?? '').isNotEmpty) slot.competition!,
      if (slot.round != null) '${slot.round}. kolo',
    ].join(', ');
    final subtitle = [
      slot.startsAt.display(),
      if (competitionPart.isNotEmpty) competitionPart,
      slot.isAway ? 'venku' : 'doma',
    ].join(' · ');
    final points = result == null
        ? '–'
        : pointsLabel(result.homePoints, result.awayPoints);
    final pins = result == null
        ? ''
        : pinsLabel(result.homeTotal, result.awayTotal);

    return ListTile(
      leading: MatchTrophy(
        colorId: matchColorOf(
          slot,
          followedTeams,
          teamColors,
          exceptions: exceptions,
        ),
      ),
      title: Text(slot.title),
      subtitle: Text(subtitle),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (slot.videoUrl case final url?)
            IconButton(
              icon: const Icon(Icons.play_circle_outline),
              tooltip: 'Video',
              onPressed: () => widget.launch(url),
            ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    points,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (live)
                    Text(
                      ' • probíhá',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                ],
              ),
              if (pins.isNotEmpty) Text(pins, style: theme.textTheme.bodySmall),
            ],
          ),
        ],
      ),
      onTap: () => _openMatch(context, slot),
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
    final exceptions =
        ref.watch(myMatchExceptionsProvider).value ?? const <String, bool>{};

    final mineAvailable = followedTeams.isNotEmpty;
    final effectiveMine = _filterTouched ? _mine : mineAvailable;

    final anyFederationMatches = resultsTimeline(
      slots: slots,
      mineOnly: false,
      followedTeams: const [],
      exceptions: const {},
    ).isNotEmpty;

    final days = resultsTimeline(
      slots: slots,
      team: _team,
      mineOnly: effectiveMine,
      followedTeams: followedTeams,
      exceptions: exceptions,
    );

    // Once per screen lifetime, past the first real snapshot of BOTH inputs
    // — slots is a plain Provider that reads `[]` before its own stream
    // (prioritySlotsLoadingProvider's own signal) has delivered, so gating
    // on the results stream alone would let this latch on an empty list
    // and never see a live match that only shows up once slots catches up.
    if (!_didLiveRefreshCheck && !slotsLoading && resultsAsync.hasValue) {
      _didLiveRefreshCheck = true;
      final live = _liveMatches(days, results, now);
      if (live.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          for (final slot in live) {
            unawaited(_refreshQuietly(slot.id));
          }
        });
      }
    }

    final todayIdx = todayIndex(days, today);
    if (!slotsLoading && !_scrolledToToday && todayIdx >= 0) {
      _scrolledToToday = true;
      final key = _keyFor(days[todayIdx].day);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = key.currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(ctx, alignment: 0, duration: Duration.zero);
        }
      });
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Výsledky')),
      body: Column(
        children: [
          _filterChips(mineAvailable, effectiveMine, ourTeams),
          Expanded(
            child: slotsLoading
                ? const Center(child: CircularProgressIndicator())
                : !anyFederationMatches
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Zatím žádné zápasy — správce zapne stahování v '
                        'Správa → Oddíly.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : days.isEmpty
                ? const Center(child: Text('Žádné zápasy pro tento výběr.'))
                : RefreshIndicator(
                    onRefresh: () =>
                        _refresh(context, _liveMatches(days, results, now)),
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
                          for (final day in days) ...[
                            Padding(
                              key: _keyFor(day.day),
                              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                              child: Text(
                                _dayLabel(day.day, today),
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                            ),
                            for (final slot in day.matches)
                              _matchTile(
                                context,
                                slot,
                                results[slot.id],
                                now,
                                followedTeams,
                                teamColors,
                                exceptions,
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

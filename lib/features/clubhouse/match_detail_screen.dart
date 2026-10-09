/// Klubovna's match detail (Task 4): one federation match's score, team
/// stats, players with a per-lane breakdown, video/web links and a live
/// refresh — pushed from `results_screen.dart`'s row tap.
///
/// Top to bottom: the scoreboard (with how old the score is and the match's
/// page on the site), the video button when it is not in the scoreboard,
/// and the match drawn the way the device's owner chose for the way it is
/// held (Můj profil → Detail zápasu, [matchLayoutPrefsProvider]): the duel
/// cards and the Družstva card, scrolling ([MatchLayout.full]); the duels
/// fitted to the screen with the scoreboard pinned on top
/// ([MatchLayout.compact], [MatchLayout.table] — the kiosk's drawings,
/// `duels_compact.dart`); or, held sideways only, the kuzelky.com-style
/// score sheet ([MatchLayout.zapis]) full screen in place of the detail the
/// moment the phone turns ([ZapisPage]), gone when it turns back.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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
import 'widgets/duels_compact.dart';
import 'widgets/match_scoreboard.dart';
import 'widgets/team_totals_card.dart';
import 'widgets/zapis_page.dart';
import '../../core/push_screen.dart';

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

class _MatchDetailScreenState extends ConsumerState<MatchDetailScreen>
    with SingleTickerProviderStateMixin {
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

  /// Set when the Zápis shown on a turn to landscape was closed by its ×
  /// while the phone stayed sideways: the detail then shows until the next
  /// turn instead of the sheet coming back.
  bool _zapisDismissed = false;

  /// 0 = the detail, 1 = the Zápis: the cross-fade of a turn of the phone.
  /// Started a frame after the one that built the sheet — the first frame
  /// of a turn is slow (the sheet and the detail laid out at the new
  /// size), and an animation started in a slow frame jumps to its end.
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );

  /// Whether the sheet is wanted now, and the last one built — it stays up
  /// while it fades out.
  bool? _sheetWanted;
  Widget? _sheetPage;

  void _fadeTo(bool sheet) {
    if (_sheetWanted == null) {
      // The first build: no animation, straight to what is wanted.
      _sheetWanted = sheet;
      _fade.value = sheet ? 1 : 0;
      return;
    }
    if (_sheetWanted == sheet) return;
    _sheetWanted = sheet;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      if (!mounted) return;
      if (_sheetWanted == true) {
        unawaited(_fade.forward());
      } else {
        unawaited(_fade.reverse());
      }
    });
  }

  @override
  void dispose() {
    _fade.dispose();
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

  /// The video button is the scoreboard's status while the match is live
  /// or recorded („Sledovat živě“ / „Záznam“ say what „Živě“ / „Dokončeno“
  /// did); in any other state the chip stays and the button sits below it.
  bool _videoInScoreboard(PrioritySlot slot, MatchResult? result, bool live) =>
      slot.videoUrl != null && (live || result?.status == MatchStatus.finished);

  Widget _videoButton(
    BuildContext context,
    String videoUrl,
    MatchResult? result,
    bool live,
  ) {
    final recorded =
        result?.status == MatchStatus.finished ||
        result?.status == MatchStatus.forfeit;
    return FilledButton.icon(
      style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
      onPressed: () => widget.launch(videoUrl),
      icon: live
          ? Icon(
              Icons.circle,
              size: 12,
              color: Theme.of(context).colorScheme.error,
            )
          : const Icon(Icons.play_circle_fill),
      label: Text(live ? 'Sledovat živě' : (recorded ? 'Záznam' : 'Video')),
    );
  }

  Widget _buttonsRow(
    BuildContext context,
    PrioritySlot slot,
    MatchResult? result,
    bool live,
  ) {
    final videoUrl = slot.videoUrl;
    if (videoUrl == null || _videoInScoreboard(slot, result, live)) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Wrap(
        spacing: 8,
        children: [_videoButton(context, videoUrl, result, live)],
      ),
    );
  }

  /// „Rozbalit vše“ / „Sbalit vše“ at the right, over the scrolling cards
  /// (the fitted layouts fold cards to fit, so they have no such button).
  Widget _expandAllRow(List<Duel> duels) {
    // A duel nobody has started never opens: it neither needs the button
    // nor keeps it from reading „Sbalit vše“ once the rest are open.
    final openable = [
      for (final duel in duels)
        if (duel.state != DuelState.waiting) duel.position,
    ];
    if (openable.isEmpty) return const SizedBox.shrink();
    final allOpen = openable.every(_expanded.contains);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Align(
        alignment: Alignment.centerRight,
        child: TextButton(
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
    final leagueAsync = isLeague
        ? ref.watch(leagueMatchesProvider(leagueSlug))
        : null;
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
    final lineup = playersAsync.value ?? const <MatchPlayerResult>[];
    final playersLoading = !playersAsync.hasValue && !playersAsync.hasError;
    final venues = ref.watch(venuesProvider).value ?? const <Venue>[];
    // The match drawn the way the owner wants it for this way of holding
    // the device; sideways with Zápis the sheet opens on its own and what
    // is under it is the upright choice.
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final layoutPrefs = ref.watch(matchLayoutPrefsProvider);
    final layout = landscape ? layoutPrefs.landscape : layoutPrefs.portrait;
    final inlineLayout = layout == MatchLayout.zapis
        ? layoutPrefs.portrait
        : layout;
    final players = lineup;

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
    // A finished match can still be corrected on the site; nothing polls for
    // that, so the button asks (0062).
    final correctable = slot != null && isCorrectable(slot, result, now);
    final showRefreshButton =
        (live || askable || correctable) && !_hiddenByNotLive;

    if (!landscape) _zapisDismissed = false;
    // Held sideways with the Zápis chosen, the sheet takes the whole screen
    // in place of the detail — chosen in the very frame of the turn, so the
    // detail is never drawn sideways on its own, and the two cross-fade.
    final sheet =
        layout == MatchLayout.zapis &&
        players.isNotEmpty &&
        slot != null &&
        !_zapisDismissed;

    _fadeTo(sheet);
    if (sheet) {
      _sheetPage = ZapisPage(
        slot: slot,
        closeButton: true,
        competitionSlug: fromLeague ? widget.competitionSlug : null,
        withRegnums: true,
        onClose: () => setState(() => _zapisDismissed = true),
      );
    }

    final detail = Scaffold(
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
              layout: inlineLayout,
              now: now,
              live: live,
              // Pulling is the ⟳ button's twin: gone together once a
              // refresh has answered not_live.
              pullToRefresh: showRefreshButton,
            ),
    );
    // The detail stays built under the sheet (hidden once the sheet is
    // whole), so the turn back has nothing to build; the sheet fades in
    // over it and out again.
    return AnimatedBuilder(
      animation: _fade,
      builder: (context, _) {
        final sheetUp =
            _sheetPage != null && (_sheetWanted == true || _fade.value > 0);
        return Stack(
          fit: StackFit.expand,
          children: [
            Offstage(offstage: _fade.value == 1, child: detail),
            if (sheetUp) FadeTransition(opacity: _fade, child: _sheetPage),
          ],
        );
      },
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
    required MatchLayout layout,
    required DateTime now,
    required bool live,
    required bool pullToRefresh,
  }) {
    // Always green for the hosts and red for the guests — never a team's
    // own colour, so a side reads the same on every match.
    const homeColor = homeSideColor;
    const awayColor = awaySideColor;
    final duels = duelsOf(players);
    final videoInScoreboard = _videoInScoreboard(slot, result, live);

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
              : () => pushScreen(
                  context,
                  (_) => VenueDetailScreen(slug: venueMatch.slug),
                ),
          onSiteTap: slot.siteUrl == null
              ? null
              : () => widget.launch(slot.siteUrl!),
          homeColor: homeColor,
          awayColor: awayColor,
          video: videoInScoreboard
              ? _videoButton(context, slot.videoUrl!, result, live)
              : null,
        ),
        _buttonsRow(context, slot, result, live),
        if (layout == MatchLayout.full) _expandAllRow(duels),
      ])
        _centred(child),
    ];

    if (layout == MatchLayout.compact || layout == MatchLayout.table) {
      return _fitted(
        context,
        layout: layout,
        header: Column(mainAxisSize: MainAxisSize.min, children: children),
        duels: duels,
        result: result,
        pullToRefresh: pullToRefresh,
      );
    }

    children.addAll(switch (layout) {
      MatchLayout.full ||
      MatchLayout.compact ||
      MatchLayout.table ||
      MatchLayout.zapis => [
        for (final child in _souboje(
          duels: duels,
          result: result,
          homeColor: homeColor,
          awayColor: awayColor,
        ))
          _centred(child),
      ],
    });

    final list = ListView(
      // Keeps the scroll offset when the pull-to-refresh around the list
      // comes or goes (a match that ends while watched): the list is then
      // rebuilt under a new parent and would start from the top again.
      key: const PageStorageKey('match-detail'),
      // A short list (no lineup yet) still has to pull.
      physics: pullToRefresh ? const AlwaysScrollableScrollPhysics() : null,
      padding: padWithSystemInset(context, const EdgeInsets.only(bottom: 24)),
      children: children,
    );
    if (!pullToRefresh) return list;
    return RefreshIndicator(
      // The ⟳ button's twin: the same forced refresh, the same waiting.
      onRefresh: () => _onRefreshTap(context, result?.fetchedAt),
      child: list,
    );
  }

  /// The compact or table layout: [header] (the scoreboard and its rows)
  /// pinned, the duels fitted under it — the kiosk's drawing, as wide as
  /// the list but at most 720dp like the rest, and with the list's pull.
  /// Held sideways there is no height for both: the header then goes to
  /// the left of the duels, scrolling on its own.
  Widget _fitted(
    BuildContext context, {
    required MatchLayout layout,
    required Widget header,
    required List<Duel> duels,
    required MatchResult? result,
    required bool pullToRefresh,
  }) {
    final padding = padWithSystemInset(
      context,
      const EdgeInsets.fromLTRB(12, 2, 12, 24),
    );
    Future<void> refresh() => _onRefreshTap(context, result?.fetchedAt);
    Widget fitted(Widget? pinned) => switch (layout) {
      MatchLayout.compact => DuelsCompact(
        duels: duels,
        result: result,
        singleOpen: true,
        header: pinned,
        listPadding: padding,
        onRefresh: pullToRefresh ? refresh : null,
      ),
      MatchLayout.table || MatchLayout.full || MatchLayout.zapis => DuelsTable(
        duels: duels,
        result: result,
        singleOpen: true,
        header: pinned,
        listPadding: padding,
        onRefresh: pullToRefresh ? refresh : null,
      ),
    };
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth > constraints.maxHeight) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 4,
                child: SingleChildScrollView(
                  padding: padWithSystemInset(
                    context,
                    const EdgeInsets.only(bottom: 12),
                  ),
                  child: header,
                ),
              ),
              Expanded(flex: 5, child: fitted(null)),
            ],
          );
        }
        return Center(
          child: SizedBox(
            width: math.min(constraints.maxWidth, 720),
            height: constraints.maxHeight,
            child: fitted(header),
          ),
        );
      },
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/ui.dart' show dayFull;
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/clubhouse/match_detail_screen.dart';
import 'package:rezervator/features/clubhouse/results_screen.dart';
import 'package:rezervator/features/schedule/my_trainings_screen.dart'
    show MatchTrophy;

void main() {
  final now = DateTime(2026, 9, 23, 18, 0); // středa
  final today = Day.fromDateTime(now);
  const veverky = 'SKK Veverky Brno A';
  const souperA = 'KK MS Brno D';
  const souperB = 'TJ Sokol Řečkovice B';

  const meFollows = Profile(
    id: 'me',
    displayName: 'Já Hráč',
    email: 'me@example.com',
    role: Role.player,
    status: ProfileStatus.approved,
    followedTeams: [veverky],
  );
  const meFollowsNothing = Profile(
    id: 'me',
    displayName: 'Já Hráč',
    email: 'me@example.com',
    role: Role.player,
    status: ProfileStatus.approved,
  );

  PrioritySlot match({
    required String id,
    required Day date,
    String home = veverky,
    String away = souperA,
    String? videoUrl,
    String? competition,
    int? round,
    bool isAway = false,
  }) => PrioritySlot(
    id: id,
    date: date,
    startsAt: const HourMinute(17, 30),
    endsAt: const HourMinute(20, 30),
    type: PrioritySlot.fallbackMatchType,
    homeTeam: home,
    awayTeam: away,
    importKey: 'cka:$id',
    videoUrl: videoUrl,
    competition: competition,
    round: round,
    isAway: isAway,
  );

  final finishedYesterday = match(id: 'm1', date: today.addDays(-1));
  final finishedResult = MatchResult.fromJson(const {
    'match_id': 'm1',
    'status': 'finished',
    'home_points': 5,
    'away_points': 3,
    'home_total': 3460,
    'away_total': 3349,
    'fetched_at': '2026-09-22T21:00:00+00:00',
  });

  final liveToday = match(
    id: 'm2',
    date: today,
    away: souperB,
    videoUrl: 'https://vysledky.kuzelky.cz/video/m2',
    competition: 'KP1 Sever',
    round: 5,
  );
  final liveResult = MatchResult.fromJson(const {
    'match_id': 'm2',
    'status': 'in_progress',
    'fetched_at': '2026-09-23T17:40:00+00:00',
  });

  final futureNoResult = match(id: 'm3', date: today.addDays(5), away: souperB);

  MatchResult liveResultFor(String matchId) => MatchResult.fromJson({
    'match_id': matchId,
    'status': 'in_progress',
    'fetched_at': '2026-09-23T17:40:00+00:00',
  });

  // A test-only StreamProvider our own prioritySlotsProvider/
  // prioritySlotsLoadingProvider overrides can watch, so a test can flip
  // "still loading" -> "loaded" mid-lifetime the same way the real
  // _prioritySlotRowsProvider does — without touching Supabase.
  final testSlotsStreamProvider = StreamProvider<List<PrioritySlot>>(
    (ref) => const Stream.empty(),
  );

  Widget app({
    Profile profile = meFollows,
    List<PrioritySlot> slots = const [],
    Stream<List<PrioritySlot>>? slotsStream,
    Map<String, MatchResult> results = const {},
    List<String> teams = const [veverky, souperA],
    Map<String, int> teamColors = const {},
    Map<String, bool> exceptions = const {},
    List<CalendarTeam> calendarTeams = const [],
    Future<String> Function(String matchId)? refreshMatch,
    void Function(String url)? launch,
  }) {
    return ProviderScope(
      overrides: [
        myProfileProvider.overrideWith((ref) => Stream.value(profile)),
        if (slotsStream != null) ...[
          testSlotsStreamProvider.overrideWith((ref) => slotsStream),
          prioritySlotsProvider.overrideWith(
            (ref) => ref.watch(testSlotsStreamProvider).value ?? const [],
          ),
          prioritySlotsLoadingProvider.overrideWith((ref) {
            final v = ref.watch(testSlotsStreamProvider);
            return v.isLoading && !v.hasValue;
          }),
        ] else ...[
          prioritySlotsProvider.overrideWithValue(slots),
          prioritySlotsLoadingProvider.overrideWithValue(false),
        ],
        matchResultsProvider.overrideWith((ref) => Stream.value(results)),
        // MatchDetailScreen (pushed on row tap) watches these two as well.
        matchPlayerResultsProvider.overrideWith(
          (ref, id) => Stream.value(const []),
        ),
        venuesProvider.overrideWith((ref) => Stream.value(const [])),
        ourTeamsProvider.overrideWithValue(teams),
        myTeamColorsProvider.overrideWith((ref) => Stream.value(teamColors)),
        myMatchExceptionsProvider.overrideWith(
          (ref) => Stream.value(exceptions),
        ),
        myCalendarTeamsProvider.overrideWith(
          (ref) => Stream.value(calendarTeams),
        ),
        nowProvider.overrideWith((ref) => Stream.value(now)),
      ],
      // Disables MatchLeading's pulsing ring for a live match — a repeating
      // AnimationController never settles on its own, which would hang
      // every pumpAndSettle below; none of these tests exercise the pulse
      // itself (that lives in match_video_icon_test.dart).
      child: MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: ResultsScreen(
              refreshMatch: refreshMatch ?? (_) async => 'not_live',
              launch: launch ?? (_) {},
            ),
          ),
        ),
      ),
    );
  }

  testWidgets(
      'an excepted derby of a Kalendář-only team wears that team\'s colour, '
      'not the uncoloured home side\'s', (tester) async {
    final derby = match(
      id: 'derby',
      date: today.addDays(-2),
      home: 'KS Devítka Brno A',
      away: veverky,
    );
    await tester.pumpWidget(app(
      profile: meFollowsNothing,
      slots: [derby],
      teams: const ['KS Devítka Brno A', veverky],
      teamColors: const {veverky: 9},
      exceptions: const {'derby': true},
      calendarTeams: const [CalendarTeam(team: veverky)],
    ));
    await tester.pumpAndSettle();

    expect(tester.widget<MatchTrophy>(find.byType(MatchTrophy)).colorId, 9);
  });

  testWidgets('Vše is selected by default, whatever the player follows', (
    tester,
  ) async {
    await tester.pumpWidget(app(slots: [finishedYesterday]));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ChoiceChip, 'Moje'), findsNothing);
    final vse = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, 'Vše'),
    );
    expect(vse.selected, isTrue);
  });

  testWidgets('a team chip filters to just that team\'s matches', (
    tester,
  ) async {
    final otherTeamMatch = match(
      id: 'm4',
      date: today.addDays(1),
      home: souperA,
      away: souperB,
    );
    await tester.pumpWidget(
      app(
        slots: [finishedYesterday, otherTeamMatch],
        results: {'m1': finishedResult},
      ),
    );
    await tester.pumpAndSettle();
    // The default is already Vše — the whole season shows with no filter
    // tap needed.
    expect(find.text('$veverky – $souperA'), findsOneWidget);
    expect(find.text('$souperA – $souperB'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, souperA));
    await tester.pumpAndSettle();

    expect(find.text('$veverky – $souperA'), findsOneWidget);
    expect(find.text('$souperA – $souperB'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, veverky));
    await tester.pumpAndSettle();

    expect(find.text('$veverky – $souperA'), findsOneWidget);
    expect(find.text('$souperA – $souperB'), findsNothing);
  });

  testWidgets('a finished match shows its points and pins', (tester) async {
    await tester.pumpWidget(
      app(slots: [finishedYesterday], results: {'m1': finishedResult}),
    );
    await tester.pumpAndSettle();

    expect(find.text('5 : 3'), findsOneWidget);
    expect(find.text('3460 : 3349'), findsOneWidget);
  });

  testWidgets('a future match without a result shows a dash', (tester) async {
    await tester.pumpWidget(app(slots: [futureNoResult]));
    await tester.pumpAndSettle();

    expect(find.text('–'), findsOneWidget);
  });

  testWidgets(
    'the winning side\'s team NAME gets the fixed w800 weight, the score '
    'never gets winner-conditional styling',
    (tester) async {
      await tester.pumpWidget(
        app(slots: [finishedYesterday], results: {'m1': finishedResult}),
      );
      await tester.pumpAndSettle();

      // The score is a single plain Text(pointsLabel(...), style: ...) — no
      // per-side branching in the code to test; both digits necessarily
      // share the one style regardless of who won.
      final scoreText = tester.widget<Text>(find.text('5 : 3'));
      expect(
        scoreText.style,
        Theme.of(tester.element(find.text('5 : 3'))).textTheme.titleMedium,
      );

      final titleText = tester.widget<Text>(find.text('$veverky – $souperA'));
      final spans = (titleText.textSpan! as TextSpan).children!
          .cast<TextSpan>();
      expect(spans[0].style?.fontWeight, FontWeight.w800, reason: 'home won');
      // Explicitly w400 (not just "not w800") — a plain ambient/null style
      // would also satisfy `isNot(w800)` without proving the loser was
      // actually lightened (Fix round 1).
      expect(spans[1].style?.fontWeight, FontWeight.w400, reason: 'separator');
      expect(spans[2].style?.fontWeight, FontWeight.w400, reason: 'away lost');
    },
  );

  testWidgets(
    'a draw or a match with no result renders with no weighted winner '
    'name',
    (tester) async {
      await tester.pumpWidget(app(slots: [futureNoResult]));
      await tester.pumpAndSettle();

      // No result at all — MatchTitle falls back to a plain Text, same as
      // find.text always matched before this batch. Style is exactly
      // null (the ambient default), not forced to w400 either (Fix
      // round 1: a "no winner" match must stay fully unstyled).
      final titleText = tester.widget<Text>(find.text('$veverky – $souperB'));
      expect(titleText.textSpan, isNull);
      expect(titleText.style, isNull);
    },
  );

  testWidgets('subtitle shows time, competition, round and doma/venku', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(slots: [liveToday], results: {'m2': liveResult}),
    );
    await tester.pumpAndSettle();

    expect(find.text('17:30 · KP1 Sever, 5. kolo · doma'), findsOneWidget);
  });

  testWidgets(
    'a live match shows the videocam badge (tooltip Živý přenos), which '
    'launches the video url',
    (tester) async {
      final launched = <String>[];
      await tester.pumpWidget(
        app(
          slots: [liveToday],
          results: {'m2': liveResult},
          launch: launched.add,
        ),
      );
      await tester.pumpAndSettle();

      final button = find.widgetWithIcon(IconButton, Icons.videocam);
      expect(button, findsOneWidget);
      expect(tester.widget<IconButton>(button).tooltip, 'Živý přenos');
      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(launched, ['https://vysledky.kuzelky.cz/video/m2']);
    },
  );

  testWidgets('a finished match with a video shows the play_circle_fill badge '
      '(tooltip Záznam) in place of the trophy', (tester) async {
    final finishedWithVideo = match(
      id: 'm6',
      date: today.addDays(-1),
      videoUrl: 'https://vysledky.kuzelky.cz/video/m6',
    );
    final finishedResultWithVideo = MatchResult.fromJson(const {
      'match_id': 'm6',
      'status': 'finished',
      'home_points': 5,
      'away_points': 3,
      'fetched_at': '2026-09-22T21:00:00+00:00',
    });
    await tester.pumpWidget(
      app(slots: [finishedWithVideo], results: {'m6': finishedResultWithVideo}),
    );
    await tester.pumpAndSettle();

    final button = find.widgetWithIcon(IconButton, Icons.play_circle_fill);
    expect(button, findsOneWidget);
    expect(tester.widget<IconButton>(button).tooltip, 'Záznam');
  });

  testWidgets('opening the screen with a live match refreshes it once', (
    tester,
  ) async {
    final refreshed = <String>[];
    await tester.pumpWidget(
      app(
        slots: [finishedYesterday, liveToday],
        results: {'m1': finishedResult, 'm2': liveResult},
        refreshMatch: (id) async {
          refreshed.add(id);
          return 'queued';
        },
      ),
    );
    await tester.pumpAndSettle();
    // A later rebuild (Realtime-style emission of the same data) must not
    // refresh again — only the first arrival triggers it.
    await tester.pump();
    await tester.pumpAndSettle();

    expect(refreshed, ['m2']);
  });

  testWidgets('pull-to-refresh refreshes every live match in the filter', (
    tester,
  ) async {
    final refreshed = <String>[];
    await tester.pumpWidget(
      app(
        slots: [liveToday],
        results: {'m2': liveResult},
        refreshMatch: (id) async {
          refreshed.add(id);
          return 'queued';
        },
      ),
    );
    await tester.pumpAndSettle();
    refreshed.clear(); // drop the open-time refresh, isolate the pull

    await tester.fling(
      find.byKey(const Key('results-list')),
      const Offset(0, 300),
      1000,
    );
    await tester.pumpAndSettle();

    expect(refreshed, ['m2']);
  });

  testWidgets('pull-to-refresh with nothing live shows a snackbar', (
    tester,
  ) async {
    await tester.pumpWidget(app(slots: [finishedYesterday]));
    await tester.pumpAndSettle();

    await tester.fling(
      find.byKey(const Key('results-list')),
      const Offset(0, 300),
      1000,
    );
    await tester.pumpAndSettle();

    expect(find.text('Nic právě neprobíhá.'), findsOneWidget);
  });

  testWidgets('a failed pull-to-refresh shows the Czech error copy', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        slots: [liveToday],
        results: {'m2': liveResult},
        refreshMatch: (_) async => throw Exception('not_allowed'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.fling(
      find.byKey(const Key('results-list')),
      const Offset(0, 300),
      1000,
    );
    await tester.pumpAndSettle();

    expect(find.text('Na tohle nemáš oprávnění.'), findsOneWidget);
  });

  testWidgets('no federation matches at all shows the admin hint', (
    tester,
  ) async {
    await tester.pumpWidget(app(slots: const []));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Zatím žádné zápasy — správce zapne stahování v Správa → '
        'Oddíly.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a filter yielding nothing shows the filter-specific message', (
    tester,
  ) async {
    const noMatchTeam = 'HKK Havířov C';
    await tester.pumpWidget(
      app(
        profile: meFollowsNothing,
        slots: [finishedYesterday],
        teams: const [veverky, souperA, noMatchTeam],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ChoiceChip, noMatchTeam));
    await tester.pumpAndSettle();

    expect(find.text('Žádné zápasy pro tento výběr.'), findsOneWidget);
  });

  testWidgets(
    'with nothing decided yet, scrolls to today\'s header with earlier days '
    'scrolled above',
    (tester) async {
      // A couple of scheduled (undecided) days behind today, and plenty of
      // scheduled ones ahead — that way there is enough content BELOW
      // today's row for the scroll to actually reach top alignment instead
      // of clamping at the list's own end (which would leave today's header
      // lower on screen, still visible but not pinned to the top).
      final pastMatches = [
        for (var i = 2; i >= 1; i--)
          match(id: 'past$i', date: today.addDays(-i)),
      ];
      final futureMatches = [
        for (var i = 1; i <= 10; i++)
          match(id: 'future$i', date: today.addDays(i)),
      ];
      await tester.pumpWidget(
        app(slots: [...pastMatches, liveToday, ...futureMatches]),
      );
      await tester.pumpAndSettle();

      final earliestHeader = tester.getTopLeft(
        find.text(dayFull(today.addDays(-2))),
      );
      final todayHeader = tester.getTopLeft(find.text('Dnes'));
      // Scrolled well above the viewport (chips + app bar sit around y=100).
      expect(earliestHeader.dy, lessThan(0));
      // Aligned to the top of the scrollable area, just below chips/app bar.
      expect(todayHeader.dy, inInclusiveRange(0, 200));
    },
  );

  testWidgets(
    'with a decided past match, scrolls so ITS row sits at the BOTTOM of '
    'the viewport — the whole screen fills with recent results, only '
    'scrolling down reveals what\'s still ahead',
    (tester) async {
      // Plenty of UNDECIDED days well before the decided one (today-12..-3)
      // — enough content ABOVE the anchor for a genuine bottom-alignment
      // scroll to have somewhere to scroll FROM (a decided match with
      // nothing above it would clamp at scroll offset 0, same as any
      // top-of-list target — this fixture rules that degenerate case out).
      // today-2 is decided (finished); today-1 and today itself are still
      // undecided — mostRecentDecidedMatchId must land on today-2's own
      // row, bottom-aligned, not on any day header top-aligned.
      final earlierMatches = [
        for (var i = 12; i >= 3; i--)
          match(id: 'earlier$i', date: today.addDays(-i)),
      ];
      final decided = match(id: 'decided', date: today.addDays(-2));
      final undecidedYesterday = match(
        id: 'undecided1',
        date: today.addDays(-1),
      );
      final futureMatches = [
        for (var i = 1; i <= 10; i++)
          match(id: 'future$i', date: today.addDays(i)),
      ];
      final decidedResult = MatchResult.fromJson(const {
        'match_id': 'decided',
        'status': 'finished',
        'home_points': 5,
        'away_points': 3,
        'fetched_at': '2026-09-20T21:00:00+00:00',
      });
      await tester.pumpWidget(
        app(
          slots: [
            ...earlierMatches,
            decided,
            undecidedYesterday,
            liveToday,
            ...futureMatches,
          ],
          results: {'decided': decidedResult},
        ),
      );
      await tester.pumpAndSettle();

      // The debugMatchKey hook is the only way to tell same-titled fixture
      // rows (identical default home/away) apart — see its own doc comment.
      final state = tester.state(find.byType(ResultsScreen)) as dynamic;
      final GlobalKey key = state.debugMatchKey('decided') as GlobalKey;
      final rowBottom = tester.getBottomLeft(find.byKey(key));
      final listBottom = tester
          .getBottomLeft(find.byKey(const Key('results-list')))
          .dy;

      // Bottom-aligned: the row's own bottom edge sits on the bottom of the
      // scrollable viewport — not centred, not pinned near the top.
      expect(rowBottom.dy, closeTo(listBottom, 1.0));

      // The earliest day (today-12) is scrolled well above the viewport —
      // real scrolling happened, not a no-op left at the list's own top.
      final earliestHeader = tester.getTopLeft(
        find.text(dayFull(today.addDays(-12))),
      );
      expect(earliestHeader.dy, lessThan(0));
    },
  );

  testWidgets(
    'choosing a team chip re-anchors on THAT team\'s most recent decided '
    'match, bottom-aligned, instead of keeping the unfiltered offset',
    (tester) async {
      MatchResult finished(String id) => MatchResult.fromJson({
        'match_id': id,
        'status': 'finished',
        'home_points': 5,
        'away_points': 3,
        'fetched_at': '2026-09-20T21:00:00+00:00',
      });
      final ourEarlier = [
        for (var i = 45; i >= 36; i--)
          match(id: 'ourEarlier$i', date: today.addDays(-i)),
      ];
      final others = [
        for (var i = 35; i >= 3; i--)
          match(
            id: 'other$i',
            date: today.addDays(-i),
            home: souperA,
            away: souperB,
          ),
      ];
      final ourDecided = match(id: 'ourDecided', date: today.addDays(-2));
      final otherLatest = match(
        id: 'otherLatest',
        date: today.addDays(-1),
        home: souperA,
        away: souperB,
      );
      final ourFuture = [
        for (var i = 1; i <= 30; i++)
          match(id: 'ourFuture$i', date: today.addDays(i)),
      ];
      await tester.pumpWidget(
        app(
          slots: [
            ...ourEarlier,
            ...others,
            ourDecided,
            otherLatest,
            ...ourFuture,
          ],
          results: {
            for (final s in [...ourEarlier, ...others, ourDecided, otherLatest])
              s.id: finished(s.id),
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(ChoiceChip, veverky));
      await tester.pumpAndSettle();

      final state = tester.state(find.byType(ResultsScreen)) as dynamic;
      final GlobalKey key = state.debugMatchKey('ourDecided') as GlobalKey;
      final row = tester.getRect(find.byKey(key));
      final viewport = tester.getRect(find.byKey(const Key('results-list')));

      expect(row.top, greaterThanOrEqualTo(viewport.top));
      expect(row.bottom, lessThanOrEqualTo(viewport.bottom));
      expect(row.bottom, greaterThan(viewport.top + viewport.height * 0.7));
      expect(
        tester.getTopLeft(find.text(dayFull(today.addDays(-45)))).dy,
        lessThan(viewport.top),
      );
    },
  );

  testWidgets('tapping a row opens the match detail screen', (tester) async {
    await tester.pumpWidget(app(slots: [finishedYesterday]));
    await tester.pumpAndSettle();

    await tester.tap(find.text('$veverky – $souperA'));
    await tester.pumpAndSettle();

    expect(find.byType(MatchDetailScreen), findsOneWidget);
    // No competition/round on this fixture — the title falls back to the
    // match's own title, same as the row it was opened from.
    expect(find.widgetWithText(AppBar, '$veverky – $souperA'), findsOneWidget);
  });

  testWidgets(
    'while slots are still loading shows a progress indicator, never the '
    'no-matches empty state',
    (tester) async {
      final slotsCtrl = StreamController<List<PrioritySlot>>();
      addTearDown(slotsCtrl.close);
      // No pumpAndSettle: the indicator's animation never settles on its own —
      // a single frame already flushes the other overridden streams, leaving
      // only the slots stream genuinely stuck loading.
      await tester.pumpWidget(app(slotsStream: slotsCtrl.stream));

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        find.text(
          'Zatím žádné zápasy — správce zapne stahování v Správa → '
          'Oddíly.',
        ),
        findsNothing,
      );
    },
  );

  testWidgets(
    'the once-only live refresh waits for slots to finish loading, not '
    'just for results to arrive',
    (tester) async {
      // Regression for a real bug: matchResultsProvider alone can settle
      // before prioritySlotsProvider's own stream delivers its first
      // snapshot (which still reads `[]` while loading) — gating the
      // one-time check on results only would let it latch on an empty
      // list and never see the live match once slots actually load.
      final refreshed = <String>[];
      final slotsCtrl = StreamController<List<PrioritySlot>>();
      addTearDown(slotsCtrl.close);
      await tester.pumpWidget(
        app(
          slotsStream: slotsCtrl.stream,
          results: {'m2': liveResultFor('m2')},
          refreshMatch: (id) async {
            refreshed.add(id);
            return 'queued';
          },
        ),
      );
      await tester.pump();
      expect(refreshed, isEmpty);

      slotsCtrl.add([liveToday]);
      await tester.pumpAndSettle();

      expect(refreshed, ['m2']);

      // A later emission of the same data must not refresh again.
      slotsCtrl.add([liveToday]);
      await tester.pumpAndSettle();

      expect(refreshed, ['m2']);
    },
  );

  testWidgets(
    'two simultaneous live matches are each refreshed exactly once on '
    'open',
    (tester) async {
      final refreshed = <String>[];
      final liveToday2 = match(
        id: 'm5',
        date: today,
        home: souperA,
        away: souperB,
      );
      await tester.pumpWidget(
        app(
          profile: meFollowsNothing,
          slots: [liveToday, liveToday2],
          results: {'m2': liveResultFor('m2'), 'm5': liveResultFor('m5')},
          refreshMatch: (id) async {
            refreshed.add(id);
            return 'queued';
          },
        ),
      );
      await tester.pumpAndSettle();
      // A later rebuild must not refresh either match again.
      await tester.pump();
      await tester.pumpAndSettle();

      expect(refreshed..sort(), ['m2', 'm5']);
    },
  );

  testWidgets(
    'two simultaneous live matches are each refreshed exactly once on '
    'pull-to-refresh',
    (tester) async {
      final refreshed = <String>[];
      final liveToday2 = match(
        id: 'm5',
        date: today,
        home: souperA,
        away: souperB,
      );
      await tester.pumpWidget(
        app(
          profile: meFollowsNothing,
          slots: [liveToday, liveToday2],
          results: {'m2': liveResultFor('m2'), 'm5': liveResultFor('m5')},
          refreshMatch: (id) async {
            refreshed.add(id);
            return 'queued';
          },
        ),
      );
      await tester.pumpAndSettle();
      refreshed.clear(); // drop the open-time refresh, isolate the pull

      await tester.fling(
        find.byKey(const Key('results-list')),
        const Offset(0, 300),
        1000,
      );
      await tester.pumpAndSettle();

      expect(refreshed..sort(), ['m2', 'm5']);
    },
  );

  testWidgets(
    'a failed open-time auto-refresh does not throw an unhandled error',
    (tester) async {
      // Regression: the fire-and-forget refresh call must swallow its own
      // errors — a rejected Future left unawaited-and-unhandled would surface
      // as a test failure (and in the real app, an ugly zone error) even
      // though nothing here is a user action that should show a snackbar.
      await tester.pumpWidget(
        app(
          slots: [liveToday],
          results: {'m2': liveResultFor('m2')},
          refreshMatch: (_) async => throw StateError('boom'),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    },
  );
}

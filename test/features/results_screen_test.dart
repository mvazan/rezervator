import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/ui.dart' show dayFull;
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/clubhouse/results_screen.dart';

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

  Widget app({
    Profile profile = meFollows,
    List<PrioritySlot> slots = const [],
    Map<String, MatchResult> results = const {},
    List<String> teams = const [veverky, souperA],
    Map<String, int> teamColors = const {},
    Map<String, bool> exceptions = const {},
    Future<String> Function(String matchId)? refreshMatch,
    void Function(String url)? launch,
  }) {
    return ProviderScope(
      overrides: [
        myProfileProvider.overrideWith((ref) => Stream.value(profile)),
        prioritySlotsProvider.overrideWithValue(slots),
        matchResultsProvider.overrideWith((ref) => Stream.value(results)),
        ourTeamsProvider.overrideWithValue(teams),
        myTeamColorsProvider.overrideWith((ref) => Stream.value(teamColors)),
        myMatchExceptionsProvider.overrideWith(
          (ref) => Stream.value(exceptions),
        ),
        nowProvider.overrideWith((ref) => Stream.value(now)),
      ],
      child: MaterialApp(
        home: ResultsScreen(
          refreshMatch: refreshMatch ?? (_) async => 'not_live',
          launch: launch ?? (_) {},
        ),
      ),
    );
  }

  testWidgets('Moje is selected by default when the player follows a team', (
    tester,
  ) async {
    await tester.pumpWidget(app(slots: [finishedYesterday]));
    await tester.pumpAndSettle();

    final moje = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, 'Moje'),
    );
    expect(moje.selected, isTrue);
    final vse = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, 'Vše'),
    );
    expect(vse.selected, isFalse);
  });

  testWidgets('Vše is selected by default when the player follows no team', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(profile: meFollowsNothing, slots: [finishedYesterday]),
    );
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
    // The default follows the player's own team (veverky), which hides
    // otherTeamMatch — switch to Vše first to see the whole season.
    await tester.tap(find.widgetWithText(ChoiceChip, 'Vše'));
    await tester.pumpAndSettle();

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

  testWidgets('a live match shows the probíhá marker next to the points', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(slots: [liveToday], results: {'m2': liveResult}),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('probíhá'), findsOneWidget);
  });

  testWidgets('subtitle shows time, competition, round and doma/venku', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(slots: [liveToday], results: {'m2': liveResult}),
    );
    await tester.pumpAndSettle();

    expect(find.text('17:30 · KP1 Sever, 5. kolo · doma'), findsOneWidget);
  });

  testWidgets('a video icon button launches the video url', (tester) async {
    final launched = <String>[];
    await tester.pumpWidget(
      app(
        slots: [liveToday],
        results: {'m2': liveResult},
        launch: launched.add,
      ),
    );
    await tester.pumpAndSettle();

    final button = find.widgetWithIcon(IconButton, Icons.play_circle_outline);
    expect(button, findsOneWidget);
    expect(tester.widget<IconButton>(button).tooltip, 'Video');
    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(launched, ['https://vysledky.kuzelky.cz/video/m2']);
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
    'scrolls so today\'s header is visible with earlier finished days '
    'scrolled above',
    (tester) async {
      // A couple of finished days behind today, and plenty of scheduled ones
      // ahead — that way there is enough content BELOW today's row for the
      // scroll to actually reach top alignment instead of clamping at the
      // list's own end (which would leave today's header lower on screen,
      // still visible but not pinned to the top).
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

  testWidgets('tapping a row pushes a placeholder titled after the match', (
    tester,
  ) async {
    await tester.pumpWidget(app(slots: [finishedYesterday]));
    await tester.pumpAndSettle();

    await tester.tap(find.text('$veverky – $souperA'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, '$veverky – $souperA'), findsOneWidget);
  });
}

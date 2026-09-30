import 'dart:async';


import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/cache.dart';
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/local_prefs.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/clubhouse/match_detail_screen.dart';
import 'package:rezervator/features/clubhouse/results_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _LateMode extends ResultsModeNotifier {
  _LateMode(this.gate);
  final Future<ResultsMode> gate;
  @override
  ResultsMode build() {
    gate.then((m) {
      if (ref.mounted) state = m;
    });
    return ResultsMode.teams;
  }
}

void main() {
  final now = DateTime(2026, 9, 23, 18, 0);
  final today = Day.fromDateTime(now);
  const veverky = 'SKK Veverky Brno A';
  const souperA = 'KK MS Brno D';
  const liga = 'liga-x-2026';
  const ligaName = 'Liga X';

  const me = Profile(
    id: 'me',
    displayName: 'Já Hráč',
    email: 'me@example.com',
    role: Role.player,
    status: ProfileStatus.approved,
    followedTeams: [veverky],
  );

  PrioritySlot ourLiga(String id, Day date, int round) => PrioritySlot(
    id: id,
    date: date,
    startsAt: const HourMinute(17, 30),
    endsAt: const HourMinute(20, 30),
    type: PrioritySlot.fallbackMatchType,
    homeTeam: veverky,
    awayTeam: souperA,
    importKey: 'cka:$id',
    competition: ligaName,
    round: round,
    siteSlug: '$liga-kolo-$round-a-b',
    siteMatchId: id.hashCode & 0xffff,
  );

  MatchResult res(String id, String status) => MatchResult.fromJson({
    'match_id': id,
    'status': status,
    'home_points': status == 'finished' ? 5 : null,
    'away_points': status == 'finished' ? 3 : null,
    'fetched_at': '2026-09-23T17:40:00+00:00',
  });

  LeagueMatch foreign(
    String id,
    Day date,
    int round, {
    String home = 'KK Cizí A',
    String away = 'KK Cizí B',
    String? startsAt = '09:00:00',
    String status = 'finished',
    String comp = liga,
  }) => LeagueMatch.fromJson({
    'id': id,
    'site_match_id': id.hashCode & 0xffff | 0x10000,
    'site_slug': '$comp-kolo-$round-x-y',
    'competition_slug': comp,
    'competition': ligaName,
    'round': round,
    'date': date.toSql(),
    'starts_at': startsAt,
    'home_team': home,
    'away_team': away,
    'venue': 'Cizí kuželna',
    'status': status,
    'home_points': status == 'finished' ? 6 : null,
    'away_points': status == 'finished' ? 2 : null,
    'home_total': status == 'finished' ? 3200 : null,
    'away_total': status == 'finished' ? 3100 : null,
    'fetched_at': '2026-09-20T10:00:00+00:00',
    'detail_status': status == 'finished' ? 'finished' : null,
  });

  List<LeagueMatch> season() => [
    for (var r = 1; r <= 20; r++)
      foreign('old$r', today.addDays(-21 - 7 * (20 - r)), r),
    foreign(
      'live1',
      today,
      21,
      home: 'KK Živě A',
      away: 'KK Živě B',
      startsAt: '17:00:00',
      status: 'scheduled',
    ),
  ];

  // Our own matches of the competition: 12 finished weeks + one live today.
  final ours = [
    for (var i = 1; i <= 12; i++)
      ourLiga('mine$i', today.addDays(-7 * (13 - i)), i),
    ourLiga('mineLive', today, 21),
  ];
  final ourResults = {
    for (var i = 1; i <= 12; i++) 'mine$i': res('mine$i', 'finished'),
    'mineLive': res('mineLive', 'in_progress'),
  };

  const teamLiga = Team(
    id: 't1',
    name: veverky,
    competitionSlug: liga,
    competitionName: ligaName,
  );

  Widget app({
    Stream<List<Team>>? teams,
    Stream<List<Team>> Function()? teamsBuilder,
    required List<String> refreshed,
    Map<String, List<LeagueMatch>>? league,
    ResultsModeNotifier Function()? mode,
  }) {
    final lg = league ?? {liga: season()};
    return ProviderScope(
      overrides: [
        teamsProvider.overrideWith((ref) => teamsBuilder?.call() ?? teams!),
        if (mode != null) resultsModeProvider.overrideWith(mode),
        leagueMatchesProvider.overrideWith(
          (ref, slug) => Stream.value(lg[slug] ?? const []),
        ),
        leaguePlayerResultsProvider.overrideWith(
          (ref, id) => Stream.value(const []),
        ),
        myProfileProvider.overrideWith((ref) => Stream.value(me)),
        prioritySlotsProvider.overrideWithValue(ours),
        prioritySlotsLoadingProvider.overrideWithValue(false),
        matchResultsProvider.overrideWith((ref) => Stream.value(ourResults)),
        matchPlayerResultsProvider.overrideWith(
          (ref, id) => Stream.value(const []),
        ),
        venuesProvider.overrideWith((ref) => Stream.value(const [])),
        myTeamColorsProvider.overrideWith((ref) => Stream.value(const {})),
        myMatchExceptionsProvider.overrideWith(
          (ref) => Stream.value(const {}),
        ),
        myCalendarTeamsProvider.overrideWith(
          (ref) => Stream.value(const <CalendarTeam>[]),
        ),
        nowProvider.overrideWith((ref) => Stream.value(now)),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: ResultsScreen(
              refreshMatch: (id, {force = false}) async {
                refreshed.add(force ? '$id!' : id);
                return 'queued';
              },
              launch: (_) {},
            ),
          ),
        ),
      ),
    );
  }

  void expectOld20Visible(WidgetTester tester) {
    final state = tester.state<State>(find.byType(ResultsScreen));
    final key = (state as dynamic).debugMatchKey('old20') as GlobalKey?;
    expect(key, isNotNull, reason: 'old20 tile key');
    final rect = tester.getRect(find.byKey(key!));
    expect(rect.bottom, lessThanOrEqualTo(tester.view.physicalSize.height / tester.view.devicePixelRatio));
    expect(rect.top, greaterThan(0));
  }


  // The rect of one tile of ours, and the list's own viewport rect.
  Rect tileRect(WidgetTester tester, String id) {
    final state = tester.state<State>(find.byType(ResultsScreen));
    final key = (state as dynamic).debugMatchKey(id) as GlobalKey?;
    return tester.getRect(find.byKey(key!));
  }


  testWidgets('a foreign match detail does not claim missing lineups while its '
      'player lines load', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final lines = StreamController<List<MatchPlayerResult>>();
    addTearDown(lines.close);
    final lg = foreign('lgX', today.addDays(-2), 20);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        leagueMatchesProvider.overrideWith((ref, slug) => Stream.value([lg])),
        leaguePlayerResultsProvider.overrideWith((ref, id) => lines.stream),
        prioritySlotsProvider.overrideWithValue(const []),
        prioritySlotsLoadingProvider.overrideWithValue(false),
        matchResultsProvider.overrideWith((ref) => Stream.value(const {})),
        matchPlayerResultsProvider.overrideWith((ref, id) => Stream.value(const [])),
        venuesProvider.overrideWith((ref) => Stream.value(const [])),
        nowProvider.overrideWith((ref) => Stream.value(now)),
        myTeamColorsProvider.overrideWith((ref) => Stream.value(const {})),
      ],
      child: MaterialApp(
        home: MatchDetailScreen(
          matchId: 'lgX',
          competitionSlug: liga,
          siteMatchId: lg.siteMatchId,
          refresh: (id, {force = false}) async => 'queued',
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Sestavy zatím nejsou k dispozici.'), findsNothing);
    lines.add(const [
      MatchPlayerResult(id: 'p1', matchId: 'lgX', side: 'home', position: 1, playerName: 'Jan Cizí', total: 540),
      MatchPlayerResult(id: 'p2', matchId: 'lgX', side: 'away', position: 1, playerName: 'Petr Host', total: 500),
    ]);
    await tester.pumpAndSettle();
  });

  testWidgets('teams arrive after slots+results: saved Soutěže still scrolls '
      'and pokes the live foreign match', (tester) async {
    SharedPreferences.setMockInitialValues({
      'results_mode': 'competitions',
      'results_competition': liga,
    });
    final teamsCtl = StreamController<List<Team>>();
    addTearDown(teamsCtl.close);
    final refreshed = <String>[];
    await tester.pumpWidget(app(teams: teamsCtl.stream, refreshed: refreshed));
    await tester.pumpAndSettle();
    expect(find.text('Soutěže'), findsNothing, reason: 'no teams yet: no switch');
    teamsCtl.add([teamLiga]);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ChoiceChip, ligaName), findsOneWidget);
    expectOld20Visible(tester);
    expect(refreshed, contains('live1'));
  });

  testWidgets('the saved mode arrives after the teams view latched: the '
      'competition list scrolls and pokes afresh', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final gate = Completer<ResultsMode>();
    final refreshed = <String>[];
    await tester.pumpWidget(app(
      teams: Stream.value(const [teamLiga]),
      refreshed: refreshed,
      mode: () => _LateMode(gate.future),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Vše'), findsOneWidget);
    gate.complete(ResultsMode.competitions);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ChoiceChip, ligaName), findsOneWidget);
    expectOld20Visible(tester);
    expect(refreshed, contains('live1'));
  });

  testWidgets('a stale „scheduled“ foreign match 10 h after its start is '
      'poked from the list (refreshable, not isLive)', (tester) async {
    SharedPreferences.setMockInitialValues({
      'results_mode': 'competitions',
      'results_competition': liga,
    });
    final refreshed = <String>[];
    await tester.pumpWidget(app(
      teams: Stream.value(const [teamLiga]),
      refreshed: refreshed,
      league: {
        liga: [
          foreign('old1', today.addDays(-7), 20),
          foreign('stale1', today, 21, startsAt: '08:00:00', status: 'scheduled'),
        ],
      },
    ));
    await tester.pumpAndSettle();
    expect(refreshed, contains('stale1'));
  });

}

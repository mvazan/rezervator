import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/live_refresh.dart';
import 'package:rezervator/data/local_prefs.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/clubhouse/match_detail_screen.dart';
import 'package:rezervator/features/clubhouse/results_screen.dart';
import 'package:rezervator/features/schedule/my_trainings_screen.dart'
    show MatchTrophy;
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
    int? siteId,
  }) => LeagueMatch.fromJson({
    'id': id,
    'site_match_id': siteId ?? id.hashCode & 0xffff | 0x10000,
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
    Stream<List<LeagueMatch>> Function()? leagueBuilder,
    ResultsModeNotifier Function()? mode,
    Profile profile = me,
    Map<String, int> teamColors = const {},
    List<CalendarTeam> calendarTeams = const [],
    List<PrioritySlot>? slots,
    Map<String, MatchResult>? results,
  }) {
    final lg = league ?? {liga: season()};
    return ProviderScope(
      overrides: [
        teamsProvider.overrideWith((ref) => teamsBuilder?.call() ?? teams!),
        if (mode != null) resultsModeProvider.overrideWith(mode),
        leagueMatchesProvider.overrideWith(
          (ref, slug) =>
              leagueBuilder?.call() ?? Stream.value(lg[slug] ?? const []),
        ),
        leaguePlayerResultsProvider.overrideWith(
          (ref, id) => Stream.value(const []),
        ),
        myProfileProvider.overrideWith((ref) => Stream.value(profile)),
        prioritySlotsProvider.overrideWithValue(slots ?? ours),
        prioritySlotsLoadingProvider.overrideWithValue(false),
        matchResultsProvider.overrideWith(
          (ref) => Stream.value(results ?? ourResults),
        ),
        matchPlayerResultsProvider.overrideWith(
          (ref, id) => Stream.value(const []),
        ),
        venuesProvider.overrideWith((ref) => Stream.value(const [])),
        myTeamColorsProvider.overrideWith((ref) => Stream.value(teamColors)),
        myMatchExceptionsProvider.overrideWith(
          (ref) => Stream.value(const {}),
        ),
        myCalendarTeamsProvider.overrideWith(
          (ref) => Stream.value(calendarTeams),
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


  GlobalKey keyOf(WidgetTester tester, String id) {
    final state = tester.state<State>(find.byType(ResultsScreen));
    return (state as dynamic).debugMatchKey(id) as GlobalKey;
  }

  // The rect of one tile.
  Rect tileRect(WidgetTester tester, String id) =>
      tester.getRect(find.byKey(keyOf(tester, id)));


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
    expect(find.text('Jan Cizí'), findsWidgets, reason: 'the lines are shown');
    expect(find.text('Petr Host'), findsWidgets);
    expect(find.text('Sestavy zatím nejsou k dispozici.'), findsNothing);
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
    // Every live match once: the foreign one and ours.
    expect(refreshed, unorderedEquals(['live1', 'mineLive']));
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

  testWidgets('default Oddíly, teams arrive late: the last decided match is '
      'fully in view once the switch has appeared (P5)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final teamsCtl = StreamController<List<Team>>();
    addTearDown(teamsCtl.close);
    await tester.pumpWidget(app(teams: teamsCtl.stream, refreshed: []));
    await tester.pumpAndSettle();
    teamsCtl.add([teamLiga]);
    await tester.pumpAndSettle();
    expect(find.text('Soutěže'), findsOneWidget);
    // The switch pushed the list down by 56 px: a scroll done before the
    // teams were known would leave the target below the fold.
    final list = tester.getRect(find.byKey(const Key('results-list')));
    final t = tileRect(tester, 'mine12');
    expect(t.bottom, lessThanOrEqualTo(list.bottom + 0.5));
    expect(t.top, greaterThanOrEqualTo(list.top));
  });

  testWidgets('teams fail (offline, nothing cached): the list scrolls at once, '
      'not after the provider retries (P6)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(app(
      teamsBuilder: () => Stream.error(Exception('offline')),
      refreshed: [],
    ));
    await tester.pumpAndSettle();
    final list = tester.getRect(find.byKey(const Key('results-list')));
    final t = tileRect(tester, 'mine12');
    expect(t.bottom, lessThanOrEqualTo(list.bottom + 0.5));
    expect(t.top, greaterThanOrEqualTo(list.top));
    // Let Riverpod's retry timers run out.
    await tester.pump(const Duration(seconds: 60));
  });

  testWidgets('tapping the effective (first) competition chip persists it, so '
      'a competition that sorts earlier later does not take over (P4)',
      (tester) async {
    SharedPreferences.setMockInitialValues({'results_mode': 'competitions'});
    final teamsCtl = StreamController<List<Team>>();
    addTearDown(teamsCtl.close);
    const alfa = Team(
      id: 'a',
      name: 'A tým',
      competitionSlug: 'alfa-2026',
      competitionName: 'Alfa',
    );
    const beta = Team(
      id: 'b',
      name: 'B tým',
      competitionSlug: 'beta-2026',
      competitionName: 'Beta',
    );
    const aaa = Team(
      id: 'c',
      name: 'C tým',
      competitionSlug: 'aaa-2026',
      competitionName: 'Aaa',
    );
    await tester.pumpWidget(
      app(teams: teamsCtl.stream, refreshed: [], league: const {}),
    );
    teamsCtl.add(const [alfa, beta]);
    await tester.pumpAndSettle();
    ChoiceChip chip(String name) =>
        tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, name));
    expect(chip('Alfa').selected, isTrue);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Alfa'));
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('results_competition'), 'alfa-2026');
    teamsCtl.add(const [alfa, beta, aaa]);
    await tester.pumpAndSettle();
    expect(chip('Alfa').selected, isTrue, reason: 'the user chose Alfa');
  });

  testWidgets('detail: a foreign match that became ours is refreshed by OUR '
      'slot id, on open and by the button (P9)', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final ourSlot = PrioritySlot(
      id: 'slot1',
      date: today,
      startsAt: const HourMinute(17, 30),
      endsAt: const HourMinute(20, 30),
      type: PrioritySlot.fallbackMatchType,
      homeTeam: 'KK Cizí A',
      awayTeam: 'KK Cizí B',
      importKey: 'cka:777',
      competition: ligaName,
      round: 3,
      siteMatchId: 777,
      siteSlug: '$liga-kolo-3-a-b',
    );
    final asked = <String>[];
    await tester.pumpWidget(ProviderScope(
      overrides: [
        leagueMatchesProvider.overrideWith((ref, slug) => Stream.value(const [])),
        leaguePlayerResultsProvider.overrideWith(
          (ref, id) => Stream.value(const []),
        ),
        prioritySlotsProvider.overrideWithValue([ourSlot]),
        prioritySlotsLoadingProvider.overrideWithValue(false),
        matchResultsProvider.overrideWith(
          (ref) => Stream.value({'slot1': res('slot1', 'in_progress')}),
        ),
        matchPlayerResultsProvider.overrideWith(
          (ref, id) => Stream.value(const []),
        ),
        venuesProvider.overrideWith((ref) => Stream.value(const [])),
        nowProvider.overrideWith((ref) => Stream.value(now)),
        myTeamColorsProvider.overrideWith((ref) => Stream.value(const {})),
        teamsProvider.overrideWith((ref) => Stream.value(const <Team>[])),
      ],
      child: MaterialApp(
        home: MatchDetailScreen(
          matchId: 'lg1',
          competitionSlug: liga,
          siteMatchId: 777,
          refresh: (id, {force = false}) async {
            asked.add(force ? '$id!' : id);
            return 'queued';
          },
        ),
      ),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byTooltip('Obnovit'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(asked, ['slot1', 'slot1!']);
    await tester.pump(const Duration(seconds: 21));
  });

  testWidgets('saved Soutěže is known before the first frame (seeded like the '
      'appearance): the list never shows Oddíly and pokes each live match '
      'once, although teams and results were alive already (N3r)',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'results_mode': 'competitions',
      'results_competition': liga,
    });
    final seeded = await tester.runAsync(loadPersistedResultsView);
    final refreshed = <String>[];
    final shown = <String>[];
    await tester.pumpWidget(ProviderScope(
      overrides: [
        ...seeded!,
        teamsProvider.overrideWith((ref) => Stream.value(const [teamLiga])),
        leagueMatchesProvider.overrideWith(
          (ref, slug) => Stream.value(slug == liga ? season() : const []),
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
        myMatchExceptionsProvider.overrideWith((ref) => Stream.value(const {})),
        myCalendarTeamsProvider.overrideWith(
          (ref) => Stream.value(const <CalendarTeam>[]),
        ),
        nowProvider.overrideWith((ref) => Stream.value(now)),
      ],
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) {
            // Můj přehled keeps the results alive; Moje týmy / Správa the teams.
            ref.watch(matchResultsProvider);
            ref.watch(teamsProvider);
            ref.watch(myProfileProvider);
            ref.watch(myTeamColorsProvider);
            ref.watch(myMatchExceptionsProvider);
            ref.watch(myCalendarTeamsProvider);
            ref.watch(nowProvider);
            return TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(disableAnimations: true),
                    child: Consumer(builder: (context, ref, _) {
                      shown.add(ref.watch(resultsModeProvider).name);
                      return ResultsScreen(
                        refreshMatch: (id, {force = false}) async {
                          refreshed.add(force ? '$id!' : id);
                          return 'queued';
                        },
                        launch: (_) {},
                      );
                    }),
                  ),
                ),
              ),
              child: const Text('Výsledky'),
            );
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Výsledky'));
    await tester.pumpAndSettle();
    expect(shown.toSet(), {'competitions'}, reason: 'never a frame of Oddíly');
    expect(refreshed, unorderedEquals(['live1', 'mineLive']));
  });

  group('league tile colours', () {
    const veverkyC = 'SKK Veverky Brno C'; // a switched-off team of ours
    const kalendar = 'KK Kalendář';
    const gone = 'Bývalý tým'; // followed once, no team of ours now

    testWidgets('only a side that is one of OUR teams colours a league tile',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'results_mode': 'competitions',
        'results_competition': liga,
      });
      const profile = Profile(
        id: 'me',
        displayName: 'Já Hráč',
        email: 'me@example.com',
        role: Role.player,
        status: ProfileStatus.approved,
        followedTeams: [veverky, veverkyC, gone],
      );
      final d = today.addDays(-3);
      await tester.pumpWidget(app(
        teams: Stream.value(const [
          teamLiga,
          Team(
            id: 't3',
            name: veverkyC,
            competitionSlug: liga,
            competitionName: ligaName,
            active: false,
          ),
          Team(
            id: 't4',
            name: kalendar,
            competitionSlug: liga,
            competitionName: ligaName,
          ),
        ]),
        refreshed: [],
        profile: profile,
        teamColors: const {veverky: 5, veverkyC: 7, kalendar: 9, gone: 3},
        calendarTeams: const [CalendarTeam(team: kalendar)],
        slots: [ourLiga('mine1', d, 3)],
        results: {'mine1': res('mine1', 'finished')},
        league: {
          liga: [
            // A purely foreign match.
            foreign('f1', d, 3),
            // A switched-off team of ours: a league row, our admin's name.
            foreign('sw1', d, 3, home: veverkyC, away: 'KK Cizí D'),
            // Our active team's match with no time yet: a league row too.
            foreign('tl1', today.addDays(4), 4,
                home: veverky,
                away: 'KK Cizí E',
                startsAt: null,
                status: 'scheduled'),
            // A calendar team of ours.
            foreign('cal1', d, 3, home: 'KK Cizí F', away: kalendar),
            // Foreign teams that merely carry a name we follow / a calendar
            // name once had — not one of our teams: neutral.
            foreign('ns1', d, 3, home: 'KK Cizí G', away: gone),
          ],
        },
      ));
      await tester.pumpAndSettle();
      int? colorOf(String id) => tester
          .widget<MatchTrophy>(find.descendant(
            of: find.byKey(keyOf(tester, id)),
            matching: find.byType(MatchTrophy),
          ))
          .colorId;
      expect(colorOf('mine1'), 5, reason: 'our slot');
      expect(colorOf('f1'), isNull, reason: 'foreign');
      expect(colorOf('sw1'), 7, reason: 'switched-off team of ours');
      expect(colorOf('tl1'), 5, reason: 'our timeless match');
      expect(colorOf('cal1'), 9, reason: 'calendar team of ours');
      expect(colorOf('ns1'), isNull, reason: 'a namesake of a followed team');
    });
  });

  testWidgets('the league stream fails with nothing cached (offline): our '
      'matches of the competition are shown with a note, pulling still works',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'results_mode': 'competitions',
      'results_competition': liga,
    });
    final refreshed = <String>[];
    await tester.pumpWidget(app(
      teams: Stream.value(const [teamLiga]),
      leagueBuilder: () => Stream.error(Exception('offline')),
      refreshed: refreshed,
    ));
    // The saved mode arrives, the league stream starts and fails.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(
      find.text('Zápasy ostatních družstev se nepodařilo načíst.'),
      findsOneWidget,
    );
    expect(find.textContaining(souperA), findsWidgets, reason: 'our matches');
    expect(find.text('Soutěž zatím nemá žádné zápasy.'), findsNothing);
    // Still spinner-free later, while the provider retries.
    await tester.pump(const Duration(seconds: 30));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    unawaited(
      tester
          .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
          .show(),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(refreshed, contains('mineLive!'));
    await tester.pump(const Duration(seconds: 60));
  });

  testWidgets('the app resumes (LiveRefresh): live matches are poked again, '
      'the scroll position stays', (tester) async {
    SharedPreferences.setMockInitialValues({
      'results_mode': 'competitions',
      'results_competition': liga,
    });
    LiveRefresh.resetThrottle();
    final refreshed = <String>[];
    await tester.pumpWidget(app(
      teams: Stream.value(const [teamLiga]),
      refreshed: refreshed,
    ));
    await tester.pumpAndSettle();
    expect(refreshed, unorderedEquals(['live1', 'mineLive']));
    LiveRefresh.request();
    await tester.pumpAndSettle();
    expect(
      refreshed,
      unorderedEquals(['live1', 'mineLive', 'live1', 'mineLive']),
      reason: 'the open-time poke ran again after the wake',
    );
    expectOld20Visible(tester);
    // Not on every rebuild: only on a wake.
    await tester.pump(const Duration(seconds: 5));
    expect(refreshed, hasLength(4));
    LiveRefresh.resetThrottle();
  });

  testWidgets('competition chips are Czech-sorted (H before Ch)',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'results_mode': 'competitions',
      'results_competition': 'h-2026',
    });
    await tester.pumpWidget(app(
      teams: Stream.value(const [
        Team(
          id: 'a',
          name: 'A tým',
          competitionSlug: 'c-2026',
          competitionName: 'Chodovská liga',
        ),
        Team(
          id: 'b',
          name: 'B tým',
          competitionSlug: 'h-2026',
          competitionName: 'Hvězdná liga',
        ),
      ]),
      refreshed: [],
      league: const {},
    ));
    await tester.pumpAndSettle();
    final hvezda = tester.getTopLeft(find.widgetWithText(ChoiceChip, 'Hvězdná liga'));
    final chodov = tester.getTopLeft(find.widgetWithText(ChoiceChip, 'Chodovská liga'));
    expect(hvezda.dx, lessThan(chodov.dx));
  });

  testWidgets('a tile without points does not read a trailing dash '
      '(TalkBack)', (tester) async {
    SharedPreferences.setMockInitialValues({
      'results_mode': 'competitions',
      'results_competition': liga,
    });
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(app(
      teams: Stream.value(const [teamLiga]),
      refreshed: [],
      slots: const [],
      results: const {},
      league: {
        liga: [
          foreign('tl1', today.addDays(4), 4,
              startsAt: null, status: 'scheduled'),
          foreign('done', today.addDays(-4), 3),
        ],
      },
    ));
    await tester.pumpAndSettle();
    final unscored = tester.getSemantics(find.byKey(keyOf(tester, 'tl1'))).label;
    final scored = tester.getSemantics(find.byKey(keyOf(tester, 'done'))).label;
    expect(unscored.trim().endsWith('–'), isFalse, reason: unscored);
    expect(scored, contains('6 : 2'));
    handle.dispose();
  });
}

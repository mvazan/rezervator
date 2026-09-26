import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/local_prefs.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/duels.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/palette.dart';
import 'package:rezervator/features/clubhouse/match_detail_screen.dart';
import 'package:rezervator/features/clubhouse/venue_detail_screen.dart';
import 'package:rezervator/features/clubhouse/widgets/duel_card.dart';
import 'package:rezervator/features/clubhouse/widgets/legacy_score_sheet.dart';
import 'package:rezervator/features/clubhouse/widgets/match_scoreboard.dart';
import 'package:rezervator/features/clubhouse/widgets/team_totals_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/rudna_vrsovice.dart';

/// The Souboje/Zápis choice pinned to one view: no SharedPreferences, and a
/// switch only moves the state, so a test can read what was picked.
class _FixedView extends MatchDetailViewNotifier {
  _FixedView(this._view);

  final MatchDetailView _view;

  @override
  MatchDetailView build() => _view;

  @override
  Future<void> set(MatchDetailView view) async => state = view;
}

/// The „Zápis“ segment of the view switch (the score sheet's own heading
/// reads „Zápis“ too).
final _zapisSegment = find.descendant(
  of: find.byType(SegmentedButton<MatchDetailView>),
  matching: find.text('Zápis'),
);

/// [text] inside the scoreboard only.
Finder _inBoard(String text) => find.descendant(
  of: find.byType(MatchScoreboard),
  matching: find.text(text),
);

/// A window [width] wide and tall enough for the whole Rudná match — six
/// expanded duel cards and the Družstva card — so the list builds all of it.
void _tall(WidgetTester tester, {double width = 800}) {
  tester.view.physicalSize = Size(width, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  final now = DateTime.utc(2026, 9, 23, 18, 0);
  final today = Day.fromDateTime(now);
  const home = 'SKK Veverky Brno A';
  const away = 'KK MS Brno D';

  PrioritySlot match({
    required String id,
    required Day date,
    String? videoUrl,
    String? siteSlug,
    String? competition,
    int? round,
    String? venue,
    String? venueSlug,
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
    siteSlug: siteSlug,
    competition: competition,
    round: round,
    venue: venue,
    venueSlug: venueSlug,
  );

  final finishedResult = MatchResult.fromJson(const {
    'match_id': 'm1',
    'status': 'finished',
    'match_type': 'TEAMS_OF_6',
    'discipline': 'T120',
    'home_points': 5,
    'away_points': 3,
    'home_total': 3460,
    'away_total': 3349,
    'home_fulls': 1780,
    'away_fulls': 1700,
    'home_spares': 120,
    'away_spares': 110,
    'home_errors': 40,
    'away_errors': 35,
    'home_set_points': 15,
    'away_set_points': 9,
    'fetched_at': '2026-09-23T10:00:00+00:00',
  });

  final homePlayer = MatchPlayerResult.fromJson(const {
    'id': 'p1',
    'match_id': 'm1',
    'side': 'home',
    'position': 1,
    'player_name': 'Jan Novák',
    'fulls': 350,
    'spares': 20,
    'errors': 5,
    'total': 580,
    'set_points': 2,
    'team_points': 1,
    'lanes': [
      {
        'lane': 1,
        'fulls': 175,
        'spares': 10,
        'errors': 2,
        'total': 290,
        'setPoints': 1,
      },
      {
        'lane': 2,
        'fulls': 175,
        'spares': 10,
        'errors': 3,
        'total': 290,
        'setPoints': 1,
      },
    ],
  });

  final awayPlayer = MatchPlayerResult.fromJson(const {
    'id': 'p2',
    'match_id': 'm1',
    'side': 'away',
    'position': 1,
    'player_name': 'Petr Svoboda',
    'fulls': 340,
    'spares': 18,
    'errors': 8,
    'total': 550,
    'set_points': 0,
    'team_points': 0,
  });

  MatchResult liveResultWith({
    String status = 'in_progress',
    String fetchedAt = '2026-09-23T17:40:00+00:00',
  }) => MatchResult.fromJson({
    'match_id': 'm2',
    'status': status,
    'fetched_at': fetchedAt,
  });

  // A test-only StreamProvider our own prioritySlotsProvider/
  // prioritySlotsLoadingProvider overrides can watch, so a test can flip
  // "still loading" -> "loaded" mid-lifetime the same way the real
  // _prioritySlotRowsProvider does — without touching Supabase. Mirrors
  // results_screen_test.dart's own helper.
  final testSlotsStreamProvider = StreamProvider<List<PrioritySlot>>(
    (ref) => const Stream.empty(),
  );

  Widget app({
    String matchId = 'm1',
    List<PrioritySlot> slots = const [],
    bool slotsLoading = false,
    Stream<List<PrioritySlot>>? slotsStream,
    Map<String, MatchResult> results = const {},
    Stream<Map<String, MatchResult>>? resultsStream,
    List<MatchPlayerResult> players = const [],
    Stream<List<MatchPlayerResult>>? playersStream,
    List<Venue> venues = const [],
    Map<String, int> teamColors = const {},
    // The view the screen opens on, pinned by _FixedView; null leaves the
    // real notifier (SharedPreferences) in place.
    MatchDetailView? view = MatchDetailView.souboje,
    Future<String> Function(String matchId)? refresh,
    void Function(String url)? launch,
    // When true, MatchDetailScreen is pushed on top of a host route (via a
    // button tap) instead of being the app's own `home` — lets a test pop
    // it back off while a refresh is outstanding.
    bool pushable = false,
  }) {
    final screen = MatchDetailScreen(
      matchId: matchId,
      refresh: refresh ?? (_) async => 'queued',
      launch: launch ?? (_) {},
    );
    return ProviderScope(
      overrides: [
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
          prioritySlotsLoadingProvider.overrideWithValue(slotsLoading),
        ],
        matchResultsProvider.overrideWith(
          (ref) => resultsStream ?? Stream.value(results),
        ),
        matchPlayerResultsProvider.overrideWith(
          (ref, id) => playersStream ?? Stream.value(players),
        ),
        venuesProvider.overrideWith((ref) => Stream.value(venues)),
        nowProvider.overrideWith((ref) => Stream.value(now)),
        myTeamColorsProvider.overrideWith((ref) => Stream.value(teamColors)),
        if (view != null)
          matchDetailViewProvider.overrideWith(() => _FixedView(view)),
      ],
      child: MaterialApp(
        home: pushable
            ? Scaffold(
                body: Builder(
                  builder: (context) => Center(
                    child: ElevatedButton(
                      onPressed: () => Navigator.of(
                        context,
                      ).push(MaterialPageRoute(builder: (_) => screen)),
                      child: const Text('open'),
                    ),
                  ),
                ),
              )
            : screen,
      ),
    );
  }

  testWidgets('a finished match renders points, pins, SB and the format in the '
      'scoreboard, and the players with their lanes in either view', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        slots: [match(id: 'm1', date: today.addDays(-1))],
        results: {'m1': finishedResult},
        players: [homePlayer, awayPlayer],
      ),
    );
    await tester.pumpAndSettle();

    // The scoreboard sets the score „5 : 3“ as three Texts: the digits
    // and the colon between them.
    expect(find.byType(MatchScoreboard), findsOneWidget);
    expect(_inBoard('5'), findsOneWidget);
    expect(_inBoard(' : '), findsOneWidget);
    expect(_inBoard('3'), findsOneWidget);
    // Scoped to the scoreboard: the duel card and the score sheet's
    // summary row show team names too.
    expect(
      tester.widget<Text>(_inBoard(home)).style?.fontWeight,
      FontWeight.w800,
    );
    // Explicitly w400 (not just "not w800") — a plain ambient style
    // would also satisfy `isNot(w800)` without proving the loser was
    // actually lightened (Fix round 1).
    expect(
      tester.widget<Text>(_inBoard(away)).style?.fontWeight,
      FontWeight.w400,
    );
    // The pins with the lead between them, the set points in the
    // explanation, the status chip and the format line.
    expect(_inBoard('3460'), findsOneWidget);
    expect(_inBoard('3349'), findsOneWidget);
    expect(_inBoard('← 111'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(MatchScoreboard),
        matching: find.textContaining('SB 15 : 9'),
      ),
      findsOneWidget,
    );
    expect(_inBoard('Dokončeno'), findsOneWidget);
    expect(_inBoard('6 hráčů · 120 HS'), findsOneWidget);

    // Souboje (the default): the two players meet in duel 1.
    final duel = find.byType(DuelCard);
    expect(duel, findsOneWidget);
    expect(
      find.descendant(of: duel, matching: find.text('Jan Novák')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: duel, matching: find.text('Petr Svoboda')),
      findsOneWidget,
    );

    // Zápis: the legacy score sheet — team names (again, in the summary
    // row), player names with position prefix, and the lane totals.
    await tester.tap(_zapisSegment);
    await tester.pumpAndSettle();

    expect(find.text(home), findsNWidgets(2));
    expect(find.text(away), findsNWidgets(2));
    expect(find.text('Jan Novák'), findsOneWidget);
    expect(find.text('Petr Svoboda'), findsOneWidget);
    expect(find.text('Série hodů'), findsNWidgets(2));
    expect(find.text('290'), findsNWidgets(2));
  });

  testWidgets(
    'players section shows a message when there are none yet, but the '
    'team sums (from the result) still show — the Družstva card in '
    'Souboje, the summary row in Zápis',
    (tester) async {
      await tester.pumpWidget(
        app(
          slots: [match(id: 'm1', date: today.addDays(-1))],
          results: {'m1': finishedResult},
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(DuelCard), findsNothing);
      expect(
        find.descendant(
          of: find.byType(TeamTotalsCard),
          matching: find.text('3460'),
        ),
        findsOneWidget,
      );

      await tester.tap(_zapisSegment);
      await tester.pumpAndSettle();

      // The result has team-level data even with no lineup yet — Fix
      // round 1: this used to disappear along with the per-player section.
      final sheet = find.byType(LegacyScoreSheet);
      expect(
        find.descendant(of: sheet, matching: find.text('Zápis')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: sheet, matching: find.text('3460')),
        findsOneWidget,
      );
      expect(find.text('Jméno a příjmení hráče'), findsNothing);
    },
  );

  testWidgets('no lineup yet reads „Sestavy zatím nejsou k dispozici.“ in both '
      'views, and there is nothing to expand', (tester) async {
    const noLineup = 'Sestavy zatím nejsou k dispozici.';
    await tester.pumpWidget(
      app(
        slots: [match(id: 'm1', date: today.addDays(-1))],
        results: {'m1': finishedResult},
      ),
    );
    await tester.pumpAndSettle();

    // Souboje: no duel cards; the scoreboard says it, once.
    expect(find.byType(DuelCard), findsNothing);
    expect(_inBoard(noLineup), findsOneWidget);
    expect(find.text(noLineup), findsOneWidget);
    expect(find.text('Rozbalit vše'), findsNothing);

    await tester.tap(_zapisSegment);
    await tester.pumpAndSettle();

    expect(find.byType(LegacyScoreSheet), findsOneWidget);
    expect(_inBoard(noLineup), findsOneWidget);
    expect(find.text(noLineup), findsOneWidget);
  });

  testWidgets(
    'a forfeit reads 8 : 0 · Kontumace, without pins, a refresh or a lineup',
    (tester) async {
      final forfeit = MatchResult.fromJson(const {
        'match_id': 'm1',
        'status': 'forfeit',
        'match_type': 'TEAMS_OF_6',
        'discipline': 'T120',
        'home_points': 8,
        'away_points': 0,
        'fetched_at': '2026-09-23T10:00:00+00:00',
      });
      // Today, half an hour after kickoff: a scheduled match would be live
      // here, so only the forfeit status keeps the refresh away.
      await tester.pumpWidget(
        app(
          slots: [
            match(
              id: 'm1',
              date: today,
              videoUrl: 'https://vysledky.kuzelky.cz/video/m1',
            ),
          ],
          results: {'m1': forfeit},
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(_inBoard('8'), findsOneWidget);
      expect(_inBoard('0'), findsOneWidget);
      expect(_inBoard('Kontumace'), findsOneWidget);
      expect(_inBoard('6 hráčů · 120 HS'), findsOneWidget);
      expect(
        find.text('Zápas skončil kontumací – souboje se nehrály.'),
        findsOneWidget,
      );
      // No pin totals: no lead, no set points, no Družstva card.
      expect(find.textContaining('←'), findsNothing);
      expect(find.textContaining('→'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(MatchScoreboard),
          matching: find.textContaining('SB'),
        ),
        findsNothing,
      );
      expect(find.text('Družstva'), findsNothing);
      expect(find.byIcon(Icons.refresh), findsNothing);
      expect(find.byType(RefreshIndicator), findsNothing);
      expect(find.text('Záznam'), findsOneWidget);
      // The scoreboard tells the forfeit instead of the missing lineup.
      expect(find.text('Sestavy zatím nejsou k dispozici.'), findsNothing);

      await tester.tap(_zapisSegment);
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(LegacyScoreSheet),
          matching: find.text('Zápis'),
        ),
        findsOneWidget,
      );
      expect(find.text(home), findsNWidgets(2));
      expect(find.text(away), findsNWidgets(2));
      expect(find.text('Sestavy zatím nejsou k dispozici.'), findsNothing);
    },
  );

  testWidgets('a tap on a waiting duel does nothing: once it is played it '
      'opens collapsed, not by surprise', (tester) async {
    final players = StreamController<List<MatchPlayerResult>>();
    addTearDown(players.close);
    List<MatchPlayerResult> duel1({required bool played}) => [
      for (final p in rudnaPlayers.where((p) => p.position == 1))
        played
            ? p
            : MatchPlayerResult.fromJson({
                'id': p.id,
                'match_id': p.matchId,
                'side': p.side,
                'position': 1,
                'player_name': p.playerName,
                'lanes': [
                  for (final l in p.lanes)
                    {'lane': l.lane, 'total': null},
                ],
              }),
    ];
    await tester.pumpWidget(
      app(
        slots: [match(id: 'm1', date: today.addDays(-1))],
        results: {'m1': finishedResult},
        playersStream: players.stream,
      ),
    );
    players.add(duel1(played: false));
    await tester.pumpAndSettle();
    expect(find.text('čeká'), findsOneWidget);

    await tester.tap(find.text('čeká'));
    await tester.pumpAndSettle();
    players.add(duel1(played: true));
    await tester.pumpAndSettle();

    expect(find.text('407'), findsOneWidget);
    expect(find.text('156'), findsNothing, reason: 'still collapsed');
  });

  testWidgets('Video and Na webu ČKA buttons show only when the data exists', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        slots: [
          match(
            id: 'm1',
            date: today.addDays(-1),
            videoUrl: 'https://vysledky.kuzelky.cz/video/m1',
            siteSlug: 'zapas-m1',
          ),
        ],
        results: {'m1': finishedResult},
      ),
    );
    await tester.pumpAndSettle();

    // finishedResult's status is 'finished' — never live — so the button
    // reads "Záznam" (a recording), not the plain "Video" label.
    expect(find.text('Záznam'), findsOneWidget);
    expect(find.text('Na webu ČKA'), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
    expect(find.byIcon(Icons.open_in_new), findsOneWidget);
  });

  testWidgets('no video/site data hides the buttons', (tester) async {
    await tester.pumpWidget(
      app(
        slots: [match(id: 'm1', date: today.addDays(-1))],
        results: {'m1': finishedResult},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Záznam'), findsNothing);
    expect(find.text('Video'), findsNothing);
    expect(find.text('Na webu ČKA'), findsNothing);
  });

  testWidgets('the Záznam button launches the video url', (tester) async {
    final launched = <String>[];
    await tester.pumpWidget(
      app(
        slots: [
          match(
            id: 'm1',
            date: today.addDays(-1),
            videoUrl: 'https://vysledky.kuzelky.cz/video/m1',
          ),
        ],
        results: {'m1': finishedResult},
        launch: launched.add,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Záznam'));
    await tester.pumpAndSettle();

    expect(launched, ['https://vysledky.kuzelky.cz/video/m1']);
  });

  testWidgets(
    'a scheduled match with a video (not yet live) reads the plain Video '
    'label',
    (tester) async {
      await tester.pumpWidget(
        app(
          slots: [
            match(
              id: 'm1',
              date: today.addDays(5),
              videoUrl: 'https://vysledky.kuzelky.cz/video/m1',
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Video'), findsOneWidget);
      expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);

      // No result at all yet — no winner, so both of the scoreboard's team
      // names sit at the neutral w500: neither lightened like a loser nor
      // heavy like a winner.
      expect(
        tester.widget<Text>(_inBoard(home)).style?.fontWeight,
        FontWeight.w500,
      );
      expect(
        tester.widget<Text>(_inBoard(away)).style?.fontWeight,
        FontWeight.w500,
      );
    },
  );

  testWidgets(
    'a live match reads Sledovat živě with a small red dot, not the play '
    'icon',
    (tester) async {
      await tester.pumpWidget(
        app(
          matchId: 'm2',
          slots: [
            match(
              id: 'm2',
              date: today,
              videoUrl: 'https://vysledky.kuzelky.cz/video/m2',
            ),
          ],
          results: {'m2': liveResultWith()},
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Sledovat živě'), findsOneWidget);
      // Scoped to the button: the scoreboard's Živě chip has a dot too.
      expect(
        find.descendant(
          of: find.bySubtype<FilledButton>(),
          matching: find.byIcon(Icons.circle),
        ),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.play_circle_fill), findsNothing);
    },
  );

  testWidgets('freshness line reads relative to nowProvider', (tester) async {
    final fetched = now.subtract(const Duration(minutes: 20));
    final result = MatchResult.fromJson({
      'match_id': 'm1',
      'status': 'finished',
      'fetched_at': fetched.toIso8601String(),
    });
    await tester.pumpWidget(
      app(
        slots: [match(id: 'm1', date: today.addDays(-1))],
        results: {'m1': result},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Výsledky z webu: před 20 min'), findsOneWidget);
  });

  testWidgets(
    'a live match keeps its freshness in the Živě chip, not in a line '
    'under the scoreboard',
    (tester) async {
      await tester.pumpWidget(
        app(
          matchId: 'm2',
          slots: [match(id: 'm2', date: today)],
          results: {'m2': liveResultWith()},
        ),
      );
      await tester.pumpAndSettle();

      expect(_inBoard('Živě · před 20 min'), findsOneWidget);
      expect(find.textContaining('Výsledky z webu'), findsNothing);
      expect(find.text('Výsledky zatím nejsou.'), findsNothing);
    },
  );

  testWidgets('no result yet shows the no-results line', (tester) async {
    await tester.pumpWidget(
      app(
        slots: [match(id: 'm1', date: today.addDays(5))],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Výsledky zatím nejsou.'), findsOneWidget);
  });

  testWidgets('while slots are loading shows a progress indicator', (
    tester,
  ) async {
    await tester.pumpWidget(app(slotsLoading: true));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('a match no longer in the schedule shows the gone message', (
    tester,
  ) async {
    await tester.pumpWidget(app(slots: const []));
    await tester.pumpAndSettle();

    expect(find.text('Zápas už v rozpisu není.'), findsOneWidget);
  });

  testWidgets('a live match is refreshed once on open and shows the icon', (
    tester,
  ) async {
    final refreshed = <String>[];
    await tester.pumpWidget(
      app(
        matchId: 'm2',
        slots: [match(id: 'm2', date: today)],
        results: {'m2': liveResultWith()},
        refresh: (id) async {
          refreshed.add(id);
          return 'queued';
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(refreshed, ['m2']);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    final button = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.refresh),
    );
    expect(button.tooltip, 'Obnovit');
  });

  testWidgets(
    'the once-only live refresh waits for slots to finish loading, not '
    'just for results to arrive',
    (tester) async {
      // Regression for the same class of bug results_screen_test.dart
      // guards against: matchResultsProvider can already carry a live
      // result before prioritySlotsProvider's own stream delivers its
      // first snapshot (which reads `[]` while loading) — gating the
      // one-time open refresh on results alone would let it latch on a
      // null slot and never see the live match once slots actually load.
      final refreshed = <String>[];
      final slotsCtrl = StreamController<List<PrioritySlot>>();
      addTearDown(slotsCtrl.close);
      await tester.pumpWidget(
        app(
          matchId: 'm2',
          slotsStream: slotsCtrl.stream,
          results: {'m2': liveResultWith()},
          refresh: (id) async {
            refreshed.add(id);
            return 'queued';
          },
        ),
      );
      await tester.pump();
      expect(refreshed, isEmpty);

      slotsCtrl.add([match(id: 'm2', date: today)]);
      await tester.pumpAndSettle();

      expect(refreshed, ['m2']);

      // A later emission of the same data must not refresh again.
      slotsCtrl.add([match(id: 'm2', date: today)]);
      await tester.pumpAndSettle();

      expect(refreshed, ['m2']);
    },
  );

  testWidgets('a finished match never shows the refresh icon, nor pulls to '
      'refresh', (tester) async {
    await tester.pumpWidget(
      app(
        slots: [match(id: 'm1', date: today.addDays(-1))],
        results: {'m1': finishedResult},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.refresh), findsNothing);
    expect(find.byType(RefreshIndicator), findsNothing);
  });

  testWidgets(
    'a live match wraps the list in a pull-to-refresh that refreshes once '
    'more',
    (tester) async {
      final refreshed = <String>[];
      await tester.pumpWidget(
        app(
          matchId: 'm2',
          slots: [match(id: 'm2', date: today)],
          results: {'m2': liveResultWith()},
          refresh: (id) async {
            refreshed.add(id);
            return 'queued';
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(refreshed, ['m2']); // the refresh on open

      expect(
        find.ancestor(
          of: find.byType(ListView),
          matching: find.byType(RefreshIndicator),
        ),
        findsOneWidget,
      );
      // The list is shorter than the screen, yet still pulls.
      expect(
        tester.widget<ListView>(find.byType(ListView)).physics,
        isA<AlwaysScrollableScrollPhysics>(),
      );

      await tester.fling(find.byType(ListView), const Offset(0, 300), 1000);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1)); // the scroll settles
      await tester.pump(const Duration(seconds: 1)); // the refresh runs
      await tester.pump(const Duration(seconds: 1)); // the indicator hides

      expect(refreshed, ['m2', 'm2']);
    },
  );

  testWidgets(
    'a match that ends while watched keeps its scroll offset as the '
    'pull-to-refresh goes away',
    (tester) async {
      final resultsCtrl = StreamController<Map<String, MatchResult>>();
      addTearDown(resultsCtrl.close);
      await tester.pumpWidget(
        app(
          matchId: 'm2',
          slots: [match(id: 'm2', date: today)],
          resultsStream: resultsCtrl.stream,
          players: rudnaPlayers,
        ),
      );
      resultsCtrl.add({'m2': liveResultWith()});
      await tester.pumpAndSettle();
      expect(find.byType(RefreshIndicator), findsOneWidget);

      double offset() => tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(ListView),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position
          .pixels;
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pumpAndSettle();
      final scrolled = offset();
      expect(scrolled, greaterThan(300));

      resultsCtrl.add({
        'm2': liveResultWith(
          status: 'finished',
          fetchedAt: '2026-09-23T17:55:00+00:00',
        ),
      });
      await tester.pumpAndSettle();

      expect(find.byType(RefreshIndicator), findsNothing);
      expect(offset(), scrolled);
    },
  );

  testWidgets(
    'tapping refresh calls it again and shows a progress indicator until '
    'a newer result arrives',
    (tester) async {
      final refreshed = <String>[];
      await tester.pumpWidget(
        app(
          matchId: 'm2',
          slots: [match(id: 'm2', date: today)],
          results: {'m2': liveResultWith()},
          refresh: (id) {
            refreshed.add(id);
            if (refreshed.length == 1) return Future.value('queued');
            return Completer<String>().future; // manual tap: never resolves
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(refreshed, ['m2']);

      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pump();

      expect(refreshed, ['m2', 'm2']);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.refresh), findsNothing);
    },
  );

  testWidgets(
    'the progress indicator clears as soon as a newer result arrives',
    (tester) async {
      final resultsCtrl = StreamController<Map<String, MatchResult>>();
      addTearDown(resultsCtrl.close);
      var callCount = 0;
      await tester.pumpWidget(
        app(
          matchId: 'm2',
          slots: [match(id: 'm2', date: today)],
          resultsStream: resultsCtrl.stream,
          refresh: (id) {
            callCount++;
            if (callCount == 1) return Future.value('queued');
            return Completer<String>().future;
          },
        ),
      );
      resultsCtrl.add({'m2': liveResultWith()});
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      resultsCtrl.add({
        'm2': liveResultWith(fetchedAt: '2026-09-23T17:41:00+00:00'),
      });
      await tester.pump();
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byIcon(Icons.refresh), findsOneWidget);
    },
  );

  testWidgets(
    'the progress indicator clears itself once 20s pass without a newer '
    'result',
    (tester) async {
      var callCount = 0;
      await tester.pumpWidget(
        app(
          matchId: 'm2',
          slots: [match(id: 'm2', date: today)],
          results: {'m2': liveResultWith()},
          refresh: (id) {
            callCount++;
            if (callCount == 1) return Future.value('queued');
            return Completer<String>().future;
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.pump(const Duration(seconds: 20));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byIcon(Icons.refresh), findsOneWidget);
    },
  );

  testWidgets('a fresh result on tap shows a snackbar', (tester) async {
    var callCount = 0;
    await tester.pumpWidget(
      app(
        matchId: 'm2',
        slots: [match(id: 'm2', date: today)],
        results: {'m2': liveResultWith()},
        refresh: (id) async {
          callCount++;
          return callCount == 1 ? 'queued' : 'fresh';
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();

    expect(find.text('Výsledky jsou čerstvé.'), findsOneWidget);
  });

  testWidgets('a not_live result on tap hides the refresh button', (
    tester,
  ) async {
    var callCount = 0;
    await tester.pumpWidget(
      app(
        matchId: 'm2',
        slots: [match(id: 'm2', date: today)],
        results: {'m2': liveResultWith()},
        refresh: (id) async {
          callCount++;
          return callCount == 1 ? 'queued' : 'not_live';
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.refresh), findsOneWidget);

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.refresh), findsNothing);
  });

  testWidgets('a refresh error on tap shows a friendly snackbar', (
    tester,
  ) async {
    var callCount = 0;
    await tester.pumpWidget(
      app(
        matchId: 'm2',
        slots: [match(id: 'm2', date: today)],
        results: {'m2': liveResultWith()},
        refresh: (id) async {
          callCount++;
          if (callCount == 1) return 'queued';
          throw Exception('federation_not_configured');
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();

    expect(
      find.text('Nejdřív ulož kuželnu z výsledkového servisu.'),
      findsOneWidget,
    );
  });

  testWidgets('AppBar title is competition and round', (tester) async {
    await tester.pumpWidget(
      app(
        slots: [
          match(
            id: 'm1',
            date: today.addDays(-1),
            competition: 'Jihomoravská divize',
            round: 5,
          ),
        ],
        results: {'m1': finishedResult},
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.widgetWithText(AppBar, 'Jihomoravská divize · 5. kolo'),
      findsOneWidget,
    );
  });

  testWidgets(
    'venue line is tappable and opens the venue detail when a matching '
    'venue exists',
    (tester) async {
      await tester.pumpWidget(
        app(
          slots: [
            match(
              id: 'm1',
              date: today.addDays(-1),
              venue: 'TJ Sokol Brno IV',
              venueSlug: 'tj-sokol-brno-iv',
            ),
          ],
          results: {'m1': finishedResult},
          venues: [
            Venue.fromJson(const {
              'id': 'v1',
              'slug': 'tj-sokol-brno-iv',
              'name': 'TJ Sokol Brno IV',
              'fetched_at': '2026-09-23T01:00:00+00:00',
            }),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // The scoreboard's last line: the format, then the venue as a link.
      expect(_inBoard('6 hráčů · 120 HS · '), findsOneWidget);
      expect(_inBoard('TJ Sokol Brno IV'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);

      await tester.tap(_inBoard('TJ Sokol Brno IV'));
      await tester.pumpAndSettle();

      expect(find.byType(VenueDetailScreen), findsOneWidget);
      expect(find.widgetWithText(AppBar, 'TJ Sokol Brno IV'), findsOneWidget);
    },
  );

  testWidgets(
    'venue line shows plain text, not tappable, when no matching venue '
    'exists',
    (tester) async {
      await tester.pumpWidget(
        app(
          slots: [
            match(
              id: 'm1',
              date: today.addDays(-1),
              venue: 'TJ Sokol Brno IV',
              venueSlug: 'tj-sokol-brno-iv',
            ),
          ],
          results: {'m1': finishedResult},
        ),
      );
      await tester.pumpAndSettle();

      expect(_inBoard('6 hráčů · 120 HS · TJ Sokol Brno IV'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsNothing);
    },
  );

  testWidgets(
    'popping the route while a manual refresh is still pending throws '
    'nothing, and the 20s wait timer does not fire into a disposed state',
    (tester) async {
      final completer = Completer<String>();
      var callCount = 0;
      await tester.pumpWidget(
        app(
          matchId: 'm2',
          slots: [match(id: 'm2', date: today)],
          results: {'m2': liveResultWith()},
          pushable: true,
          refresh: (id) {
            callCount++;
            if (callCount == 1) return Future.value('queued'); // open-time
            return completer.future; // manual tap: stays pending
          },
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // Pop the detail screen back off while the refresh is outstanding.
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      // The refresh finally resolves, and the 20s wait timer's own
      // duration elapses — both after the State is long gone.
      completer.complete('queued');
      await tester.pump();
      await tester.pump(const Duration(seconds: 20));
      await tester.pump();

      expect(tester.takeException(), isNull);
    },
  );

  group('Souboje on the real Rudná A 7 : 1 Vršovice A', () {
    Widget rudna({
      MatchDetailView? view = MatchDetailView.souboje,
      Map<String, int> teamColors = const {},
    }) => app(
      matchId: 'rv',
      slots: [rudnaSlot],
      results: {'rv': rudnaResult},
      players: rudnaPlayers,
      view: view,
      teamColors: teamColors,
    );

    testWidgets(
      'Souboje is the default: six duel cards in position order on one '
      'shared scale, then the Družstva card, and no score sheet',
      (tester) async {
        _tall(tester);
        // The real notifier, with nothing saved on the device yet.
        SharedPreferences.setMockInitialValues({});
        await tester.pumpWidget(rudna(view: null));
        await tester.pumpAndSettle();

        final cards = tester
            .widgetList<DuelCard>(find.byType(DuelCard))
            .toList();
        expect([for (final c in cards) c.duel.position], [1, 2, 3, 4, 5, 6]);
        // Duel 5 (450 : 351) sets the scale every bar shares.
        expect(diffScale(duelsOf(rudnaPlayers)), 99);
        expect([for (final c in cards) c.scale], List.filled(6, 99));
        expect(cards.every((c) => !c.expanded), isTrue);
        expect(find.byType(TeamTotalsCard), findsOneWidget);
        expect(find.byType(LegacyScoreSheet), findsNothing);
        expect(
          tester
              .widget<SegmentedButton<MatchDetailView>>(
                find.byType(SegmentedButton<MatchDetailView>),
              )
              .selected,
          {MatchDetailView.souboje},
        );
        expect(find.text('Rozbalit vše'), findsOneWidget);
      },
    );

    testWidgets(
      'tapping Zápis shows the score sheet instead of the cards, keeps the '
      'scoreboard, and remembers the choice',
      (tester) async {
        _tall(tester);
        await tester.pumpWidget(rudna());
        await tester.pumpAndSettle();

        await tester.tap(_zapisSegment);
        await tester.pumpAndSettle();

        expect(find.byType(LegacyScoreSheet), findsOneWidget);
        expect(find.byType(DuelCard), findsNothing);
        expect(find.byType(TeamTotalsCard), findsNothing);
        expect(find.text('Rozbalit vše'), findsNothing);
        expect(find.byType(MatchScoreboard), findsOneWidget);
        final container = ProviderScope.containerOf(
          tester.element(find.byType(MatchDetailScreen)),
        );
        expect(container.read(matchDetailViewProvider), MatchDetailView.zapis);
      },
    );

    testWidgets('a saved Zápis opens on the score sheet', (tester) async {
      _tall(tester);
      await tester.pumpWidget(rudna(view: MatchDetailView.zapis));
      await tester.pumpAndSettle();

      expect(find.byType(LegacyScoreSheet), findsOneWidget);
      expect(find.byType(DuelCard), findsNothing);
    });

    testWidgets(
      'a tap opens and closes one duel; Rozbalit vše opens all six, Sbalit '
      'vše closes them',
      (tester) async {
        _tall(tester);
        await tester.pumpWidget(rudna());
        await tester.pumpAndSettle();

        // Lane 1 of duel 1: Mičanová's 156 plné, shown only in the table.
        expect(find.text('156'), findsNothing);

        await tester.tap(find.byType(DuelCard).first);
        await tester.pumpAndSettle();
        expect(find.text('156'), findsOneWidget);
        expect(
          tester.widget<DuelCard>(find.byType(DuelCard).first).expanded,
          isTrue,
        );
        // One duel open is not all of them.
        expect(find.text('Rozbalit vše'), findsOneWidget);

        await tester.tap(find.byType(DuelCard).first);
        await tester.pumpAndSettle();
        expect(find.text('156'), findsNothing);

        await tester.tap(find.text('Rozbalit vše'));
        await tester.pumpAndSettle();
        // Six tables, each with two Celkem column heads and a Celkem row.
        expect(find.text('Celkem'), findsNWidgets(6 * 3));
        for (final card in tester.widgetList<DuelCard>(find.byType(DuelCard))) {
          expect(card.expanded, isTrue, reason: 'duel ${card.duel.position}');
        }
        expect(find.text('Rozbalit vše'), findsNothing);

        await tester.tap(find.text('Sbalit vše'));
        await tester.pumpAndSettle();
        expect(find.text('Celkem'), findsNothing);
        expect(find.text('Rozbalit vše'), findsOneWidget);
      },
    );

    testWidgets(
      'each side takes its colour from my team colours, else primary for '
      'home and tertiary for away',
      (tester) async {
        _tall(tester);
        await tester.pumpWidget(
          rudna(teamColors: const {'TJ Sokol Rudná A': 5}),
        );
        await tester.pumpAndSettle();

        final card = tester.widget<DuelCard>(find.byType(DuelCard).first);
        final scheme = Theme.of(
          tester.element(find.byType(DuelCard).first),
        ).colorScheme;
        expect(card.homeColor, googleEventColorOf(5));
        expect(card.awayColor, scheme.tertiary);
      },
    );

    testWidgets('without team colours: primary and tertiary', (tester) async {
      _tall(tester);
      await tester.pumpWidget(rudna());
      await tester.pumpAndSettle();

      final card = tester.widget<DuelCard>(find.byType(DuelCard).first);
      final scheme = Theme.of(
        tester.element(find.byType(DuelCard).first),
      ).colorScheme;
      expect(card.homeColor, scheme.primary);
      expect(card.awayColor, scheme.tertiary);
    });

    testWidgets('on a wide window the column is centred, at most 720dp', (
      tester,
    ) async {
      _tall(tester, width: 1400);
      await tester.pumpWidget(rudna());
      await tester.pumpAndSettle();

      final board = tester.getRect(find.byType(MatchScoreboard));
      expect(board.width, 720);
      expect(board.center.dx, 700);
      final card = tester.getRect(find.byType(DuelCard).first);
      expect(card.left, board.left + 12);
      expect(card.right, board.right - 12);
    });

    testWidgets(
      'on a wide window the Zápis sheet keeps the full width while the '
      'scoreboard stays at 720dp',
      (tester) async {
        _tall(tester, width: 1400);
        await tester.pumpWidget(rudna(view: MatchDetailView.zapis));
        await tester.pumpAndSettle();

        // The sheet is about 1000dp at its natural width: capped at 720 it
        // would hide a third of itself behind a sideways scroll.
        final sheet = tester.getRect(find.byType(LegacyScoreSheet));
        expect(sheet.left, 0);
        expect(sheet.width, 1400);
        expect(tester.getRect(find.byType(MatchScoreboard)).width, 720);
      },
    );

    testWidgets('at 360dp every duel opens without an overflow', (
      tester,
    ) async {
      _tall(tester, width: 360);
      await tester.pumpWidget(rudna());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Rozbalit vše'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Sbalit vše'), findsOneWidget);
    });
  });
}

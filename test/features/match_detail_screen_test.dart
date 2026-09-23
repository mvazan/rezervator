import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/clubhouse/match_detail_screen.dart';
import 'package:rezervator/features/clubhouse/venue_detail_screen.dart';

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
    List<MatchPlayerResult> players = const [],
    List<Venue> venues = const [],
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
        matchResultsProvider.overrideWith((ref) => Stream.value(results)),
        matchPlayerResultsProvider.overrideWith(
          (ref, id) => Stream.value(players),
        ),
        venuesProvider.overrideWith((ref) => Stream.value(venues)),
        nowProvider.overrideWith((ref) => Stream.value(now)),
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

  testWidgets(
    'a finished match renders points, pins, SB, stats, players and lanes '
    'once expanded',
    (tester) async {
      await tester.pumpWidget(
        app(
          slots: [match(id: 'm1', date: today.addDays(-1))],
          results: {'m1': finishedResult},
          players: [homePlayer, awayPlayer],
        ),
      );
      await tester.pumpAndSettle();

      // The score is a single plain Text(pointsLabel(...), style: ...) — no
      // per-side branching in the code to test.
      final scoreText = tester.widget<Text>(find.text('5 : 3'));
      expect(
        scoreText.style,
        Theme.of(tester.element(find.text('5 : 3'))).textTheme.headlineSmall,
      );
      // The header card is the only Card on screen — scope to it, since the
      // legacy score sheet's team summary row shows the same team name text
      // again further down.
      final headerCard = find.byType(Card);
      expect(headerCard, findsOneWidget);
      final homeName = tester.widget<Text>(
        find.descendant(of: headerCard, matching: find.text(home)),
      );
      expect(homeName.style?.fontWeight, FontWeight.w800);
      final awayName = tester.widget<Text>(
        find.descendant(of: headerCard, matching: find.text(away)),
      );
      // Explicitly w400 (not just "not w800") — a plain ambient style
      // would also satisfy `isNot(w800)` without proving the loser was
      // actually lightened (Fix round 1).
      expect(awayName.style?.fontWeight, FontWeight.w400);
      expect(find.text('3460 : 3349'), findsOneWidget);
      expect(find.textContaining('SB 15 : 9'), findsOneWidget);
      // The joined format+status line, exactly (formatLabel + ' · ' + status).
      expect(find.text('6 hráčů · 120 HS · Dokončeno'), findsOneWidget);

      // The legacy score sheet: team names (again, in the summary row),
      // player names with position prefix, and the lane totals.
      expect(find.text(home), findsNWidgets(2));
      expect(find.text(away), findsNWidgets(2));
      expect(find.text('1. Jan Novák'), findsOneWidget);
      expect(find.text('1. Petr Svoboda'), findsOneWidget);
      expect(find.text('Série'), findsNWidgets(2));
      expect(find.text('290'), findsNWidgets(2));
    },
  );

  testWidgets(
    'players section shows a message when there are none yet, but the '
    'team summary (from the result) still shows',
    (tester) async {
      await tester.pumpWidget(
        app(
          slots: [match(id: 'm1', date: today.addDays(-1))],
          results: {'m1': finishedResult},
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Sestavy zatím nejsou k dispozici.'), findsOneWidget);
      // The result has team-level data even with no lineup yet — Fix
      // round 1: this used to disappear along with the per-player section.
      expect(find.text('Zápis'), findsOneWidget);
      expect(find.text('3460'), findsOneWidget);
      expect(find.text('Jméno a příjmení hráče'), findsNothing);
    },
  );

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

      // No result at all yet — no winner, so the header card's team names
      // stay fully unstyled (null), not forced to w400 either (Fix
      // round 1).
      final headerCard = find.byType(Card);
      final homeName = tester.widget<Text>(
        find.descendant(of: headerCard, matching: find.text(home)),
      );
      expect(homeName.style, isNull);
      final awayName = tester.widget<Text>(
        find.descendant(of: headerCard, matching: find.text(away)),
      );
      expect(awayName.style, isNull);
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
      expect(find.byIcon(Icons.circle), findsOneWidget);
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

  testWidgets('a finished match never shows the refresh icon', (tester) async {
    await tester.pumpWidget(
      app(
        slots: [match(id: 'm1', date: today.addDays(-1))],
        results: {'m1': finishedResult},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.refresh), findsNothing);
  });

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

      expect(find.text('Kuželna: TJ Sokol Brno IV'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);

      await tester.tap(find.text('Kuželna: TJ Sokol Brno IV'));
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

      expect(find.text('Kuželna: TJ Sokol Brno IV'), findsOneWidget);
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
}

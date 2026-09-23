import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/clubhouse/match_detail_screen.dart';
import 'package:rezervator/features/schedule/widgets/calendar_board.dart';
import 'package:rezervator/features/schedule/widgets/day_header.dart';
import 'package:rezervator/features/schedule/widgets/day_matches_dialog.dart';

/// The header strip ellipsises long match names to "…"; tapping it opens the
/// day's events in full. The dialog shows the bare title (a different string
/// than the strip's "🏠 title · time" label), so finding the bare title proves
/// the dialog, not the strip.
void main() {
  final date = Day(2026, 9, 18);
  final now = DateTime(2026, 9, 18, 12, 0);

  // The dialog content is a Consumer (it reads matchResultsProvider/
  // nowProvider), so every pump needs a ProviderScope — real Supabase-backed
  // providers (matchResultsProvider, prioritySlotsProvider's own stream,
  // MatchDetailScreen's own reads) are overridden with plain test doubles.
  Widget wrap(
    Widget home, {
    Map<String, MatchResult> results = const {},
    List<PrioritySlot> slots = const [],
  }) {
    return ProviderScope(
      overrides: [
        matchResultsProvider.overrideWith((ref) => Stream.value(results)),
        nowProvider.overrideWith((ref) => Stream.value(now)),
        prioritySlotsProvider.overrideWithValue(slots),
        prioritySlotsLoadingProvider.overrideWithValue(false),
        matchPlayerResultsProvider.overrideWith(
          (ref, id) => Stream.value(const []),
        ),
        venuesProvider.overrideWith((ref) => Stream.value(const [])),
      ],
      child: MaterialApp(home: home),
    );
  }

  PrioritySlot match(
    String home,
    String away, {
    bool away_ = false,
    String? id,
    String? importKey,
    String? videoUrl,
  }) => PrioritySlot(
    id: id ?? '$home-$away',
    date: date,
    startsAt: const HourMinute(16, 30),
    endsAt: const HourMinute(18, 30),
    type: PrioritySlot.fallbackMatchType,
    homeTeam: home,
    awayTeam: away,
    isAway: away_,
    importKey: importKey,
    videoUrl: videoUrl,
  );

  final matches = [
    match('SKK Veverky Brno C', 'SK Brno Žabovřesky B'),
    match('KK MS Brno C', 'TJ Sokol Brno IV D'),
  ];

  group('showDayMatchesDialog', () {
    testWidgets('lists every event in full with its time and side',
        (tester) async {
      await tester.pumpWidget(wrap(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDayMatchesDialog(context, date, matches),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      // Full names, untruncated — both, even the long second one.
      expect(find.text('SKK Veverky Brno C – SK Brno Žabovřesky B'),
          findsOneWidget);
      expect(find.text('KK MS Brno C – TJ Sokol Brno IV D'), findsOneWidget);
      expect(find.text('16:30–18:30 · doma'), findsNWidgets(2));

      await tester.tap(find.text('Zavřít'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('an away match reads "venku"', (tester) async {
      await tester.pumpWidget(wrap(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDayMatchesDialog(
                  context, date, [match('A', 'B', away_: true)]),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('16:30–18:30 · venku'), findsOneWidget);
    });

    testWidgets('no events opens nothing', (tester) async {
      await tester.pumpWidget(wrap(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDayMatchesDialog(context, date, const []),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('a finished federation match shows its points and pins',
        (tester) async {
      final finished = match(
        'TJ Sokol Husovice',
        'TJ Slovan Karlovy Vary',
        id: 'm1',
        importKey: 'cka:m1',
      );
      final result = MatchResult.fromJson(const {
        'match_id': 'm1',
        'status': 'finished',
        'home_points': 5,
        'away_points': 3,
        'home_total': 3460,
        'away_total': 3349,
        'fetched_at': '2026-09-17T21:00:00+00:00',
      });
      await tester.pumpWidget(wrap(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showDayMatchesDialog(context, date, [finished]),
              child: const Text('open'),
            ),
          ),
        ),
        results: {'m1': result},
        slots: [finished],
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('5 : 3'), findsOneWidget);
      expect(find.text('3460 : 3349'), findsOneWidget);
    });

    testWidgets('a live federation match shows the probíhá marker',
        (tester) async {
      final live = match(
        'TJ Sokol Husovice',
        'TJ Slovan Karlovy Vary',
        id: 'm2',
        importKey: 'cka:m2',
      );
      final result = MatchResult.fromJson(const {
        'match_id': 'm2',
        'status': 'in_progress',
        'fetched_at': '2026-09-18T11:40:00+00:00',
      });
      await tester.pumpWidget(wrap(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDayMatchesDialog(context, date, [live]),
              child: const Text('open'),
            ),
          ),
        ),
        results: {'m2': result},
        slots: [live],
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.textContaining('probíhá'), findsOneWidget);
    });

    testWidgets(
        'a scheduled result inside the "live" time window shows only the '
        'title — no score, no probíhá', (tester) async {
      final upcoming = match(
        'TJ Sokol Husovice',
        'TJ Slovan Karlovy Vary',
        id: 'm7',
        importKey: 'cka:m7',
      );
      // A row the sync created ahead of kickoff — status scheduled, all
      // points null — inside isLive's own refresh window (1h before start).
      final result = MatchResult.fromJson(const {
        'match_id': 'm7',
        'status': 'scheduled',
        'fetched_at': '2026-09-18T11:00:00+00:00',
      });
      await tester.pumpWidget(wrap(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDayMatchesDialog(context, date, [upcoming]),
              child: const Text('open'),
            ),
          ),
        ),
        results: {'m7': result},
        slots: [upcoming],
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('TJ Sokol Husovice – TJ Slovan Karlovy Vary'),
          findsOneWidget);
      expect(find.textContaining('probíhá'), findsNothing);
      expect(find.text('–'), findsNothing);
    });

    testWidgets(
        'a preparation result also shows only the title', (tester) async {
      final upcoming = match(
        'TJ Sokol Husovice',
        'TJ Slovan Karlovy Vary',
        id: 'm8',
        importKey: 'cka:m8',
      );
      final result = MatchResult.fromJson(const {
        'match_id': 'm8',
        'status': 'preparation',
        'fetched_at': '2026-09-18T11:00:00+00:00',
      });
      await tester.pumpWidget(wrap(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDayMatchesDialog(context, date, [upcoming]),
              child: const Text('open'),
            ),
          ),
        ),
        results: {'m8': result},
        slots: [upcoming],
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('TJ Sokol Husovice – TJ Slovan Karlovy Vary'),
          findsOneWidget);
      expect(find.textContaining('probíhá'), findsNothing);
    });

    testWidgets(
        'an in_progress result with null points shows the score row and '
        'probíhá', (tester) async {
      final live = match(
        'TJ Sokol Husovice',
        'TJ Slovan Karlovy Vary',
        id: 'm9',
        importKey: 'cka:m9',
      );
      final result = MatchResult.fromJson(const {
        'match_id': 'm9',
        'status': 'in_progress',
        'fetched_at': '2026-09-18T11:40:00+00:00',
      });
      await tester.pumpWidget(wrap(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDayMatchesDialog(context, date, [live]),
              child: const Text('open'),
            ),
          ),
        ),
        results: {'m9': result},
        slots: [live],
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('–'), findsOneWidget);
      expect(find.textContaining('probíhá'), findsOneWidget);
    });

    testWidgets(
        'a finished result shows the score, no probíhá', (tester) async {
      final finished = match(
        'TJ Sokol Husovice',
        'TJ Slovan Karlovy Vary',
        id: 'm10',
        importKey: 'cka:m10',
      );
      final result = MatchResult.fromJson(const {
        'match_id': 'm10',
        'status': 'finished',
        'home_points': 5,
        'away_points': 3,
        'fetched_at': '2026-09-18T11:40:00+00:00',
      });
      await tester.pumpWidget(wrap(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDayMatchesDialog(context, date, [finished]),
              child: const Text('open'),
            ),
          ),
        ),
        results: {'m10': result},
        slots: [finished],
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('5 : 3'), findsOneWidget);
      expect(find.textContaining('probíhá'), findsNothing);
    });

    testWidgets('the winning side\'s number is bold in the day dialog',
        (tester) async {
      final finished = match(
        'TJ Sokol Husovice',
        'TJ Slovan Karlovy Vary',
        id: 'm11',
        importKey: 'cka:m11',
      );
      final result = MatchResult.fromJson(const {
        'match_id': 'm11',
        'status': 'finished',
        'home_points': 5,
        'away_points': 3,
        'fetched_at': '2026-09-18T11:40:00+00:00',
      });
      await tester.pumpWidget(wrap(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDayMatchesDialog(context, date, [finished]),
              child: const Text('open'),
            ),
          ),
        ),
        results: {'m11': result},
        slots: [finished],
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final scoreText = tester.widget<Text>(find.text('5 : 3'));
      final spans = (scoreText.textSpan! as TextSpan).children!.cast<TextSpan>();
      expect(spans[0].style?.fontWeight, FontWeight.w800);
      expect(spans[2].style?.fontWeight, isNot(FontWeight.w800));
    });

    testWidgets('a video button exists with tooltip Video and launches it',
        (tester) async {
      final withVideo = match(
        'TJ Sokol Husovice',
        'TJ Slovan Karlovy Vary',
        id: 'm3',
        importKey: 'cka:m3',
        videoUrl: 'https://vysledky.kuzelky.cz/video/m3',
      );
      final launched = <String>[];
      await tester.pumpWidget(wrap(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDayMatchesDialog(
                context,
                date,
                [withVideo],
                launch: launched.add,
              ),
              child: const Text('open'),
            ),
          ),
        ),
        slots: [withVideo],
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final button = find.widgetWithIcon(IconButton, Icons.play_circle_fill);
      expect(button, findsOneWidget);
      expect(tester.widget<IconButton>(button).tooltip, 'Video');
      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(launched, ['https://vysledky.kuzelky.cz/video/m3']);
      // Tapping the video icon must not ALSO trigger the row's own
      // tap-through to the detail screen.
      expect(find.byType(MatchDetailScreen), findsNothing);
    });

    testWidgets(
        'opened non-interactively: score shows, no video button, no '
        'tap-through', (tester) async {
      final federationWithVideo = match(
        'TJ Sokol Husovice',
        'TJ Slovan Karlovy Vary',
        id: 'm6',
        importKey: 'cka:m6',
        videoUrl: 'https://vysledky.kuzelky.cz/video/m6',
      );
      final result = MatchResult.fromJson(const {
        'match_id': 'm6',
        'status': 'finished',
        'home_points': 5,
        'away_points': 3,
        'fetched_at': '2026-09-17T21:00:00+00:00',
      });
      await tester.pumpWidget(wrap(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDayMatchesDialog(
                context,
                date,
                [federationWithVideo],
                interactive: false,
              ),
              child: const Text('open'),
            ),
          ),
        ),
        results: {'m6': result},
        slots: [federationWithVideo],
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Score/pins still render — only the tap-through and video control
      // are gated by [interactive]; the leading glyph falls back to the
      // plain trophy/block icon instead.
      expect(find.text('5 : 3'), findsOneWidget);
      expect(find.byIcon(Icons.play_circle_fill), findsNothing);
      expect(find.byIcon(Icons.videocam), findsNothing);
      expect(find.byIcon(Icons.emoji_events_outlined), findsOneWidget);

      await tester.tap(
          find.text('TJ Sokol Husovice – TJ Slovan Karlovy Vary'));
      await tester.pumpAndSettle();

      expect(find.byType(MatchDetailScreen), findsNothing);
      expect(find.byType(AlertDialog), findsOneWidget);
    });

    testWidgets(
        'tapping a federation match closes the dialog and opens the detail',
        (tester) async {
      final federation = match(
        'TJ Sokol Husovice',
        'TJ Slovan Karlovy Vary',
        id: 'm4',
        importKey: 'cka:m4',
      );
      await tester.pumpWidget(wrap(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showDayMatchesDialog(context, date, [federation]),
              child: const Text('open'),
            ),
          ),
        ),
        slots: [federation],
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(
          find.text('TJ Sokol Husovice – TJ Slovan Karlovy Vary'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(MatchDetailScreen), findsOneWidget);
    });

    testWidgets('a manual (non-federation) match is not tappable',
        (tester) async {
      final manual = match('A', 'B', id: 'm5');
      await tester.pumpWidget(wrap(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDayMatchesDialog(context, date, [manual]),
              child: const Text('open'),
            ),
          ),
        ),
        slots: [manual],
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('A – B'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byType(MatchDetailScreen), findsNothing);
    });
  });

  testWidgets('tapping the week header strip opens the dialog', (tester) async {
    await tester.pumpWidget(wrap(
      BoardColumnHeader(
        date: date,
        isToday: false,
        priority: matches,
        height: 120,
      ),
    ));
    // Before the tap the bare title is nowhere — the strip shows the label.
    expect(find.text('SKK Veverky Brno C – SK Brno Žabovřesky B'), findsNothing);

    await tester.tap(find.textContaining('SKK Veverky Brno C').first);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('SKK Veverky Brno C – SK Brno Žabovřesky B'),
        findsOneWidget);
  });

  testWidgets('tapping the pager header strip opens the dialog too',
      (tester) async {
    await tester.pumpWidget(wrap(
      DayHeader(date: date, priority: matches, chipLabel: '7 volných'),
    ));
    await tester.tap(find.textContaining('KK MS Brno C').first);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('KK MS Brno C – TJ Sokol Brno IV D'), findsOneWidget);
  });
}

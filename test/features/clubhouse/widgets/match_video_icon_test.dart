import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/clubhouse/widgets/match_video_icon.dart';

/// [MatchLeading] is pure Dart/Flutter state — no Riverpod, no Supabase — so
/// every test here pumps it directly, no ProviderScope needed.
void main() {
  final date = Day(2026, 9, 23);
  final now = DateTime(2026, 9, 23, 18, 0);

  PrioritySlot slot({String? videoUrl, Day? matchDate}) => PrioritySlot(
        id: 'm1',
        date: matchDate ?? date,
        startsAt: const HourMinute(17, 30),
        endsAt: const HourMinute(20, 30),
        type: PrioritySlot.fallbackMatchType,
        homeTeam: 'Domácí',
        awayTeam: 'Hosté',
        videoUrl: videoUrl,
      );

  MatchResult result(MatchStatus status) => MatchResult(
        matchId: 'm1',
        status: status,
        fetchedAt: now,
      );

  const fallback = Icon(Icons.emoji_events_outlined, key: Key('fallback'));

  /// [onRowOpen] simulates the row's own tap-through — MatchLeading must
  /// never trigger it, only its own [launch].
  Widget wrap({
    required PrioritySlot slot,
    MatchResult? matchResult,
    bool linksEnabled = true,
    void Function(String url)? launch,
    VoidCallback? onRowOpen,
    bool disableAnimations = false,
  }) {
    final content = InkWell(
      onTap: onRowOpen,
      child: Row(
        children: [
          MatchLeading(
            slot: slot,
            result: matchResult,
            now: now,
            linksEnabled: linksEnabled,
            fallback: fallback,
            launch: launch ?? (_) {},
          ),
          const Text('Domácí – Hosté'),
        ],
      ),
    );
    return MaterialApp(
      home: Scaffold(
        body: disableAnimations
            ? MediaQuery(
                data: const MediaQueryData(disableAnimations: true),
                child: content,
              )
            : content,
      ),
    );
  }

  testWidgets(
    'a live match shows the videocam badge with tooltip Živý přenos, and '
    'tapping it launches the url without opening the row',
    (tester) async {
      final launched = <String>[];
      var rowOpened = false;
      await tester.pumpWidget(wrap(
        slot: slot(videoUrl: 'https://vysledky.kuzelky.cz/video/m1'),
        matchResult: result(MatchStatus.inProgress),
        launch: launched.add,
        onRowOpen: () => rowOpened = true,
        disableAnimations: true, // avoid the repeating pulse in this test
      ));
      await tester.pump();

      expect(find.byIcon(Icons.videocam), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w.key == const Key('fallback')),
          findsNothing);
      final button = find.widgetWithIcon(IconButton, Icons.videocam);
      expect(tester.widget<IconButton>(button).tooltip, 'Živý přenos');

      await tester.tap(button);
      await tester.pump();

      expect(launched, ['https://vysledky.kuzelky.cz/video/m1']);
      expect(rowOpened, isFalse);

      // Tapping elsewhere on the row still opens it.
      await tester.tap(find.text('Domácí – Hosté'));
      await tester.pump();
      expect(rowOpened, isTrue);
    },
  );

  testWidgets('a finished match shows play_circle_fill with tooltip Záznam',
      (tester) async {
    await tester.pumpWidget(wrap(
      slot: slot(videoUrl: 'https://vysledky.kuzelky.cz/video/m1'),
      matchResult: result(MatchStatus.finished),
    ));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.play_circle_fill), findsOneWidget);
    expect(find.byIcon(Icons.videocam), findsNothing);
    final button = find.widgetWithIcon(IconButton, Icons.play_circle_fill);
    expect(tester.widget<IconButton>(button).tooltip, 'Záznam');
  });

  testWidgets(
      'a forfeited match also reads Záznam (finished/forfeit both count as '
      'recorded)', (tester) async {
    await tester.pumpWidget(wrap(
      slot: slot(videoUrl: 'https://vysledky.kuzelky.cz/video/m1'),
      matchResult: result(MatchStatus.forfeit),
    ));
    await tester.pumpAndSettle();

    final button = find.widgetWithIcon(IconButton, Icons.play_circle_fill);
    expect(tester.widget<IconButton>(button).tooltip, 'Záznam');
  });

  testWidgets(
      'a scheduled match with a video (not yet live) reads plain Video',
      (tester) async {
    await tester.pumpWidget(wrap(
      // Five days out — well outside isLive's own scheduled window (1h
      // before .. 6h after kickoff) — so this really is "not yet live",
      // not an accidental live match from `now` landing near kickoff.
      slot: slot(
        videoUrl: 'https://vysledky.kuzelky.cz/video/m1',
        matchDate: date.addDays(5),
      ),
      matchResult: null,
    ));
    await tester.pumpAndSettle();

    final button = find.widgetWithIcon(IconButton, Icons.play_circle_fill);
    expect(tester.widget<IconButton>(button).tooltip, 'Video');
  });

  testWidgets('no video url shows the fallback trophy, not a video control',
      (tester) async {
    await tester.pumpWidget(wrap(slot: slot(videoUrl: null)));
    await tester.pumpAndSettle();

    expect(find.byWidgetPredicate((w) => w.key == const Key('fallback')),
        findsOneWidget);
    expect(find.byIcon(Icons.play_circle_fill), findsNothing);
    expect(find.byIcon(Icons.videocam), findsNothing);
  });

  testWidgets(
      'links disabled shows the fallback even with a video url and a live '
      'result', (tester) async {
    await tester.pumpWidget(wrap(
      slot: slot(videoUrl: 'https://vysledky.kuzelky.cz/video/m1'),
      matchResult: result(MatchStatus.inProgress),
      linksEnabled: false,
    ));
    await tester.pumpAndSettle();

    expect(find.byWidgetPredicate((w) => w.key == const Key('fallback')),
        findsOneWidget);
    expect(find.byIcon(Icons.videocam), findsNothing);
  });

  testWidgets(
      'disableAnimations on a live match renders with no running animation',
      (tester) async {
    await tester.pumpWidget(wrap(
      slot: slot(videoUrl: 'https://vysledky.kuzelky.cz/video/m1'),
      matchResult: result(MatchStatus.inProgress),
      disableAnimations: true,
    ));
    // Not pumpAndSettle: a repeating pulse would never settle on its own if
    // this regressed — pump a single frame and assert directly instead.
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byIcon(Icons.videocam), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('a live match WITHOUT disableAnimations does run the pulse',
      (tester) async {
    await tester.pumpWidget(wrap(
      slot: slot(videoUrl: 'https://vysledky.kuzelky.cz/video/m1'),
      matchResult: result(MatchStatus.inProgress),
    ));
    await tester.pump(const Duration(milliseconds: 500));

    expect(tester.hasRunningAnimations, isTrue);
  });
}

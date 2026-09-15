import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/schedule/widgets/calendar_board.dart';
import 'package:rezervator/features/schedule/widgets/day_header.dart';
import 'package:rezervator/features/schedule/widgets/day_matches_dialog.dart';

/// The header strip ellipsises long match names to "…"; tapping it opens the
/// day's events in full. The dialog shows the bare title (a different string
/// than the strip's "🏠 title · time" label), so finding the bare title proves
/// the dialog, not the strip.
void main() {
  final date = Day(2026, 9, 18);

  PrioritySlot match(String home, String away, {bool away_ = false}) =>
      PrioritySlot(
        id: '$home-$away',
        date: date,
        startsAt: const HourMinute(16, 30),
        endsAt: const HourMinute(18, 30),
        type: PrioritySlot.fallbackMatchType,
        homeTeam: home,
        awayTeam: away,
        isAway: away_,
      );

  final matches = [
    match('SKK Veverky Brno C', 'SK Brno Žabovřesky B'),
    match('KK MS Brno C', 'TJ Sokol Brno IV D'),
  ];

  group('showDayMatchesDialog', () {
    testWidgets('lists every event in full with its time and side',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
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
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
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
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
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
  });

  testWidgets('tapping the week header strip opens the dialog', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BoardColumnHeader(
          date: date,
          isToday: false,
          priority: matches,
          height: 120,
        ),
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
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DayHeader(date: date, priority: matches, chipLabel: '7 volných'),
      ),
    ));
    await tester.tap(find.textContaining('KK MS Brno C').first);
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('KK MS Brno C – TJ Sokol Brno IV D'), findsOneWidget);
  });
}

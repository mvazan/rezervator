import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/schedule/widgets/day_watch_button.dart';

/// The „Hlídat uvolněná místa“ bell (0058): who is offered it, and what a
/// tap does.
void main() {
  const settings = ScheduleSettings(
    laneCount: 2,
    trainingWeekdays: {1, 2, 3, 4, 5, 6, 7},
    bookingHorizonDays: 14,
    maxActiveReservations: 3,
  );
  const player = Profile(
    id: 'p',
    displayName: 'Hráč',
    email: 'p@example.com',
    role: Role.player,
    status: ProfileStatus.approved,
  );
  const admin = Profile(
    id: 'a',
    displayName: 'Správce',
    email: 'a@example.com',
    role: Role.admin,
    status: ProfileStatus.approved,
  );
  const kiosk = Profile(
    id: 'k',
    displayName: 'Tablet',
    email: 'k@example.com',
    role: Role.kiosk,
    status: ProfileStatus.approved,
  );
  final today = Day(2026, 10, 7);

  group('canWatchDay', () {
    bool can(Day date, {Profile? me = player, bool interactive = true}) =>
        canWatchDay(
          date: date,
          today: today,
          settings: settings,
          me: me,
          interactive: interactive,
        );

    test('today up to the booking horizon', () {
      expect(can(today), isTrue);
      expect(can(today.addDays(14)), isTrue);
      expect(can(today.addDays(15)), isFalse);
    });

    test('never a day that is over', () {
      expect(can(today.addDays(-1)), isFalse);
    });

    test('an admin books beyond the horizon, so may watch there', () {
      expect(can(today.addDays(40), me: admin), isTrue);
      expect(can(today.addDays(-1), me: admin), isFalse);
    });

    test('not on the kiosk, the public overview or signed out', () {
      expect(can(today, me: kiosk), isFalse);
      expect(can(today, interactive: false), isFalse);
      expect(can(today, me: null), isFalse);
    });
  });

  group('DayWatchButton', () {
    Widget app({
      Set<Day> watched = const {},
      required List<Day> watchLog,
      required List<Day> unwatchLog,
      Future<void> Function(Day)? watch,
    }) => ProviderScope(
      overrides: [
        myDayWatchesProvider.overrideWith((ref) => Stream.value(watched)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: DayWatchButton(
              date: today,
              watch: watch ?? (d) async => watchLog.add(d),
              unwatch: (d) async => unwatchLog.add(d),
            ),
          ),
        ),
      ),
    );

    testWidgets('off: a tap watches the day and promises a notice', (
      tester,
    ) async {
      final watched = <Day>[];
      final unwatched = <Day>[];
      await tester.pumpWidget(app(watchLog: watched, unwatchLog: unwatched));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.notifications_none), findsOneWidget);
      expect(find.byTooltip('Hlídat uvolněná místa'), findsOneWidget);
      await tester.tap(find.byType(IconButton));
      await tester.pump();
      expect(watched, [today]);
      expect(unwatched, isEmpty);
      expect(find.text(dayWatchOnMessage), findsOneWidget);
    });

    testWidgets('on: the bell is lit and a tap stops watching, silently', (
      tester,
    ) async {
      final watched = <Day>[];
      final unwatched = <Day>[];
      await tester.pumpWidget(
        app(watched: {today}, watchLog: watched, unwatchLog: unwatched),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.notifications_active), findsOneWidget);
      await tester.tap(find.byType(IconButton));
      await tester.pump();
      expect(unwatched, [today]);
      expect(watched, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('a refusal reads as Czech copy', (tester) async {
      await tester.pumpWidget(
        app(
          watchLog: [],
          unwatchLog: [],
          watch: (_) async => throw Exception('too_many_watches'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(IconButton));
      await tester.pump();
      expect(find.text('Hlídáš už 30 dní — některé vypni.'), findsOneWidget);
    });
  });
}

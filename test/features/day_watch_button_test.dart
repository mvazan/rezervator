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

  group('watchableBlocks', () {
    const early = TimeBlock(
      id: 'e',
      startsAt: HourMinute(16, 0),
      endsAt: HourMinute(17, 0),
      position: 0,
      active: true,
    );
    const late = TimeBlock(
      id: 'l',
      startsAt: HourMinute(18, 0),
      endsAt: HourMinute(19, 0),
      position: 1,
      active: true,
    );

    test('another day: every block', () {
      expect(
        watchableBlocks(
          [early, late],
          date: today.addDays(1),
          today: today,
          now: const HourMinute(20, 0),
        ),
        [early, late],
      );
    });

    test('today: only the blocks that have not started', () {
      expect(
        watchableBlocks(
          [early, late],
          date: today,
          today: today,
          now: const HourMinute(17, 30),
        ),
        [late],
      );
      expect(
        watchableBlocks(
          [early, late],
          date: today,
          today: today,
          now: const HourMinute(18, 0),
        ),
        isEmpty,
        reason: 'a block that starts now cannot be booked any more',
      );
    });
  });

  group('DayWatchButton', () {
    const early = TimeBlock(
      id: 'e',
      startsAt: HourMinute(16, 0),
      endsAt: HourMinute(17, 0),
      position: 0,
      active: true,
    );
    const late = TimeBlock(
      id: 'l',
      startsAt: HourMinute(18, 0),
      endsAt: HourMinute(19, 0),
      position: 1,
      active: true,
    );

    late List<String> watchLog;
    late List<Day> unwatchLog;
    setUp(() {
      watchLog = [];
      unwatchLog = [];
    });

    Widget app({
      Map<Day, Set<String>> watched = const {},
      List<TimeBlock> blocks = const [early, late],
      Future<void> Function(Day, Set<String>)? watch,
    }) => ProviderScope(
      overrides: [
        myDayWatchesProvider.overrideWith((ref) => Stream.value(watched)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: DayWatchButton(
              date: today,
              blocks: blocks,
              watch: watch ??
                  (d, b) async =>
                      watchLog.add('${d.toSql()} ${([...b]..sort()).join(',')}'),
              unwatch: (d) async => unwatchLog.add(d),
            ),
          ),
        ),
      ),
    );

    Future<void> openSheet(WidgetTester tester) async {
      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();
    }

    bool selected(WidgetTester tester, String label) => tester
        .widget<FilterChip>(find.widgetWithText(FilterChip, label))
        .selected;

    testWidgets('off: the bell opens a sheet with the whole day chosen', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.notifications_none), findsOneWidget);
      expect(find.byTooltip('Hlídat uvolněná místa'), findsOneWidget);

      await openSheet(tester);
      expect(find.text('Hlídat uvolněná místa'), findsWidgets);
      expect(selected(tester, 'Celý den'), isTrue);
      expect(selected(tester, '16:00–17:00'), isFalse);
      expect(find.text('Přestat hlídat'), findsNothing);

      await tester.tap(find.text('Hlídat'));
      await tester.pumpAndSettle();
      expect(watchLog, ['2026-10-07 ']);
      expect(unwatchLog, isEmpty);
      expect(find.text(dayWatchOnMessage), findsOneWidget);
    });

    testWidgets('picking blocks replaces „Celý den“; none picked is the day '
        'again', (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await openSheet(tester);

      await tester.tap(find.text('18:00–19:00'));
      await tester.pump();
      expect(selected(tester, 'Celý den'), isFalse);
      expect(selected(tester, '18:00–19:00'), isTrue);

      await tester.tap(find.text('18:00–19:00'));
      await tester.pump();
      expect(selected(tester, 'Celý den'), isTrue);

      await tester.tap(find.text('16:00–17:00'));
      await tester.pump();
      await tester.tap(find.text('18:00–19:00'));
      await tester.pump();
      await tester.tap(find.text('Hlídat'));
      await tester.pumpAndSettle();
      expect(watchLog, ['2026-10-07 e,l']);
    });

    testWidgets('„Celý den“ clears the picked blocks', (tester) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await openSheet(tester);
      await tester.tap(find.text('16:00–17:00'));
      await tester.pump();
      await tester.tap(find.text('Celý den'));
      await tester.pump();
      expect(selected(tester, '16:00–17:00'), isFalse);
      await tester.tap(find.text('Hlídat'));
      await tester.pumpAndSettle();
      expect(watchLog, ['2026-10-07 ']);
    });

    testWidgets('on: the bell is lit; the sheet saves a new pick or stops', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(watched: {today: {'l'}}),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.notifications_active), findsOneWidget);

      await openSheet(tester);
      expect(selected(tester, '18:00–19:00'), isTrue);
      expect(selected(tester, 'Celý den'), isFalse);
      await tester.tap(find.text('16:00–17:00'));
      await tester.pump();
      await tester.tap(find.text('Uložit'));
      await tester.pumpAndSettle();
      expect(watchLog, ['2026-10-07 e,l']);

      await openSheet(tester);
      await tester.tap(find.text('Přestat hlídat'));
      await tester.pumpAndSettle();
      expect(unwatchLog, [today]);
    });

    testWidgets('a block that is gone from the day is not kept ticked', (
      tester,
    ) async {
      await tester.pumpWidget(app(watched: {today: {'gone'}}));
      await tester.pumpAndSettle();
      await openSheet(tester);
      expect(selected(tester, 'Celý den'), isTrue);
    });

    testWidgets('no blocks left to watch: no bell', (tester) async {
      await tester.pumpWidget(app(blocks: const []));
      await tester.pumpAndSettle();
      expect(find.byType(IconButton), findsNothing);
    });

    testWidgets('the chips and the buttons keep clear of each other', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await openSheet(tester);
      final a = tester.getRect(find.widgetWithText(FilterChip, '16:00–17:00'));
      final b = tester.getRect(find.widgetWithText(FilterChip, '18:00–19:00'));
      expect(b.left - a.right, greaterThanOrEqualTo(12));
    });

    testWidgets('a refusal reads as Czech copy', (tester) async {
      await tester.pumpWidget(
        app(watch: (_, _) async => throw Exception('too_many_watches')),
      );
      await tester.pumpAndSettle();
      await openSheet(tester);
      await tester.tap(find.text('Hlídat'));
      await tester.pumpAndSettle();
      expect(find.text('Hlídáš už 30 dní — některé vypni.'), findsOneWidget);
    });
  });
}

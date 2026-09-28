import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/duties.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/clubhouse/widgets/message_composers.dart';

/// The two composers (0051): the player's (Správci / Službě) and the
/// staff's (a day or a block, with a live recipient preview).
void main() {
  const me = Profile(
    id: 'me', displayName: 'Já Hráč', email: 'me@example.com',
    role: Role.player, status: ProfileStatus.approved,
  );
  final today = Day(2026, 10, 5);

  final b1 = TimeBlock(id: 'b1', startsAt: HourMinute(16, 0), endsAt: HourMinute(17, 0),
      position: 0, active: true);

  // The roster the duty set is filtered by (ids with an account), as
  // `message_send` filters it.
  const roster = [
    PlayerName(id: 'me', displayName: 'Já Hráč'),
    PlayerName(id: 'bara', displayName: 'Bára Kantýnská'),
    PlayerName(id: 'ghost', displayName: 'Hráč Bezúčtu', hasAccount: false),
  ];

  Widget app({
    MyDuty duty = MyDuty.none,
    List<DutyPeriod> periods = const [],
    List<DutyAssignment> assignments = const [],
    Day? date,
    TimeBlock? block,
    MessageAudience? preselect,
  }) =>
      ProviderScope(
        overrides: [
          myProfileProvider.overrideWith((ref) => Stream.value(me)),
          myDutyProvider.overrideWithValue(duty),
          dutyPeriodsProvider.overrideWith((ref) => Stream.value(periods)),
          dutyAssignmentsProvider.overrideWith((ref) => Stream.value(assignments)),
          playersProvider.overrideWith((ref) async => roster),
          nowProvider.overrideWith((ref) => Stream.value(DateTime(2026, 10, 5, 12))),
        ],
        child: MaterialApp(home: Scaffold(body: Consumer(builder: (context, ref, _) => TextButton(
          onPressed: () => showPlayerComposer(context, ref,
              date: date, block: block, preselect: preselect),
          child: const Text('open'),
        )))),
      );

  Future<void> open(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  FilledButton send(WidgetTester tester) =>
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Odeslat'));

  testWidgets('Službě is disabled with "Dnes nikdo neslouží" when nobody serves today',
      (tester) async {
    await tester.pumpWidget(app());
    await open(tester);
    expect(find.text('Správci'), findsOneWidget);
    expect(find.text('Službě'), findsOneWidget);
    expect(find.text('Dnes nikdo neslouží'), findsOneWidget);
    expect(tester.widget<RadioListTile<MessageAudience>>(
        find.widgetWithText(RadioListTile<MessageAudience>, 'Službě')).enabled, false);
  });

  testWidgets('Službě is enabled when someone else serves today', (tester) async {
    final period = DutyPeriod(id: 'p1', startsOn: today, endsOn: today);
    await tester.pumpWidget(app(
      periods: [period],
      assignments: const [DutyAssignment(periodId: 'p1', userId: 'bara')],
    ));
    await open(tester);
    expect(find.text('Dnes nikdo neslouží'), findsNothing);
  });

  testWidgets('…but not when I am the only one on duty', (tester) async {
    final period = DutyPeriod(id: 'p1', startsOn: today, endsOn: today);
    await tester.pumpWidget(app(
      periods: [period],
      assignments: const [DutyAssignment(periodId: 'p1', userId: 'me')],
    ));
    await open(tester);
    expect(find.text('Dnes nikdo neslouží'), findsOneWidget);
  });

  testWidgets('…nor when the only other one is a player without an account',
      (tester) async {
    final period = DutyPeriod(id: 'p1', startsOn: today, endsOn: today);
    await tester.pumpWidget(app(
      periods: [period],
      assignments: const [
        DutyAssignment(periodId: 'p1', userId: 'me'),
        DutyAssignment(periodId: 'p1', userId: 'ghost'),
      ],
    ));
    await open(tester);
    expect(find.text('Dnes nikdo neslouží'), findsOneWidget);
  });

  testWidgets('"Odeslat" is disabled until something is typed', (tester) async {
    await tester.pumpWidget(app());
    await open(tester);
    expect(send(tester).onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'Přijdu později.');
    await tester.pump();
    expect(send(tester).onPressed, isNotNull);
    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    expect(send(tester).onPressed, isNull);
  });

  testWidgets('opened from a training it names the training and preselects Službě when possible',
      (tester) async {
    final period = DutyPeriod(id: 'p1', startsOn: today, endsOn: today);
    await tester.pumpWidget(app(
      periods: [period],
      assignments: const [DutyAssignment(periodId: 'p1', userId: 'bara')],
      date: today, block: b1, preselect: MessageAudience.duty,
    ));
    await open(tester);
    expect(find.text('K tréninku po 5. 10. · 16:00–17:00'), findsOneWidget);
    expect(tester.widget<RadioGroup<MessageAudience>>(find.byType(RadioGroup<MessageAudience>))
        .groupValue, MessageAudience.duty);
  });

  testWidgets('a duty preselect falls back to Správci when nobody serves', (tester) async {
    await tester.pumpWidget(app(date: today, block: b1, preselect: MessageAudience.duty));
    await open(tester);
    expect(tester.widget<RadioGroup<MessageAudience>>(find.byType(RadioGroup<MessageAudience>))
        .groupValue, MessageAudience.admins);
  });

  group('showStaffComposer', () {
    final b1 = TimeBlock(id: 'b1', startsAt: HourMinute(16, 0), endsAt: HourMinute(17, 0),
        position: 0, active: true);
    const admin = Profile(
      id: 'admin', displayName: 'Adam', email: 'admin@example.com',
      role: Role.admin, status: ProfileStatus.approved,
    );

    Reservation booking(String id, String playerId, String blockId) => Reservation(
        id: id, playerId: playerId, date: today, blockId: blockId, lane: 1,
        createdVia: 'app', createdAt: DateTime(2026, 10, 1));

    Widget staffApp({
      List<Reservation> reservations = const [],
      List<TimeBlock> blocks = const [],
      String? blockId,
    }) => ProviderScope(
      overrides: [
        myProfileProvider.overrideWith((ref) => Stream.value(admin)),
        myDutyProvider.overrideWithValue(MyDuty.none),
        nowProvider.overrideWith((ref) => Stream.value(DateTime(2026, 10, 5, 12))),
        settingsProvider.overrideWith((ref) => Stream.value(ScheduleSettings.defaults)),
        timeBlocksProvider.overrideWith((ref) => Stream.value(blocks.isEmpty ? [b1] : blocks)),
        dayOverridesProvider.overrideWith((ref) => Stream.value(const [])),
        prioritySlotsProvider.overrideWithValue(const []),
        rentalsProvider.overrideWith((ref) => Stream.value(const [])),
        weekReservationsProvider.overrideWith((ref, monday) => Stream.value(reservations)),
        playersProvider.overrideWith((ref) async => const [
          PlayerName(id: 'admin', displayName: 'Adam'),
          PlayerName(id: 'p1', displayName: 'Petr Novák'),
          PlayerName(id: 'p2', displayName: 'Tomáš Válka'),
          PlayerName(id: 'ghost', displayName: 'Hráč Bezúčtu', hasAccount: false),
        ]),
      ],
      child: MaterialApp(home: Scaffold(body: Consumer(builder: (context, ref, _) => TextButton(
        onPressed: () => showStaffComposer(context, ref, date: today, blockId: blockId),
        child: const Text('open'),
      )))),
    );

    FilledButton send(WidgetTester tester) =>
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Odeslat'));

    Future<void> openStaff(WidgetTester tester) async {
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('shows the live "Dostane N hráči" preview under the day and the block', (tester) async {
      await tester.pumpWidget(staffApp(reservations: [booking('r1', 'p1', 'b1')]));
      await openStaff(tester);
      expect(find.text('Napsat hráčům'), findsOneWidget);
      // Once under „Celý den“, once under the 16:00–17:00 block — the
      // fixture's only booking is in that block.
      expect(find.text('Dostane 1 hráč: Petr Novák'), findsNWidgets(2));
      await tester.enterText(find.byType(TextField), 'Přijďte dřív.');
      await tester.pump();
      expect(send(tester).onPressed, isNotNull);
    });

    testWidgets('with nobody booked every preview says so and "Odeslat" stays off', (tester) async {
      await tester.pumpWidget(staffApp());
      await openStaff(tester);
      expect(find.text('Nikdo nemá rezervaci'), findsNWidgets(2));
      await tester.enterText(find.byType(TextField), 'Přijďte dřív.');
      await tester.pump();
      expect(send(tester).onPressed, isNull);
    });

    testWidgets('the author and a player without an account are not recipients, '
        'as on the server', (tester) async {
      await tester.pumpWidget(staffApp(reservations: [
        booking('r1', 'admin', 'b1'),
        booking('r2', 'ghost', 'b1'),
        booking('r3', 'p2', 'b1'),
        booking('r4', 'p1', 'b1'),
      ]));
      await openStaff(tester);
      // Czech-sorted, the admin's own booking and the placeholder's left out.
      expect(find.text('Dostane 2 hráči: Petr Novák a Tomáš Válka'), findsNWidgets(2));
    });

    testWidgets('"Odeslat" follows the selected target: on for a booked block, off for an empty one', (tester) async {
      final b2 = TimeBlock(id: 'b2', startsAt: HourMinute(17, 0), endsAt: HourMinute(18, 0),
          position: 1, active: true);
      await tester.pumpWidget(staffApp(
        blocks: [b1, b2],
        reservations: [booking('r1', 'p1', 'b1')],
      ));
      await openStaff(tester);
      await tester.enterText(find.byType(TextField), 'Přijďte dřív.');
      await tester.pump();
      expect(send(tester).onPressed, isNotNull); // „Celý den“ has Petr
      await tester.tap(find.text('17:00–18:00'));
      await tester.pump();
      expect(tester.widget<RadioGroup<String?>>(find.byType(RadioGroup<String?>)).groupValue, 'b2');
      expect(send(tester).onPressed, isNull); // b2 is empty
      await tester.tap(find.text('16:00–17:00'));
      await tester.pump();
      expect(send(tester).onPressed, isNotNull);
    });

    testWidgets('a prefilled block (the calendar\'s „Napsat hráčům bloku…“) is selected', (tester) async {
      await tester.pumpWidget(staffApp(reservations: [booking('r1', 'p1', 'b1')], blockId: 'b1'));
      await openStaff(tester);
      expect(find.text('5. 10. 2026'), findsOneWidget);
      expect(tester.widget<RadioGroup<String?>>(find.byType(RadioGroup<String?>)).groupValue, 'b1');
    });
  });

  group('staffSendErrorText', () {
    test('no_recipients names what was asked for: the block or the day', () {
      final e = Exception('no_recipients');
      expect(staffSendErrorText(e, toBlock: true, asDuty: false),
          'V tomto bloku nikdo nemá rezervaci.');
      expect(staffSendErrorText(e, toBlock: false, asDuty: false),
          'V tento den nikdo nemá rezervaci.');
    });

    test('date_past has its own text here', () {
      expect(staffSendErrorText(Exception('date_past'), toBlock: false, asDuty: true),
          'Minulým dnům už nejde psát.');
    });

    test('not_allowed as the duty means the duty ended; unknown_block keeps its text', () {
      expect(staffSendErrorText(Exception('not_allowed'), toBlock: false, asDuty: true),
          'Služba skončila — tohle teď může jen správce.');
      expect(staffSendErrorText(Exception('not_allowed'), toBlock: false, asDuty: false),
          'Na tohle nemáš oprávnění.');
      expect(staffSendErrorText(Exception('unknown_block'), toBlock: true, asDuty: false),
          'Tenhle blok už neplatí — mrkni na aktuální rozvrh.');
    });
  });
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show StateProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/duties.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/clubhouse/widgets/message_composers.dart';

/// One call of the composers' RPC, as [recorder] keeps it.
typedef Sent = ({
  MessageKind kind,
  MessageAudience audience,
  Day? onDate,
  String? blockId,
  String body,
});

/// Stands in for Api.messageSend (no Supabase): records each call into
/// [calls], then answers with [answer] — a new id when there is none.
MessageSend recorder(List<Sent> calls, {Future<String> Function()? answer}) =>
    ({
      required MessageKind kind,
      required MessageAudience audience,
      Day? onDate,
      String? blockId,
      String? title,
      required String body,
      DateTime? expiresAt,
      bool notify = true,
    }) {
      calls.add((kind: kind, audience: audience, onDate: onDate,
          blockId: blockId, body: body));
      return answer?.call() ?? Future.value('new-id');
    };

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
    MessageSend? send,
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
          onPressed: () => showPlayerComposer(context, ref, date: date,
              block: block, preselect: preselect, send: send ?? recorder([])),
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

  testWidgets('with the keyboard up the sheet ends above it: the field and '
      '„Odeslat“ are never scrolled to under the keyboard', (tester) async {
    // 800×600 logical; a 400-dp keyboard leaves 200 dp — less than the
    // sheet, so it scrolls, and its viewport must end where the keyboard
    // starts (a viewport under the keyboard reveals the caret behind it).
    tester.view.viewInsets = const FakeViewPadding(bottom: 1200);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(app());
    await open(tester);
    final scroll = find.ancestor(
        of: find.text('Napsat'), matching: find.byType(SingleChildScrollView));
    expect(tester.getRect(scroll).bottom, lessThanOrEqualTo(600 - 400));
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

  testWidgets('„Odeslat“ sends the trimmed text to Správci, then closes with '
      '„Zpráva odeslána.“', (tester) async {
    final calls = <Sent>[];
    final reply = Completer<String>();
    await tester.pumpWidget(app(send: recorder(calls, answer: () => reply.future)));
    await open(tester);
    await tester.enterText(find.byType(TextField), '  Přijdu později.  ');
    await tester.pump();
    await tester.tap(find.text('Odeslat'));
    await tester.pump();
    expect(calls, [(kind: MessageKind.message, audience: MessageAudience.admins,
        onDate: null, blockId: null, body: 'Přijdu později.')]);
    // Still open while it goes out, and not sendable twice.
    expect(send(tester).onPressed, isNull);
    reply.complete('new-id');
    await tester.pumpAndSettle();
    expect(find.text('Odeslat'), findsNothing);
    expect(find.text('Zpráva odeslána.'), findsOneWidget);
  });

  testWidgets('a double tap handled before the next frame sends once', (tester) async {
    final calls = <Sent>[];
    final reply = Completer<String>();
    await tester.pumpWidget(app(send: recorder(calls, answer: () => reply.future)));
    await open(tester);
    await tester.enterText(find.byType(TextField), 'Přijdu později.');
    await tester.pump();
    // Both taps land before a rebuild could disable „Odeslat“ (a janky frame).
    final odeslat = tester.getCenter(find.text('Odeslat'));
    await tester.tapAt(odeslat);
    await tester.tapAt(odeslat);
    await tester.pump();
    expect(calls, hasLength(1));
    reply.complete('new-id');
    await tester.pumpAndSettle();
    expect(find.text('Zpráva odeslána.'), findsOneWidget);
  });

  testWidgets('from a training, „Službě“ goes out with the training\'s on_date '
      'and block_id', (tester) async {
    final period = DutyPeriod(id: 'p1', startsOn: today, endsOn: today);
    final calls = <Sent>[];
    await tester.pumpWidget(app(
      periods: [period],
      assignments: const [DutyAssignment(periodId: 'p1', userId: 'bara')],
      date: today, block: b1, send: recorder(calls),
    ));
    await open(tester);
    await tester.tap(find.text('Službě'));
    await tester.enterText(find.byType(TextField), 'Přijdu o 10 minut později.');
    await tester.pump();
    await tester.tap(find.text('Odeslat'));
    await tester.pumpAndSettle();
    expect(calls, [(kind: MessageKind.message, audience: MessageAudience.duty,
        onDate: today, blockId: 'b1', body: 'Přijdu o 10 minut později.')]);
    expect(find.text('Zpráva odeslána.'), findsOneWidget);
  });

  testWidgets('a refused send keeps the sheet open with the text, says why, '
      'and can be sent again', (tester) async {
    final period = DutyPeriod(id: 'p1', startsOn: today, endsOn: today);
    final calls = <Sent>[];
    await tester.pumpWidget(app(
      periods: [period],
      assignments: const [DutyAssignment(periodId: 'p1', userId: 'bara')],
      preselect: MessageAudience.duty,
      // The duty was unassigned meanwhile: refused once, then through.
      send: recorder(calls, answer: () async => calls.length == 1
          ? throw Exception('nobody_on_duty')
          : 'new-id'),
    ));
    await open(tester);
    await tester.enterText(find.byType(TextField), 'Došel toaleťák.');
    await tester.pump();
    await tester.tap(find.text('Odeslat'));
    await tester.pumpAndSettle();
    expect(calls, hasLength(1));
    expect(find.text('Dnes nikdo neslouží — napiš správci.'), findsOneWidget);
    expect(find.text('Zpráva odeslána.'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Došel toaleťák.');
    expect(send(tester).onPressed, isNotNull);
    // The message sits over the sheet's bottom edge until tapped away
    // (core/messages.dart) — then „Odeslat“ again.
    await tester.tap(find.text('Dnes nikdo neslouží — napiš správci.'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Odeslat'));
    await tester.pumpAndSettle();
    expect(calls, hasLength(2));
    expect(find.text('Odeslat'), findsNothing);
    expect(find.text('Zpráva odeslána.'), findsOneWidget);
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

    // Stands in for Api.messageSend: succeeds without reaching Supabase.
    Future<String> sent({
      required MessageKind kind,
      required MessageAudience audience,
      Day? onDate,
      String? blockId,
      String? title,
      required String body,
      DateTime? expiresAt,
      bool notify = true,
    }) async => 'new-id';

    // [duty] backs myDutyProvider with a state a test can flip while the
    // sheet is open (midnight, an unassignment); [send] replaces the RPC.
    Widget staffApp({
      List<Reservation> reservations = const [],
      List<TimeBlock> blocks = const [],
      String? blockId,
      Profile profile = admin,
      StateProvider<MyDuty>? duty,
      MessageSend? send,
    }) => ProviderScope(
      overrides: [
        myProfileProvider.overrideWith((ref) => Stream.value(profile)),
        if (duty == null)
          myDutyProvider.overrideWithValue(MyDuty.none)
        else
          myDutyProvider.overrideWith((ref) => ref.watch(duty)),
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
      // Czech, for „Změnit“'s date picker (pickDay asks for cs).
      child: MaterialApp(
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          supportedLocales: const [Locale('cs')],
          home: Scaffold(body: Consumer(builder: (context, ref, _) => TextButton(
        onPressed: () => showStaffComposer(context, ref,
            date: today, blockId: blockId, send: send ?? sent),
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

    Future<void> typeAndSend(WidgetTester tester) async {
      await tester.enterText(find.byType(TextField), '  Přijďte dřív.  ');
      await tester.pump();
      await tester.tap(find.text('Odeslat'));
      await tester.pumpAndSettle();
    }

    testWidgets('„Celý den“ goes out as a day message, no block, on the sheet\'s date',
        (tester) async {
      final calls = <Sent>[];
      await tester.pumpWidget(staffApp(
          reservations: [booking('r1', 'p1', 'b1')], send: recorder(calls)));
      await openStaff(tester);
      await typeAndSend(tester);
      expect(calls, [(kind: MessageKind.message, audience: MessageAudience.day,
          onDate: today, blockId: null, body: 'Přijďte dřív.')]);
      expect(find.text('Napsat hráčům'), findsNothing);
      expect(find.text('Zpráva odeslána.'), findsOneWidget);
    });

    testWidgets('a double tap handled before the next frame sends one push, not two',
        (tester) async {
      final calls = <Sent>[];
      final reply = Completer<String>();
      await tester.pumpWidget(staffApp(reservations: [booking('r1', 'p1', 'b1')],
          send: recorder(calls, answer: () => reply.future)));
      await openStaff(tester);
      await tester.enterText(find.byType(TextField), 'Přijďte dřív.');
      await tester.pump();
      // Both taps land before a rebuild could disable „Odeslat“ (a janky frame).
      final odeslat = tester.getCenter(find.text('Odeslat'));
      await tester.tapAt(odeslat);
      await tester.tapAt(odeslat);
      await tester.pump();
      expect(calls, hasLength(1));
      reply.complete('new-id');
      await tester.pumpAndSettle();
      expect(find.text('Zpráva odeslána.'), findsOneWidget);
    });

    testWidgets('a picked block goes out as a block message with its id', (tester) async {
      final calls = <Sent>[];
      await tester.pumpWidget(staffApp(
          reservations: [booking('r1', 'p1', 'b1')], send: recorder(calls)));
      await openStaff(tester);
      await tester.tap(find.text('16:00–17:00'));
      await tester.pump();
      await typeAndSend(tester);
      expect(calls, [(kind: MessageKind.message, audience: MessageAudience.block,
          onDate: today, blockId: 'b1', body: 'Přijďte dřív.')]);
      expect(find.text('Zpráva odeslána.'), findsOneWidget);
    });

    testWidgets('a picked date goes out as on_date', (tester) async {
      final calls = <Sent>[];
      final wednesday = Day(2026, 10, 7);
      await tester.pumpWidget(staffApp(send: recorder(calls), reservations: [
        Reservation(id: 'r2', playerId: 'p2', date: wednesday, blockId: 'b1', lane: 1,
            createdVia: 'app', createdAt: DateTime(2026, 10, 1)),
      ]));
      await openStaff(tester);
      await tester.tap(find.text('Změnit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('7'));
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('7. 10. 2026'), findsOneWidget);
      await typeAndSend(tester);
      expect(calls, [(kind: MessageKind.message, audience: MessageAudience.day,
          onDate: wednesday, blockId: null, body: 'Přijďte dřív.')]);
    });

    testWidgets('a duty whose service ends while the sheet is open reads the refusal '
        'as „Služba skončila“', (tester) async {
      final onDuty = MyDuty(current: DutyPeriod(id: 'p1', startsOn: today, endsOn: today));
      final duty = StateProvider<MyDuty>((ref) => onDuty);
      final calls = <({MessageAudience audience, Day? onDate, String? blockId})>[];
      Future<String> refused({
        required MessageKind kind,
        required MessageAudience audience,
        Day? onDate,
        String? blockId,
        String? title,
        required String body,
        DateTime? expiresAt,
        bool notify = true,
      }) async {
        calls.add((audience: audience, onDate: onDate, blockId: blockId));
        throw Exception('not_allowed');
      }

      await tester.pumpWidget(staffApp(
        profile: me,
        duty: duty,
        send: refused,
        reservations: [booking('r1', 'p1', 'b1')],
      ));
      await openStaff(tester);
      await tester.enterText(find.byType(TextField), 'Přijďte dřív.');
      await tester.pump();
      // 23:59 → 00:00: the duty's period is over, the sheet is still open.
      ProviderScope.containerOf(tester.element(find.text('Napsat hráčům')))
          .read(duty.notifier)
          .state = MyDuty.none;
      await tester.pump();
      await tester.tap(find.text('Odeslat'));
      await tester.pumpAndSettle();
      expect(calls, [(audience: MessageAudience.day, onDate: today, blockId: null)]);
      expect(find.text('Služba skončila — tohle teď může jen správce.'), findsOneWidget);
      expect(find.text('Na tohle nemáš oprávnění.'), findsNothing);
      // Refused: the sheet stays, the text kept.
      expect(find.text('Napsat hráčům'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'Přijďte dřív.');
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

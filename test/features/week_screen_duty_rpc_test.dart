import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/day_edit.dart' show blockStartedMessage;
import 'package:rezervator/domain/groups.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/schedule/week_calendar_view.dart';
import 'package:rezervator/features/schedule/week_screen.dart';
import 'package:rezervator/features/schedule/widgets/day_chip_strip.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Pins the calendar's own flows for the player on canteen duty (0050) at
/// the HTTP layer: what booking, cancelling and the ⋮ day edits send, and
/// that a refusal after the duty ended says so instead of "no rights".
void main() {
  const dutyEnded = 'Služba skončila — tohle teď může jen správce.';
  const refusal =
      '{"code":"P0001","message":"not_allowed","details":null,"hint":null}';

  // The server's refusals: every write RPC the calendar flows call.
  const refused = {
    '/rpc/create_reservation',
    '/rpc/cancel_reservation',
    '/rpc/set_day_override',
  };

  late List<http.Request> requests;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final mock = MockClient((request) async {
      requests.add(request);
      if (refused.any(request.url.path.endsWith)) {
        return http.Response(
          refusal,
          400,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }
      // Nothing to cancel: the day flows skip their count confirm.
      final body = request.method == 'GET' ? '[]' : '{}';
      // postgrest reads response.request — MockClient doesn't attach it
      // unless we do.
      return http.Response(
        body,
        200,
        headers: {'content-type': 'application/json'},
        request: request,
      );
    });
    await Supabase.initialize(
      url: 'http://localhost:54321',
      publishableKey: 'test-anon-key',
      httpClient: mock,
      authOptions: const FlutterAuthClientOptions(
        detectSessionInUri: false,
        localStorage: EmptyLocalStorage(),
      ),
    );
  });

  setUp(() {
    requests = [];
    SharedPreferences.setMockInitialValues({});
  });

  // Pinned like week_screen_test's clock: a Wednesday morning, so tomorrow
  // is in the drawn week whatever the real date.
  final now = DateTime(2026, 9, 9, 10, 0);
  final t = Day.fromDateTime(now);
  final tomorrow = t.addDays(1);

  const settings = ScheduleSettings(
    laneCount: 2,
    trainingWeekdays: {1, 2, 3, 4, 5, 6, 7},
    bookingHorizonDays: 14,
    maxActiveReservations: 3,
  );
  const b1 = TimeBlock(
    id: 'b1',
    startsAt: HourMinute(22, 58),
    endsAt: HourMinute(23, 59),
    position: 0,
    active: true,
  );
  const me = Profile(
    id: 'me',
    displayName: 'Já Hráč',
    email: 'me@example.com',
    role: Role.player,
    status: ProfileStatus.approved,
  );
  // An admin who is also assigned the duty: the admin's own rights cover
  // it, so a refusal is not the duty ending.
  const admin = Profile(
    id: 'me',
    displayName: 'Já Hráč',
    email: 'me@example.com',
    role: Role.admin,
    status: ProfileStatus.approved,
  );
  const players = [
    PlayerName(id: 'me', displayName: 'Já Hráč'),
    PlayerName(id: 'p2', displayName: 'Petr Novák', nick: 'Péťa'),
  ];
  final week = DutyPeriod(
    id: 'd1',
    startsOn: Day(2026, 9, 7),
    endsOn: Day(2026, 9, 13),
  );

  // week_screen_test's `app`, cut down: I am on duty this week.
  // [clock]: a clock a test moves on; the pinned [now] otherwise.
  Widget app({
    List<DayOverride> overrides = const [],
    List<Reservation> reservations = const [],
    Stream<DateTime>? clock,
    Profile profile = me,
    List<TimeBlock> blocks = const [b1],
    // My period; [week] (on duty today) unless a test needs another.
    DutyPeriod? period,
  }) {
    return ProviderScope(
      overrides: [
        activeReservationCountProvider.overrideWith((ref, id) async => 0),
        settingsProvider.overrideWith((ref) => Stream.value(settings)),
        timeBlocksProvider.overrideWith((ref) => Stream.value(blocks)),
        dayOverridesProvider.overrideWith((ref) => Stream.value(overrides)),
        prioritySlotsProvider.overrideWithValue(const []),
        prioritySlotsLoadingProvider.overrideWithValue(false),
        matchResultsProvider.overrideWith((ref) => Stream.value(const {})),
        venuesProvider.overrideWith((ref) => Stream.value(const [])),
        rentalsProvider.overrideWith((ref) => Stream.value(const [])),
        weekReservationsProvider.overrideWith(
          (ref, monday) => Stream.value(reservations),
        ),
        myActiveReservationsProvider.overrideWith(
          (ref) => Stream.value(const []),
        ),
        myProfileProvider.overrideWith((ref) => Stream.value(profile)),
        playersProvider.overrideWith((ref) async => players),
        nowProvider.overrideWith((ref) => clock ?? Stream.value(now)),
        myGroupProvider.overrideWithValue(MyGroup.none),
        dutyPeriodsProvider.overrideWith(
          (ref) => Stream.value([period ?? week]),
        ),
        dutyAssignmentsProvider.overrideWith(
          (ref) => Stream.value(const [
            DutyAssignment(periodId: 'd1', userId: 'me'),
          ]),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: WeekScreen())),
    );
  }

  void wideSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Map<String, dynamic> bodyOf(String rpc) =>
      jsonDecode(
            requests.singleWhere((r) => r.url.path.endsWith('/rpc/$rpc')).body,
          )
          as Map<String, dynamic>;

  testWidgets('booking for another player: that player\'s id; a refusal '
      'says the duty ended', (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    final add = find.descendant(
      of: find.byKey(ValueKey(tomorrow)),
      matching: find.byIcon(Icons.add),
    );
    await tester.ensureVisible(add.first);
    await tester.pumpAndSettle();
    await tester.tap(add.first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Petr Novák'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Rezervovat'));
    await tester.pumpAndSettle();

    final body = bodyOf('create_reservation');
    expect(body['p_player_id'], 'p2');
    expect(body['p_date'], tomorrow.toSql());
    expect(find.text(dutyEnded), findsOneWidget);
  });

  testWidgets('an admin also on duty: a refusal reads plainly, not as the '
      'duty ended', (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(app(profile: admin));
    await tester.pumpAndSettle();

    final add = find.descendant(
      of: find.byKey(ValueKey(tomorrow)),
      matching: find.byIcon(Icons.add),
    );
    await tester.ensureVisible(add.first);
    await tester.pumpAndSettle();
    await tester.tap(add.first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Petr Novák'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Rezervovat'));
    await tester.pumpAndSettle();

    expect(bodyOf('create_reservation')['p_player_id'], 'p2');
    expect(find.text('Na tohle nemáš oprávnění.'), findsOneWidget);
    expect(find.text(dutyEnded), findsNothing);
  });

  testWidgets('cancelling another player\'s reservation: a refusal says the '
      'duty ended', (tester) async {
    wideSurface(tester);
    await tester.pumpWidget(
      app(
        reservations: [
          Reservation(
            id: 'r2',
            playerId: 'p2',
            date: tomorrow,
            blockId: 'b1',
            lane: 2,
            createdVia: 'app',
            createdAt: DateTime.utc(2026, 1, 1),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final cell = find.descendant(
      of: find.byKey(ValueKey(tomorrow)),
      matching: find.text('Péťa'),
    );
    await tester.ensureVisible(cell);
    await tester.pumpAndSettle();
    await tester.tap(cell);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zrušit bez zprávy'));
    await tester.pumpAndSettle();

    final body = bodyOf('cancel_reservation');
    expect(body['p_id'], 'r2');
    expect(body['p_notify'], isFalse);
    expect(find.text(dutyEnded), findsOneWidget);
  });

  // Portrait, tomorrow picked through the chip strip (the pager's own first
  // page follows the real clock), then [label] from its ⋮.
  Future<void> pickFromMenu(WidgetTester tester, String label) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(
            of: find.byType(DayChipStrip),
            matching: find.byType(InkWell),
          )
          .at(t.weekday),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  testWidgets('⋮ „Zavřít den…“: a refusal says the duty ended', (tester) async {
    await tester.pumpWidget(app());
    await pickFromMenu(tester, 'Zavřít den…');
    await tester.enterText(find.byType(TextField), 'Malování');
    await tester.tap(find.widgetWithText(FilledButton, 'Zavřít den'));
    await tester.pumpAndSettle();

    final body = bodyOf('set_day_override');
    expect(body['p_date'], tomorrow.toSql());
    expect(body['p_closed'], isTrue);
    expect(find.text(dutyEnded), findsOneWidget);
  });

  // A duty not on duty today edits its own days all the same (0050, rule
  // A); a refusal there — its period gone meanwhile — still reads as the
  // duty ended, not as „no rights“.
  testWidgets('⋮ „Zavřít den…“ of a duty starting tomorrow: a refusal says '
      'the duty ended', (tester) async {
    await tester.pumpWidget(app(
      period: DutyPeriod(id: 'd1', startsOn: tomorrow, endsOn: tomorrow.addDays(2)),
    ));
    await pickFromMenu(tester, 'Zavřít den…');
    await tester.enterText(find.byType(TextField), 'Malování');
    await tester.tap(find.widgetWithText(FilledButton, 'Zavřít den'));
    await tester.pumpAndSettle();

    expect(bodyOf('set_day_override')['p_date'], tomorrow.toSql());
    expect(find.text(dutyEnded), findsOneWidget);
  });

  testWidgets('⋮ „Obnovit týdenní rozvrh“: a refusal says the duty ended', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        overrides: [
          DayOverride(
            date: tomorrow,
            closed: false,
            reason: '',
            blockIds: const ['b1'],
          ),
        ],
      ),
    );
    await pickFromMenu(tester, 'Obnovit týdenní rozvrh');

    final body = bodyOf('set_day_override');
    expect(body['p_date'], tomorrow.toSql());
    expect(body['p_block_ids'], ['b1']);
    expect(find.text(dutyEnded), findsOneWidget);
  });

  testWidgets('moving a block: the clock is asked again after the notify '
      'choice — a block that started meanwhile writes nothing', (
    tester,
  ) async {
    wideSurface(tester);
    final clock = StreamController<DateTime>();
    addTearDown(clock.close);
    clock.add(now);
    await tester.pumpWidget(
      app(
        clock: clock.stream,
        reservations: [
          Reservation(
            id: 'r2',
            playerId: 'p2',
            date: t,
            blockId: 'b1',
            lane: 2,
            createdVia: 'app',
            createdAt: DateTime.utc(2026, 1, 1),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    tester
        .widget<WeekCalendarView>(find.byType(WeekCalendarView))
        .admin
        .onMoveBlock!(t, b1, const HourMinute(21, 0));
    await tester.pumpAndSettle();
    expect(find.text('Upozornit na přesun?'), findsOneWidget);

    // b1 (22:58) starts while the choice is open.
    clock.add(DateTime(2026, 9, 9, 22, 58));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Odeslat'));
    await tester.pumpAndSettle();

    expect(find.text(blockStartedMessage), findsOneWidget);
    expect(requests.where((r) => r.method != 'GET'), isEmpty);
  });

  testWidgets('moving a block: a new start that passed during the notify '
      'choice writes nothing — the snack reads the real time', (
    tester,
  ) async {
    wideSurface(tester);
    final clock = StreamController<DateTime>();
    addTearDown(clock.close);
    clock.add(now);
    await tester.pumpWidget(
      app(
        clock: clock.stream,
        reservations: [
          Reservation(
            id: 'r2',
            playerId: 'p2',
            date: t,
            blockId: 'b1',
            lane: 2,
            createdVia: 'app',
            createdAt: DateTime.utc(2026, 1, 1),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    tester
        .widget<WeekCalendarView>(find.byType(WeekCalendarView))
        .admin
        .onMoveBlock!(t, b1, const HourMinute(21, 0));
    await tester.pumpAndSettle();
    expect(find.text('Upozornit na přesun?'), findsOneWidget);

    // 21:30 while the choice is open: the new 21:00 start has passed, b1
    // (22:58) has not started.
    clock.add(DateTime(2026, 9, 9, 21, 30));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Odeslat'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Blok nemůže začínat dřív než teď (21:30) — vyber pozdější začátek.',
      ),
      findsOneWidget,
    );
    expect(requests.where((r) => r.method != 'GET'), isEmpty);
  });

  // Right before the write a block starting within the next minute counts
  // as started: the minute clock may lag by seconds.
  const b0 = TimeBlock(
    id: 'b0',
    startsAt: HourMinute(22, 0),
    endsAt: HourMinute(22, 30),
    position: 0,
    active: true,
  );
  for (final withSignUp in [true, false]) {
    testWidgets('moving a block that starts in 30 s writes nothing '
        '(${withSignUp ? 'after' : 'without'} the notify choice)', (
      tester,
    ) async {
      wideSurface(tester);
      final clock = StreamController<DateTime>();
      addTearDown(clock.close);
      clock.add(withSignUp ? now : DateTime(2026, 9, 9, 21, 59));
      await tester.pumpWidget(
        app(
          blocks: const [b0],
          clock: clock.stream,
          reservations: [
            if (withSignUp)
              Reservation(
                id: 'r2',
                playerId: 'p2',
                date: t,
                blockId: 'b0',
                lane: 2,
                createdVia: 'app',
                createdAt: DateTime.utc(2026, 1, 1),
              ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      tester
          .widget<WeekCalendarView>(find.byType(WeekCalendarView))
          .admin
          .onMoveBlock!(t, b0, const HourMinute(23, 0));
      await tester.pumpAndSettle();
      if (withSignUp) {
        // b0 (22:00) is still a minute away when the choice is made.
        clock.add(DateTime(2026, 9, 9, 21, 59));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Odeslat'));
        await tester.pumpAndSettle();
      }

      expect(find.text(blockStartedMessage), findsOneWidget);
      expect(requests.where((r) => r.method != 'GET'), isEmpty);
    });
  }
}

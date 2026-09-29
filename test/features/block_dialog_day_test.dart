import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rezervator/core/ui.dart' show dayFull;
import 'package:rezervator/domain/day_edit.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/admin/widgets/block_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Pins the DAY-SCOPED BlockDialog save path at the HTTP layer: editing a
/// block from the calendar must NOT touch the weekly template — it adds an
/// inactive "special" block (add_special_block, 0050) and points the day's
/// override at it. Both day writes go through RPCs, never the tables: the
/// player on duty may call those, not write the tables.
void main() {
  const b1 = TimeBlock(
    id: 'b1',
    startsAt: HourMinute(16, 0),
    endsAt: HourMinute(17, 0),
    position: 0,
    active: true,
  );
  const b2 = TimeBlock(
    id: 'b2',
    startsAt: HourMinute(17, 0),
    endsAt: HourMinute(18, 0),
    position: 1,
    active: true,
  );
  final thursday = Day(2026, 7, 16);

  late List<http.Request> requests;
  var reservationsBody = '[]';
  // The server's refusal of set_day_override (0050: a duty that just ended).
  var refuseOverride = false;
  // The server's refusal of move_day_reservations (0050: a block of today
  // that has started meanwhile).
  var refuseMoveTooLate = false;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final mock = MockClient((request) async {
      requests.add(request);
      String body = '{}';
      if (refuseOverride && request.url.path.endsWith('/rpc/set_day_override')) {
        return http.Response(
            '{"code":"P0001","message":"not_allowed","details":null,"hint":null}',
            400,
            headers: {'content-type': 'application/json'},
            request: request);
      }
      if (refuseMoveTooLate &&
          request.url.path.endsWith('/rpc/move_day_reservations')) {
        return http.Response(
            '{"code":"P0001","message":"too_late","details":null,"hint":null}',
            400,
            headers: {'content-type': 'application/json'},
            request: request);
      }
      if (request.method == 'GET' && request.url.path.contains('reservations')) {
        body = reservationsBody;
      } else if (request.method == 'POST' &&
          request.url.path.endsWith('/rpc/add_special_block')) {
        body = '"sb1"';
      }
      // postgrest reads response.request — MockClient doesn't attach it
      // unless we do.
      return http.Response(body, 200,
          headers: {'content-type': 'application/json'}, request: request);
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
    reservationsBody = '[]';
    refuseOverride = false;
    refuseMoveTooLate = false;
  });

  Widget app(BlockDialog dialog) =>
      MaterialApp(home: Scaffold(body: dialog));

  testWidgets(
      'day-scoped save inserts an INACTIVE special block and swaps it into '
      'the day override — the weekly block row is never updated', (
    tester,
  ) async {
    await tester.pumpWidget(app(BlockDialog(
      existing: b2,
      blocks: const [b1, b2],
      // Changed times (prefill wins over b2's own): 17:00-18:00 → 17:30-18:30.
      initialStart: const HourMinute(17, 30),
      initialEnd: const HourMinute(18, 30),
      dayContext: thursday,
      dayBaseIds: const ['b1', 'b2'],
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('Upravit blok — jen'), findsOneWidget);

    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();

    // 1) The special block: the RPC makes it inactive at position -1; the
    //    app sends the picked times.
    final insert = requests.firstWhere(
      (r) => r.method == 'POST' && r.url.path.endsWith('/rpc/add_special_block'),
    );
    final insertBody = jsonDecode(insert.body) as Map<String, dynamic>;
    expect(insertBody, {'p_starts_at': '17:30:00', 'p_ends_at': '18:30:00'});

    // 2) The edited block's sign-ups MOVE to the special (never cancel).
    final move = requests.firstWhere(
      (r) =>
          r.method == 'POST' && r.url.path.contains('move_day_reservations'),
    );
    final moveBody = jsonDecode(move.body) as Map<String, dynamic>;
    expect(moveBody['p_from_block'], 'b2');
    expect(moveBody['p_to_block'], 'sb1');

    // 3) The override RPC: b2 replaced by the special block, b1 kept.
    final rpc = requests.firstWhere(
      (r) => r.method == 'POST' && r.url.path.contains('set_day_override'),
    );
    final rpcBody = jsonDecode(rpc.body) as Map<String, dynamic>;
    expect(rpcBody['p_date'], thursday.toSql());
    expect(rpcBody['p_closed'], false);
    expect(rpcBody['p_block_ids'], ['b1', 'sb1']);

    // 4) Nothing hits the time_blocks table itself: no PATCH of the weekly
    //    row, no direct insert.
    expect(
      requests.any((r) => r.url.path.endsWith('/rest/v1/time_blocks')),
      isFalse,
    );
  });

  testWidgets(
      'an existing inactive SPECIAL (position -1) with the same times is '
      'REUSED — no new insert; a deactivated template block never is', (
    tester,
  ) async {
    const special = TimeBlock(
      id: 'sb-existing',
      startsAt: HourMinute(18, 0),
      endsAt: HourMinute(19, 0),
      position: -1, // the SPECIAL sentinel — only these are reused
      active: false,
    );
    // Same times, but a deactivated TEMPLATE block (position >= 0): must
    // NOT be grabbed — it belongs to the weekly template's history.
    const retired = TimeBlock(
      id: 'retired',
      startsAt: HourMinute(18, 0),
      endsAt: HourMinute(19, 0),
      position: 3,
      active: false,
    );
    await tester.pumpWidget(app(BlockDialog(
      existing: null,
      blocks: const [b1, b2, retired, special],
      initialStart: const HourMinute(18, 0),
      initialEnd: const HourMinute(19, 0),
      dayContext: thursday,
      dayBaseIds: const ['b1', 'b2'],
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();

    expect(
      requests.any((r) => r.url.path.endsWith('/rpc/add_special_block')),
      isFalse,
    );
    final rpc = requests.firstWhere(
      (r) => r.method == 'POST' && r.url.path.contains('set_day_override'),
    );
    expect((jsonDecode(rpc.body) as Map)['p_block_ids'],
        ['b1', 'b2', 'sb-existing']);
  });

  testWidgets('unchanged times on a block the day already uses is a NO-OP: '
      'the dialog closes without any write', (tester) async {
    await tester.pumpWidget(app(BlockDialog(
      existing: b2,
      blocks: const [b1, b2],
      dayContext: thursday,
      dayBaseIds: const ['b1', 'b2'],
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();

    expect(requests, isEmpty);
    expect(find.byType(BlockDialog), findsNothing); // popped
  });

  testWidgets('a base block overlapped by the new times gets the '
      'informative "Blok bude skryt" confirm; confirming proceeds', (
    tester,
  ) async {
    await tester.pumpWidget(app(BlockDialog(
      existing: null,
      blocks: const [b1, b2],
      initialStart: const HourMinute(17, 0),
      initialEnd: const HourMinute(18, 0),
      dayContext: thursday,
      dayBaseIds: const ['b1', 'b2'],
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();

    // The suppression is reversible, so the confirm explains rather than
    // alarms — and the base list keeps the hidden block's id.
    expect(find.text('Blok bude skryt'), findsOneWidget);
    expect(find.textContaining('Zobrazí se zase'), findsOneWidget);
    await tester.tap(find.text('Pokračovat'));
    await tester.pumpAndSettle();

    final rpc = requests.firstWhere(
      (r) => r.method == 'POST' && r.url.path.contains('set_day_override'),
    );
    expect(
        (jsonDecode(rpc.body) as Map)['p_block_ids'], ['b1', 'b2', 'sb1']);
  });

  testWidgets('Obnovit týdenní rozvrh composes the template ids and deletes '
      'the override row', (tester) async {
    await tester.pumpWidget(app(BlockDialog(
      existing: b2,
      blocks: const [b1, b2],
      dayContext: thursday,
      dayBaseIds: const ['b1'],
      dayHasOverride: true,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Obnovit týdenní rozvrh'));
    await tester.pumpAndSettle();

    final rpc = requests.firstWhere(
      (r) => r.method == 'POST' && r.url.path.contains('set_day_override'),
    );
    expect((jsonDecode(rpc.body) as Map)['p_block_ids'], ['b1', 'b2']);
    final delete = requests.firstWhere(
        (r) => r.url.path.endsWith('/rpc/delete_day_override'));
    expect(jsonDecode(delete.body), {'p_date': thursday.toSql()});
    expect(
      requests.any((r) => r.url.path.endsWith('/rest/v1/day_overrides')),
      isFalse,
    );
  });

  testWidgets('Odebrat v tento den drops only this block from the override', (
    tester,
  ) async {
    await tester.pumpWidget(app(BlockDialog(
      existing: b2,
      blocks: const [b1, b2],
      dayContext: thursday,
      dayBaseIds: const ['b1', 'b2'],
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Odebrat v tento den'));
    await tester.pumpAndSettle();

    final rpc = requests.firstWhere(
      (r) => r.method == 'POST' && r.url.path.contains('set_day_override'),
    );
    final rpcBody = jsonDecode(rpc.body) as Map<String, dynamic>;
    expect(rpcBody['p_block_ids'], ['b1']);
    expect(rpcBody['p_closed'], false);
  });

  testWidgets('editing a special to EXACTLY copy a template block dissolves '
      'the fork: reservations move, override restores, row is deleted', (
    tester,
  ) async {
    const special = TimeBlock(
      id: 'sp1',
      startsAt: HourMinute(17, 30),
      endsAt: HourMinute(18, 30),
      position: -1,
      active: false,
    );
    await tester.pumpWidget(app(BlockDialog(
      existing: special,
      blocks: const [b1, b2, special],
      // Edited back to b2's exact times.
      initialStart: const HourMinute(17, 0),
      initialEnd: const HourMinute(18, 0),
      dayContext: thursday,
      dayBaseIds: const ['b1', 'sp1'],
      dayHasOverride: true,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();

    // 1) The special's sign-ups move to the template twin…
    final move = requests.firstWhere(
      (r) =>
          r.method == 'POST' && r.url.path.contains('move_day_reservations'),
    );
    final moveBody = jsonDecode(move.body) as Map<String, dynamic>;
    expect(moveBody['p_from_block'], 'sp1');
    expect(moveBody['p_to_block'], 'b2');

    // 2) …the ids match the template exactly, so the fork fully unwinds:
    //    template override write (cancels strays via RPC) + row delete.
    final rpc = requests.firstWhere(
      (r) => r.method == 'POST' && r.url.path.contains('set_day_override'),
    );
    expect((jsonDecode(rpc.body) as Map)['p_block_ids'], ['b1', 'b2']);
    expect(
      requests.any((r) => r.url.path.endsWith('/rpc/delete_day_override')),
      isTrue,
    );
    // 3) No new special was added.
    expect(
      requests.any((r) => r.url.path.endsWith('/rpc/add_special_block')),
      isFalse,
    );
  });

  testWidgets('hiding a template block WITH live sign-ups counts them in the '
      'confirm and cancels them via RPC before the override write', (
    tester,
  ) async {
    reservationsBody =
        '[{"date":"${thursday.toSql()}","lane":1,"block_id":"b2"}]';
    await tester.pumpWidget(app(BlockDialog(
      existing: null,
      blocks: const [b1, b2],
      initialStart: const HourMinute(17, 0),
      initialEnd: const HourMinute(18, 0),
      dayContext: thursday,
      dayBaseIds: const ['b1', 'b2'],
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();

    // The confirm is honest about the cancellations…
    expect(find.text('Blok bude skryt'), findsOneWidget);
    expect(
      find.textContaining('1 rezervací na skrytých blocích bude zrušeno'),
      findsOneWidget,
    );
    await tester.tap(find.text('Pokračovat'));
    await tester.pumpAndSettle();

    // …and the hidden block's rows are swept via the dedicated RPC before
    // the override write — no invisible live reservations survive a hide.
    final cancel = requests.firstWhere(
      (r) =>
          r.method == 'POST' &&
          r.url.path.contains('cancel_block_day_reservations'),
    );
    expect((jsonDecode(cancel.body) as Map)['p_block'], 'b2');
    expect(
      requests.any((r) => r.url.path.contains('set_day_override')),
      isTrue,
    );
  });

  testWidgets("a moved block whose only sign-up is a hráč bez účtu skips the "
      'notify choice and moves silently', (tester) async {
    reservationsBody = '[{"date":"${thursday.toSql()}","lane":1,'
        '"block_id":"b2","player_id":"ph1"}]';
    await tester.pumpWidget(app(BlockDialog(
      existing: b2,
      blocks: const [b1, b2],
      initialStart: const HourMinute(19, 0),
      initialEnd: const HourMinute(20, 0),
      dayContext: thursday,
      dayBaseIds: const ['b1', 'b2'],
      noAccountIds: const {'ph1'},
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();

    expect(find.text('Upozornit na přesun?'), findsNothing);
    final move = requests.firstWhere(
      (r) =>
          r.method == 'POST' && r.url.path.contains('move_day_reservations'),
    );
    expect((jsonDecode(move.body) as Map)['p_notify'], false);
  });

  testWidgets('editing a block that has a reservation does NOT threaten a '
      'cancellation — the sign-up moves with the block', (tester) async {
    reservationsBody =
        '[{"date":"${thursday.toSql()}","lane":1,"block_id":"b2"}]';
    await tester.pumpWidget(app(BlockDialog(
      existing: b2,
      blocks: const [b1, b2],
      initialStart: const HourMinute(19, 0),
      initialEnd: const HourMinute(20, 0),
      dayContext: thursday,
      dayBaseIds: const ['b1', 'b2'],
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();

    // No 'Pozor — rezervace budou zrušeny' — the reservation is kept and
    // moved onto the new special instead; phase 3 asks about notifying
    // the moved player (choose silent here).
    expect(find.text('Pozor — rezervace budou zrušeny'), findsNothing);
    expect(find.text('Upozornit na přesun?'), findsOneWidget);
    await tester.tap(find.text('Neposílat'));
    await tester.pumpAndSettle();

    final move = requests.firstWhere(
      (r) =>
          r.method == 'POST' && r.url.path.contains('move_day_reservations'),
    );
    final moveBody = jsonDecode(move.body) as Map;
    expect(moveBody['p_from_block'], 'b2');
    expect(moveBody['p_notify'], false);
    expect(
      requests.any(
          (r) => r.url.path.contains('cancel_block_day_reservations')),
      isFalse,
    );
  });

  testWidgets('overlapping a block a match ALREADY cancelled (not rendered, '
      'no live rows) saves silently — no "Blok bude skryt"', (tester) async {
    await tester.pumpWidget(app(BlockDialog(
      existing: null,
      blocks: const [b1, b2],
      initialStart: const HourMinute(17, 0),
      initialEnd: const HourMinute(18, 0),
      dayContext: thursday,
      dayBaseIds: const ['b1', 'b2'],
      // b2 is match-cancelled: it does not render.
      dayRenderedIds: const {'b1'},
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();

    expect(find.text('Blok bude skryt'), findsNothing);
    expect(
      requests.any((r) => r.url.path.contains('set_day_override')),
      isTrue,
    );
    expect(
      requests.any(
          (r) => r.url.path.contains('cancel_block_day_reservations')),
      isFalse,
    );
  });

  testWidgets('…but a match-cancelled block with LIVE rows still warns and '
      'sweeps them', (tester) async {
    reservationsBody =
        '[{"date":"${thursday.toSql()}","lane":1,"block_id":"b2"}]';
    await tester.pumpWidget(app(BlockDialog(
      existing: null,
      blocks: const [b1, b2],
      initialStart: const HourMinute(17, 0),
      initialEnd: const HourMinute(18, 0),
      dayContext: thursday,
      dayBaseIds: const ['b1', 'b2'],
      dayRenderedIds: const {'b1'},
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();

    expect(find.text('Blok bude skryt'), findsOneWidget);
    await tester.tap(find.text('Pokračovat'));
    await tester.pumpAndSettle();
    expect(
      requests.any(
          (r) => r.url.path.contains('cancel_block_day_reservations')),
      isTrue,
    );
  });

  group('„Zavřít den“ (0050)', () {
    BlockDialog fromPlus({bool offer = true, TimeBlock? existing}) =>
        BlockDialog(
          existing: existing,
          blocks: const [b1, b2],
          dayContext: thursday,
          dayBaseIds: const ['b1', 'b2'],
          offerCloseDay: offer,
        );

    testWidgets('offered only on a new block from the header ＋', (
      tester,
    ) async {
      await tester.pumpWidget(app(fromPlus()));
      await tester.pumpAndSettle();
      expect(find.text('Zavřít den'), findsOneWidget);

      await tester.pumpWidget(app(fromPlus(offer: false)));
      await tester.pumpAndSettle();
      expect(find.text('Zavřít den'), findsNothing);

      await tester.pumpWidget(app(fromPlus(existing: b1)));
      await tester.pumpAndSettle();
      expect(find.text('Zavřít den'), findsNothing);
    });

    testWidgets('asks the reason, confirms the count, closes the day with '
        'the reason', (tester) async {
      reservationsBody =
          '[{"date":"${thursday.toSql()}","lane":1,"block_id":"b1"},'
          '{"date":"${thursday.toSql()}","lane":2,"block_id":"b2"}]';
      await tester.pumpWidget(app(fromPlus()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Zavřít den'));
      await tester.pumpAndSettle();
      expect(find.text('Důvod zavření'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'oprava drah');
      await tester.tap(find.widgetWithText(FilledButton, 'Zavřít den'));
      await tester.pumpAndSettle();

      expect(find.text('Pozor — rezervace budou zrušeny'), findsOneWidget);
      expect(find.textContaining('2 rezervací'), findsOneWidget);
      expect(find.textContaining('„oprava drah"'), findsOneWidget);
      await tester.tap(find.text('Pokračovat'));
      await tester.pumpAndSettle();

      final rpc = requests.singleWhere(
        (r) => r.method == 'POST' && r.url.path.contains('set_day_override'),
      );
      final body = jsonDecode(rpc.body) as Map<String, dynamic>;
      expect(body['p_date'], thursday.toSql());
      expect(body['p_closed'], true);
      expect(body['p_reason'], 'oprava drah');
      expect(find.byType(BlockDialog), findsNothing);
    });

    testWidgets('backing out of the count confirm writes nothing', (
      tester,
    ) async {
      reservationsBody =
          '[{"date":"${thursday.toSql()}","lane":1,"block_id":"b1"}]';
      await tester.pumpWidget(app(fromPlus()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Zavřít den'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Zavřít den'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Zrušit').last);
      await tester.pumpAndSettle();

      expect(
        requests.any((r) => r.url.path.contains('set_day_override')),
        isFalse,
      );
      expect(find.byType(BlockDialog), findsOneWidget);
    });
  });

  testWidgets('a duty that ended meanwhile is told so, and the dialog stays',
      (tester) async {
    refuseOverride = true;
    await tester.pumpWidget(app(BlockDialog(
      existing: null,
      blocks: const [b1, b2],
      dayContext: thursday,
      dayBaseIds: const ['b1', 'b2'],
      offerCloseDay: true,
      wasOnDuty: true,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Zavřít den'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Zavřít den'));
    await tester.pumpAndSettle();

    expect(
      find.text('Služba skončila — tohle teď může jen správce.'),
      findsOneWidget,
    );
    expect(find.byType(BlockDialog), findsOneWidget);
  });

  testWidgets('„Napsat hráčům bloku…“ shows only when editing an existing '
      'block, and calls back', (tester) async {
    var messaged = false;
    await tester.pumpWidget(app(BlockDialog(
      existing: b1,
      blocks: const [b1, b2],
      dayContext: thursday,
      dayBaseIds: const ['b1', 'b2'],
      offerMessageBlock: true,
      onMessagePlayers: () => messaged = true,
    )));
    await tester.pumpAndSettle();
    expect(find.text('Napsat hráčům bloku…'), findsOneWidget);
    await tester.tap(find.text('Napsat hráčům bloku…'));
    expect(messaged, true);
  });

  // Changed times are not saved by „Napsat hráčům bloku…“: messaging
  // „come at 15:00“ over a block still at 16:00 would mislead the players.
  testWidgets('„Napsat hráčům bloku…“ is off while the times are changed '
      'and unsaved', (tester) async {
    var messaged = false;
    await tester.pumpWidget(app(BlockDialog(
      existing: b1,
      blocks: const [b1, b2],
      dayContext: thursday,
      dayBaseIds: const ['b1', 'b2'],
      initialStart: const HourMinute(15, 0),
      offerMessageBlock: true,
      onMessagePlayers: () => messaged = true,
    )));
    await tester.pumpAndSettle();
    final tile = find.widgetWithText(ListTile, 'Napsat hráčům bloku…');
    expect(tester.widget<ListTile>(tile).enabled, isFalse);
    await tester.tap(tile, warnIfMissed: false);
    expect(messaged, isFalse);
    expect(find.byType(BlockDialog), findsOneWidget);
  });

  testWidgets('a NEW block from the header ＋ never offers „Napsat hráčům '
      'bloku…“', (tester) async {
    await tester.pumpWidget(app(BlockDialog(
      existing: null,
      blocks: const [b1, b2],
      dayContext: thursday,
      dayBaseIds: const ['b1', 'b2'],
      offerMessageBlock: true,
      onMessagePlayers: () {},
    )));
    await tester.pumpAndSettle();
    expect(find.text('Napsat hráčům bloku…'), findsNothing);
  });

  // „Napsat hráčům bloku…“ must not grow the pinned action bar: AlertDialog
  // scrolls only the title and content, so every extra action squeezes the
  // times (landscape) or pushes „Uložit“ off-screen (large text).
  group('„Napsat hráčům bloku…“ keeps the dialog usable on a small screen', () {
    Future<void> openDialog(WidgetTester tester, Size size, double scale,
        BlockDialog dialog) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showDialog<void>(context: context, builder: (_) => dialog),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    for (final size in const [Size(800, 360), Size(800, 400)]) {
      final label = '${size.width.toInt()}×${size.height.toInt()}';
      testWidgets('both times stay on screen at $label', (tester) async {
        var messaged = false;
        await openDialog(
          tester,
          size,
          1.0,
          BlockDialog(
            existing: b1,
            blocks: const [b1, b2],
            dayContext: thursday,
            dayBaseIds: const ['b1', 'b2'],
            offerMessageBlock: true,
            onMessagePlayers: () => messaged = true,
          ),
        );
        expect(find.text('Začátek').hitTestable(), findsOneWidget);
        expect(find.text('Konec').hitTestable(), findsOneWidget);
        // The message entry is still reachable (it scrolls with the times).
        await tester.ensureVisible(find.text('Napsat hráčům bloku…'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Napsat hráčům bloku…'));
        await tester.pumpAndSettle();
        expect(messaged, true);
        expect(find.byType(BlockDialog), findsNothing);
      });
    }

    testWidgets('„Uložit“ stays reachable at 640×360, text ×2.0, on a day '
        'with an override', (tester) async {
      await openDialog(
        tester,
        const Size(640, 360),
        2.0,
        BlockDialog(
          existing: b2,
          blocks: const [b1, b2],
          initialStart: const HourMinute(17, 30),
          initialEnd: const HourMinute(18, 30),
          dayContext: thursday,
          dayBaseIds: const ['b1', 'b2'],
          dayHasOverride: true,
          offerMessageBlock: true,
          onMessagePlayers: () {},
        ),
      );
      expect(find.text('Obnovit týdenní rozvrh'), findsOneWidget);
      expect(find.text('Uložit').hitTestable(), findsOneWidget);
      await tester.tap(find.text('Uložit'));
      await tester.pumpAndSettle();
      expect(
        requests.any((r) => r.url.path.endsWith('/rpc/set_day_override')),
        true,
      );
      expect(find.byType(BlockDialog), findsNothing);
    });
  });

  // The player on duty editing TODAY (0050): the calendar passes its
  // clock; b1 (16:00) has started by 16:30, b2 (17:00) has not.
  group('the duty on today: blocks already under way (0050)', () {
    const now = HourMinute(16, 30);
    String rows(List<String> blockIds) => '[${[
          for (var i = 0; i < blockIds.length; i++)
            '{"date":"${thursday.toSql()}","lane":${i + 1},'
                '"block_id":"${blockIds[i]}"}',
        ].join(',')}]';

    testWidgets('a start already past is refused before any request', (
      tester,
    ) async {
      for (final (existing, start) in [
        (b2, const HourMinute(16, 15)),
        (b2, now), // starting exactly now has started
        (null, const HourMinute(16, 0)),
      ]) {
        requests.clear();
        await tester.pumpWidget(app(BlockDialog(
          key: UniqueKey(),
          existing: existing,
          blocks: const [b1, b2],
          initialStart: start,
          initialEnd: const HourMinute(18, 30),
          dayContext: thursday,
          dayBaseIds: const ['b1', 'b2'],
          wasOnDuty: true,
          dutyClock: () => now,
        )));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Uložit'));
        await tester.pumpAndSettle();

        expect(
          find.text('Blok nemůže začínat dřív než teď (16:30) — '
              'vyber pozdější začátek.'),
          findsOneWidget,
        );
        expect(requests, isEmpty);
        expect(find.byType(BlockDialog), findsOneWidget);
        ScaffoldMessenger.of(tester.element(find.byType(BlockDialog)))
            .removeCurrentSnackBar();
        await tester.pumpAndSettle();
      }
    });

    testWidgets('„Zavřít den“ counts only what the server cancels; the '
        'admin counts every row', (tester) async {
      reservationsBody = rows(['b1', 'b2']);
      for (final (dutyClock, count) in [(() => now, 1), (null, 2)]) {
        await tester.pumpWidget(app(BlockDialog(
          key: UniqueKey(),
          existing: null,
          blocks: const [b1, b2],
          dayContext: thursday,
          dayBaseIds: const ['b1', 'b2'],
          offerCloseDay: true,
          dutyClock: dutyClock,
        )));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Zavřít den'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Zavřít den'));
        await tester.pumpAndSettle();
        expect(find.textContaining('$count rezervací'), findsOneWidget);
        await tester.tap(find.text('Zrušit').last);
        await tester.pumpAndSettle();
      }
    });

    testWidgets('„Důvod zavření“ tells the duty on today that trainings '
        'under way stay; the admin reads the plain line', (tester) async {
      final withClause = '${dayFull(thursday)} — rezervace v tento den se '
          'zruší (tréninky, které už začaly, zůstanou).';
      final plain = '${dayFull(thursday)} — rezervace v tento den se zruší.';
      for (final (dutyClock, message) in [
        (() => now, withClause),
        // b1 (16:00) starts within the minute: it counts as under way.
        (() => const HourMinute(15, 59), withClause),
        // Before any block of the day has started nothing stays.
        (() => const HourMinute(15, 0), plain),
        (null, plain),
      ]) {
        await tester.pumpWidget(app(BlockDialog(
          key: UniqueKey(),
          existing: null,
          blocks: const [b1, b2],
          dayContext: thursday,
          dayBaseIds: const ['b1', 'b2'],
          offerCloseDay: true,
          dutyClock: dutyClock,
        )));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Zavřít den'));
        await tester.pumpAndSettle();
        expect(find.text(message), findsOneWidget);
        await tester.tap(find.text('Zrušit').last);
        await tester.pumpAndSettle();
      }
    });

    testWidgets('„Zavřít den“ a minute before a block: the count leaves it '
        'out, as the clause says it stays', (tester) async {
      // b1 (16:00) starts one minute after the duty clock: by the write it
      // is under way, so the count and the clause must agree on that.
      reservationsBody = rows(['b1', 'b2']);
      await tester.pumpWidget(app(BlockDialog(
        existing: null,
        blocks: const [b1, b2],
        dayContext: thursday,
        dayBaseIds: const ['b1', 'b2'],
        offerCloseDay: true,
        dutyClock: () => const HourMinute(15, 59),
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Zavřít den'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('(tréninky, které už začaly, zůstanou)'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Zavřít den'));
      await tester.pumpAndSettle();
      expect(find.textContaining('1 rezervací'), findsOneWidget);
      expect(find.textContaining('2 rezervací'), findsNothing);
    });

    testWidgets('„Obnovit týdenní rozvrh“ of a closing day counts only what '
        'the server cancels', (tester) async {
      reservationsBody = rows(['b1', 'b2']);
      await tester.pumpWidget(app(BlockDialog(
        existing: b2,
        blocks: const [b1, b2],
        dayContext: thursday,
        dayBaseIds: const ['b1', 'b2'],
        dayHasOverride: true,
        dayIsTraining: false,
        dutyClock: () => now,
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Obnovit týdenní rozvrh'));
      await tester.pumpAndSettle();
      expect(find.textContaining('1 rezervací'), findsOneWidget);
      // The day closes: the count says why b1's training is left out.
      expect(
        find.textContaining('(tréninky, které už začaly, zůstanou)'),
        findsOneWidget,
      );
    });

    testWidgets('„Obnovit týdenní rozvrh“ of a closing day before any block '
        'has started counts every row, plainly', (tester) async {
      reservationsBody = rows(['b1', 'b2']);
      await tester.pumpWidget(app(BlockDialog(
        existing: b2,
        blocks: const [b1, b2],
        dayContext: thursday,
        dayBaseIds: const ['b1', 'b2'],
        dayHasOverride: true,
        dayIsTraining: false,
        dutyClock: () => const HourMinute(15, 0),
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Obnovit týdenní rozvrh'));
      await tester.pumpAndSettle();
      expect(find.textContaining('2 rezervací'), findsOneWidget);
      expect(find.textContaining('zůstanou'), findsNothing);
    });

    // A day-only special that replaced b2 today (0050: specials sit at a
    // negative position, inactive).
    const sp = TimeBlock(
      id: 'sp',
      startsAt: HourMinute(18, 0),
      endsAt: HourMinute(19, 0),
      position: -1,
      active: false,
    );
    BlockDialog restoring(HourMinute Function() clock) => BlockDialog(
          key: UniqueKey(),
          existing: sp,
          blocks: const [b1, b2, sp],
          dayContext: thursday,
          dayBaseIds: const ['b1', 'sp'],
          dayRenderedIds: const {'b1', 'sp'},
          dayHasOverride: true,
          wasOnDuty: true,
          dutyClock: clock,
        );

    testWidgets('„Obnovit týdenní rozvrh“ that would drop a special under '
        'way is refused before any request', (tester) async {
      await tester.pumpWidget(app(restoring(() => const HourMinute(18, 10))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Obnovit týdenní rozvrh'));
      await tester.pumpAndSettle();

      expect(find.text(blockStartedMessage), findsOneWidget);
      expect(requests, isEmpty);
      expect(find.byType(BlockDialog), findsOneWidget);
    });

    testWidgets('„Obnovit týdenní rozvrh“ with the special still ahead '
        'restores', (tester) async {
      await tester.pumpWidget(app(restoring(() => now)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Obnovit týdenní rozvrh'));
      await tester.pumpAndSettle();

      expect(find.text(blockStartedMessage), findsNothing);
      final restored = requests.singleWhere(
          (r) => r.url.path.endsWith('/rpc/set_day_override'));
      expect((jsonDecode(restored.body) as Map)['p_block_ids'], ['b1', 'b2']);
    });

    testWidgets('hiding a block under way is refused before any request — '
        'it stays the admin\'s', (tester) async {
      reservationsBody = rows(['b1', 'b2']);
      await tester.pumpWidget(app(BlockDialog(
        existing: null,
        blocks: const [b1, b2],
        initialStart: const HourMinute(16, 45),
        initialEnd: const HourMinute(17, 45),
        dayContext: thursday,
        dayBaseIds: const ['b1', 'b2'],
        wasOnDuty: true,
        dutyClock: () => now,
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Uložit'));
      await tester.pumpAndSettle();

      // The refusal names the hidden block, not the one being edited.
      expect(find.text(hideStartedMessage), findsOneWidget);
      expect(find.text(blockStartedMessage), findsNothing);
      expect(find.text('Blok bude skryt'), findsNothing);
      expect(requests, isEmpty);
      expect(find.byType(BlockDialog), findsOneWidget);
    });

    testWidgets('hiding only a block still ahead sweeps it', (tester) async {
      reservationsBody = rows(['b1', 'b2']);
      await tester.pumpWidget(app(BlockDialog(
        existing: null,
        blocks: const [b1, b2],
        initialStart: const HourMinute(17, 15),
        initialEnd: const HourMinute(17, 45),
        dayContext: thursday,
        dayBaseIds: const ['b1', 'b2'],
        dutyClock: () => now,
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Uložit'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('1 rezervací na skrytých blocích bude zrušeno'),
        findsOneWidget,
      );
      await tester.tap(find.text('Pokračovat'));
      await tester.pumpAndSettle();
      final swept = [
        for (final r in requests)
          if (r.url.path.endsWith('/rpc/cancel_block_day_reservations'))
            (jsonDecode(r.body) as Map)['p_block'],
      ];
      expect(swept, ['b2']);
    });

    testWidgets('„Odebrat v tento den“ offers no move onto a block under way',
        (tester) async {
      reservationsBody = rows(['b2']);
      await tester.pumpWidget(app(BlockDialog(
        existing: b2,
        blocks: const [b1, b2],
        dayContext: thursday,
        dayBaseIds: const ['b1', 'b2'],
        dutyClock: () => now,
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Odebrat v tento den'));
      await tester.pumpAndSettle();

      // b1, the only block left, has started: straight to the count.
      expect(find.textContaining('Přesun rezervací'), findsNothing);
      expect(find.textContaining('1 rezervací'), findsOneWidget);
    });

    testWidgets('a too_late refusal of a day edit reads as the block, not a '
        'reservation', (tester) async {
      refuseMoveTooLate = true;
      await tester.pumpWidget(app(BlockDialog(
        existing: b2,
        blocks: const [b1, b2],
        initialStart: const HourMinute(17, 30),
        initialEnd: const HourMinute(18, 30),
        dayContext: thursday,
        dayBaseIds: const ['b1', 'b2'],
        wasOnDuty: true,
        dutyClock: () => now,
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Uložit'));
      await tester.pumpAndSettle();

      expect(find.text(blockStartedMessage), findsOneWidget);
      expect(find.byType(BlockDialog), findsOneWidget);
    });

    // The clock moves while the dialog is open: it is read again right
    // before the first write, and a block that started meanwhile — or a
    // start that has passed — writes nothing.
    group('the clock moves on while the dialog is open', () {
      late HourMinute clock;
      bool wrote() => requests.any((r) => r.method != 'GET');

      testWidgets('the edited block starts before the move is confirmed', (
        tester,
      ) async {
        clock = const HourMinute(16, 58);
        reservationsBody = rows(['b2']);
        await tester.pumpWidget(app(BlockDialog(
          existing: b2,
          blocks: const [b1, b2],
          initialStart: const HourMinute(17, 30),
          initialEnd: const HourMinute(18, 30),
          dayContext: thursday,
          dayBaseIds: const ['b1', 'b2'],
          wasOnDuty: true,
          dutyClock: () => clock,
        )));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Uložit'));
        await tester.pumpAndSettle();
        expect(find.text('Upozornit na přesun?'), findsOneWidget);

        clock = const HourMinute(17, 1);
        await tester.tap(find.text('Odeslat'));
        await tester.pumpAndSettle();

        // The edited block itself: the plain block copy.
        expect(find.text(blockStartedMessage), findsOneWidget);
        expect(find.text(hideStartedMessage), findsNothing);
        expect(wrote(), isFalse);
        expect(find.byType(BlockDialog), findsOneWidget);
      });

      testWidgets('the new start passes before the hide is confirmed', (
        tester,
      ) async {
        clock = const HourMinute(16, 58);
        reservationsBody = rows(['b2']);
        await tester.pumpWidget(app(BlockDialog(
          existing: null,
          blocks: const [b1, b2],
          initialStart: const HourMinute(17, 15),
          initialEnd: const HourMinute(17, 45),
          dayContext: thursday,
          dayBaseIds: const ['b1', 'b2'],
          wasOnDuty: true,
          dutyClock: () => clock,
        )));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Uložit'));
        await tester.pumpAndSettle();
        expect(find.text('Blok bude skryt'), findsOneWidget);

        clock = const HourMinute(17, 20);
        await tester.tap(find.text('Pokračovat'));
        await tester.pumpAndSettle();

        expect(
          find.text('Blok nemůže začínat dřív než teď (17:20) — '
              'vyber pozdější začátek.'),
          findsOneWidget,
        );
        expect(wrote(), isFalse);
      });

      testWidgets('a hidden block starts before the hide is confirmed', (
        tester,
      ) async {
        clock = const HourMinute(16, 58);
        reservationsBody = rows(['b2']);
        await tester.pumpWidget(app(BlockDialog(
          existing: null,
          blocks: const [b1, b2],
          initialStart: const HourMinute(17, 30),
          initialEnd: const HourMinute(18, 30),
          dayContext: thursday,
          dayBaseIds: const ['b1', 'b2'],
          wasOnDuty: true,
          dutyClock: () => clock,
        )));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Uložit'));
        await tester.pumpAndSettle();
        expect(find.text('Blok bude skryt'), findsOneWidget);

        clock = const HourMinute(17, 1);
        await tester.tap(find.text('Pokračovat'));
        await tester.pumpAndSettle();

        expect(find.text(hideStartedMessage), findsOneWidget);
        expect(find.text(blockStartedMessage), findsNothing);
        expect(wrote(), isFalse);
      });

      testWidgets('„Odebrat v tento den“: the block starts before the count '
          'is confirmed', (tester) async {
        clock = now;
        reservationsBody = rows(['b2']);
        await tester.pumpWidget(app(BlockDialog(
          existing: b2,
          blocks: const [b1, b2],
          dayContext: thursday,
          dayBaseIds: const ['b1', 'b2'],
          wasOnDuty: true,
          dutyClock: () => clock,
        )));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Odebrat v tento den'));
        await tester.pumpAndSettle();
        expect(find.textContaining('1 rezervací'), findsOneWidget);

        clock = const HourMinute(17, 0);
        await tester.tap(find.text('Pokračovat'));
        await tester.pumpAndSettle();

        expect(find.text(blockStartedMessage), findsOneWidget);
        expect(wrote(), isFalse);
      });

      testWidgets('„Obnovit týdenní rozvrh“: the special starts before the '
          'count is confirmed', (tester) async {
        clock = const HourMinute(17, 58);
        reservationsBody = rows(['sp']);
        await tester.pumpWidget(app(restoring(() => clock)));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Obnovit týdenní rozvrh'));
        await tester.pumpAndSettle();
        expect(find.textContaining('1 rezervací'), findsOneWidget);

        // sp (18:00) starts within the minute: under way at write time.
        clock = const HourMinute(17, 59);
        await tester.tap(find.text('Pokračovat'));
        await tester.pumpAndSettle();

        expect(find.text(blockStartedMessage), findsOneWidget);
        expect(wrote(), isFalse);
      });

      // The clock left alone: b2 is still ahead, the count confirm asks.
      // Moved on: both blocks under way, the server cancels nothing — no
      // count, the day closes straight away. Either way it closes.
      for (final (later, confirm) in [
        (now, '1 rezervací'),
        (const HourMinute(17, 0), null),
      ]) {
        testWidgets('„Zavřít den“ counts at the time it asks, not when the '
            'dialog opened (clock at $later)', (tester) async {
          clock = now;
          reservationsBody = rows(['b1', 'b2']);
          await tester.pumpWidget(app(BlockDialog(
            existing: null,
            blocks: const [b1, b2],
            dayContext: thursday,
            dayBaseIds: const ['b1', 'b2'],
            offerCloseDay: true,
            dutyClock: () => clock,
          )));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Zavřít den'));
          await tester.pumpAndSettle();

          clock = later;
          await tester.tap(find.widgetWithText(FilledButton, 'Zavřít den'));
          await tester.pumpAndSettle();
          if (confirm != null) {
            expect(find.textContaining(confirm), findsOneWidget);
            await tester.tap(find.text('Pokračovat'));
            await tester.pumpAndSettle();
          } else {
            expect(find.textContaining('rezervací'), findsNothing);
          }

          final closed = requests.singleWhere(
              (r) => r.url.path.endsWith('/rpc/set_day_override'));
          expect((jsonDecode(closed.body) as Map)['p_closed'], isTrue);
        });
      }

      // Right before a write a block starting within the next minute counts
      // as started: the minute clock may lag by seconds, and the server's
      // too_late would land only after the first writes.
      group('the write-time margin of one minute', () {
        testWidgets('the edited block starting in 30 s writes nothing', (
          tester,
        ) async {
          clock = const HourMinute(16, 58);
          reservationsBody = rows(['b2']);
          await tester.pumpWidget(app(BlockDialog(
            existing: b2,
            blocks: const [b1, b2],
            initialStart: const HourMinute(17, 30),
            initialEnd: const HourMinute(18, 30),
            dayContext: thursday,
            dayBaseIds: const ['b1', 'b2'],
            wasOnDuty: true,
            dutyClock: () => clock,
          )));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Uložit'));
          await tester.pumpAndSettle();

          clock = const HourMinute(16, 59); // b2 starts at 17:00
          await tester.tap(find.text('Odeslat'));
          await tester.pumpAndSettle();

          expect(find.text(blockStartedMessage), findsOneWidget);
          expect(wrote(), isFalse);
        });

        testWidgets('a new start in 30 s has passed', (tester) async {
          clock = const HourMinute(16, 58);
          reservationsBody = rows(['b2']);
          await tester.pumpWidget(app(BlockDialog(
            existing: null,
            blocks: const [b1, b2],
            initialStart: const HourMinute(17, 15),
            initialEnd: const HourMinute(17, 45),
            dayContext: thursday,
            dayBaseIds: const ['b1', 'b2'],
            wasOnDuty: true,
            dutyClock: () => clock,
          )));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Uložit'));
          await tester.pumpAndSettle();

          clock = const HourMinute(17, 14);
          await tester.tap(find.text('Pokračovat'));
          await tester.pumpAndSettle();

          expect(
            find.text('Blok nemůže začínat dřív než teď (17:14) — '
                'vyber pozdější začátek.'),
            findsOneWidget,
          );
          expect(wrote(), isFalse);
        });

        testWidgets('„Odebrat v tento den“ of a block starting in 30 s '
            'writes nothing', (tester) async {
          clock = now;
          reservationsBody = rows(['b2']);
          await tester.pumpWidget(app(BlockDialog(
            existing: b2,
            blocks: const [b1, b2],
            dayContext: thursday,
            dayBaseIds: const ['b1', 'b2'],
            wasOnDuty: true,
            dutyClock: () => clock,
          )));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Odebrat v tento den'));
          await tester.pumpAndSettle();

          clock = const HourMinute(16, 59);
          await tester.tap(find.text('Pokračovat'));
          await tester.pumpAndSettle();

          expect(find.text(blockStartedMessage), findsOneWidget);
          expect(wrote(), isFalse);
        });
      });
    });
  });
}

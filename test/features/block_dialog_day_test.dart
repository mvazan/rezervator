import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/admin/widgets/block_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Pins the DAY-SCOPED BlockDialog save path at the HTTP layer: editing a
/// block from the calendar must NOT touch the weekly template — it inserts
/// an inactive "special" block and points the day's override at it.
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

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final mock = MockClient((request) async {
      requests.add(request);
      String body = '{}';
      if (request.method == 'GET' && request.url.path.contains('reservations')) {
        body = '[]';
      } else if (request.method == 'POST' &&
          request.url.path.contains('time_blocks')) {
        body = '{"id":"sb1"}';
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
        localStorage: EmptyLocalStorage(),
      ),
    );
  });

  setUp(() => requests = []);

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

    // 1) The special block insert: inactive, with the picked times.
    final insert = requests.firstWhere(
      (r) => r.method == 'POST' && r.url.path.contains('time_blocks'),
    );
    final insertBody = jsonDecode(insert.body) as Map<String, dynamic>;
    expect(insertBody['active'], false);
    expect(insertBody['position'], -1);
    expect(insertBody['starts_at'], '17:30:00');
    expect(insertBody['ends_at'], '18:30:00');

    // 2) The override RPC: b2 replaced by the special block, b1 kept.
    final rpc = requests.firstWhere(
      (r) => r.method == 'POST' && r.url.path.contains('set_day_override'),
    );
    final rpcBody = jsonDecode(rpc.body) as Map<String, dynamic>;
    expect(rpcBody['p_date'], thursday.toSql());
    expect(rpcBody['p_closed'], false);
    expect(rpcBody['p_block_ids'], ['b1', 'sb1']);

    // 3) No PATCH ever hits the weekly time_blocks row.
    expect(
      requests.any(
          (r) => r.method == 'PATCH' && r.url.path.contains('time_blocks')),
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
      requests.any(
          (r) => r.method == 'POST' && r.url.path.contains('time_blocks')),
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
    expect(
      requests.any((r) =>
          r.method == 'DELETE' && r.url.path.contains('day_overrides')),
      isTrue,
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
      requests.any((r) =>
          r.method == 'DELETE' && r.url.path.contains('day_overrides')),
      isTrue,
    );
    // 3) No new special was inserted.
    expect(
      requests.any(
          (r) => r.method == 'POST' && r.url.path.contains('time_blocks')),
      isFalse,
    );
  });
}

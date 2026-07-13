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
      dayContext: thursday,
      dayBaseIds: const ['b1', 'b2'],
      dayRenderedBlocks: const [b1, b2],
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
    expect(insertBody['starts_at'], '17:00:00');
    expect(insertBody['ends_at'], '18:00:00');

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
      'an existing inactive special with the same times is REUSED — no new '
      'insert', (tester) async {
    const special = TimeBlock(
      id: 'sb-existing',
      startsAt: HourMinute(17, 0),
      endsAt: HourMinute(18, 0),
      position: 7,
      active: false,
    );
    await tester.pumpWidget(app(BlockDialog(
      existing: b2,
      blocks: const [b1, b2, special],
      dayContext: thursday,
      dayBaseIds: const ['b1', 'b2'],
      dayRenderedBlocks: const [b1, b2],
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
    expect((jsonDecode(rpc.body) as Map)['p_block_ids'], ['b1', 'sb-existing']);
  });

  testWidgets('Odebrat v tento den drops only this block from the override', (
    tester,
  ) async {
    await tester.pumpWidget(app(BlockDialog(
      existing: b2,
      blocks: const [b1, b2],
      dayContext: thursday,
      dayBaseIds: const ['b1', 'b2'],
      dayRenderedBlocks: const [b1, b2],
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
}

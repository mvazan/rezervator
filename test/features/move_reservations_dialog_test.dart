import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rezervator/core/ui.dart' show dayFull;
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/admin/widgets/move_reservations_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Pins the drag&drop move flow: dragging a reservation from the removed
/// block onto a free lane of a resurfacing block stages it; committing
/// calls the move_reservation RPC and resolves true.
void main() {
  const settings = ScheduleSettings(
    laneCount: 2,
    trainingWeekdays: {1, 2, 3, 4, 5, 6, 7},
    bookingHorizonDays: 14,
    maxActiveReservations: 3,
  );
  const removed = TimeBlock(
    id: 'sp1',
    startsAt: HourMinute(17, 30),
    endsAt: HourMinute(18, 30),
    position: -1,
    active: false,
  );
  const target = TimeBlock(
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
      return http.Response('{}', 200,
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

  Reservation res(String id, String playerId, int lane, String blockId) =>
      Reservation(
        id: id,
        playerId: playerId,
        date: thursday,
        blockId: blockId,
        lane: lane,
        createdVia: 'app',
        createdAt: DateTime.utc(2026, 1, 1),
      );

  testWidgets('drag stages a move; commit fires move_reservation and pops '
      'true; occupied lanes refuse the drop', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    bool? result;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        settingsProvider.overrideWith((ref) => Stream.value(settings)),
        weekReservationsProvider.overrideWith(
          (ref, monday) => Stream.value([
            res('r1', 'p1', 1, removed.id),
            // Lane 1 of the target is already taken.
            res('r9', 'p9', 1, target.id),
          ]),
        ),
        playersProvider.overrideWith(
          (ref) async => const [
            PlayerName(id: 'p1', displayName: 'Petr Novák', club: '', nick: 'Péťa'),
            PlayerName(id: 'p9', displayName: 'Olga Malá', club: ''),
          ],
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  result = await showDialog<bool>(
                    context: context,
                    builder: (_) => MoveReservationsDialog(
                      date: thursday,
                      fromBlock: removed,
                      targets: const [target],
                      cancelNote: 'změna rozvrhu',
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Occupied lane shows its occupant; free lane invites.
    expect(find.text('Dráha 1 — Olga Malá'), findsOneWidget);
    expect(find.text('Dráha 2 — volná'), findsOneWidget);

    // A drop onto the OCCUPIED lane 1 is refused — nothing stages.
    final chip = find.text('Péťa · D1');
    await tester.drag(
      chip,
      tester.getCenter(find.text('Dráha 1 — Olga Malá')) -
          tester.getCenter(chip),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('(přesun)'), findsNothing);
    expect(find.text('Vše přesunuto.'), findsNothing);

    // Drag Péťa's chip onto the free lane 2.
    final freeLane = find.text('Dráha 2 — volná');
    await tester.drag(
      chip,
      tester.getCenter(freeLane) - tester.getCenter(chip),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Péťa (přesun)'), findsOneWidget);
    expect(find.text('Vše přesunuto.'), findsOneWidget);

    await tester.tap(find.text('Pokračovat'));
    await tester.pumpAndSettle();

    final rpc = requests.firstWhere(
      (r) => r.method == 'POST' && r.url.path.contains('move_reservation'),
    );
    final body = jsonDecode(rpc.body) as Map<String, dynamic>;
    expect(body['p_reservation'], 'r1');
    expect(body['p_to_block'], 'b2');
    expect(body['p_lane'], 2);
    expect(result, isTrue);
  });

  testWidgets('committing with unmoved reservations confirms the '
      'cancellation first', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        settingsProvider.overrideWith((ref) => Stream.value(settings)),
        weekReservationsProvider.overrideWith(
          (ref, monday) =>
              Stream.value([res('r1', 'p1', 1, removed.id)]),
        ),
        playersProvider.overrideWith(
          (ref) async => const [
            PlayerName(id: 'p1', displayName: 'Petr Novák', club: ''),
          ],
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: MoveReservationsDialog(
            date: thursday,
            fromBlock: removed,
            targets: const [target],
            cancelNote: 'změna rozvrhu',
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Nepřesunuté rezervace budou zrušeny.'), findsOneWidget);
    await tester.tap(find.text('Pokračovat'));
    await tester.pumpAndSettle();
    expect(find.text('Nepřesunuté rezervace'), findsOneWidget);
    expect(find.textContaining('změna rozvrhu'), findsOneWidget);

    // Declining keeps the dialog open and fires NO RPC.
    await tester.tap(find.text('Zrušit').last);
    await tester.pumpAndSettle();
    expect(find.text('Přesun rezervací — '
            '${dayFull(thursday)}'), findsOneWidget);
    expect(
      requests.any((r) => r.url.path.contains('move_reservation')),
      isFalse,
    );
  });
}

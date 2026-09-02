import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rezervator/core/ui.dart' show dayFull, today;
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/admin/widgets/rental_occurrence_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Pins the "jen tento den" dialog at the HTTP layer: what an exception row
/// carries when saved, skipped or removed, and which inputs are refused.
void main() {
  final thursday = Day(2026, 7, 16);

  final parent = Rental(
    id: 'n1',
    renterName: 'Firma X',
    lanes: const [1, 2],
    date: null,
    weekday: DateTime.thursday,
    startsAt: const HourMinute(18, 0),
    endsAt: const HourMinute(20, 0),
    validFrom: null,
    validUntil: null,
    note: '',
    color: 3,
  );
  final child = Rental(
    id: 'c1',
    renterName: 'Firma X',
    lanes: const [1],
    date: thursday,
    weekday: null,
    startsAt: const HourMinute(18, 0),
    endsAt: const HourMinute(20, 0),
    validFrom: null,
    validUntil: null,
    note: '',
    color: 3,
    parentId: 'n1',
  );

  late List<http.Request> requests;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final mock = MockClient((request) async {
      requests.add(request);
      // postgrest reads response.request — MockClient doesn't attach it
      // unless we do.
      return http.Response('{}', 200,
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

  setUp(() => requests = []);

  /// The dialog is pushed with showDialog (as the app does) so popping it
  /// is observable.
  Future<void> open(WidgetTester tester, RentalOccurrenceDialog dialog) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () =>
                  showDialog<bool>(context: context, builder: (_) => dialog),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Výjimka pronájmu'), findsOneWidget);
  }

  http.Request patchOf(String id) => requests.firstWhere((r) =>
      r.method == 'PATCH' &&
      r.url.path.contains('rentals') &&
      r.url.queryParameters['id'] == 'eq.$id');

  testWidgets('values equal to the series are refused — no request', (
    tester,
  ) async {
    await open(tester,
        RentalOccurrenceDialog(parent: parent, date: thursday, laneCount: 3));
    expect(find.textContaining('jen ${dayFull(thursday)}'), findsOneWidget);

    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();

    expect(find.text('Shoduje se s pravidelným pronájmem.'), findsOneWidget);
    expect(requests, isEmpty);
    expect(find.text('Výjimka pronájmu'), findsOneWidget);
  });

  testWidgets('no lanes is refused', (tester) async {
    await open(tester,
        RentalOccurrenceDialog(parent: parent, date: thursday, laneCount: 3));
    // Chips rebuild between taps — a second tap before a pump would toggle
    // against the stale selection.
    await tester.tap(find.text('Dráha 1'));
    await tester.pump();
    await tester.tap(find.text('Dráha 2'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();

    expect(find.text('Vyber aspoň jednu dráhu.'), findsOneWidget);
    expect(requests, isEmpty);
  });

  testWidgets('editing an exception PATCHes the full effective row; a '
      'change inside the series does not mention cancellations', (
    tester,
  ) async {
    await open(
        tester,
        RentalOccurrenceDialog(
            parent: parent, date: thursday, existing: child, laneCount: 3));
    // c1 blocks lane 1 only; move the exception to lane 2.
    await tester.tap(find.text('Dráha 1'));
    await tester.pump();
    await tester.tap(find.text('Dráha 2'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();

    final body = jsonDecode(patchOf('c1').body) as Map<String, dynamic>;
    expect(body['parent_id'], 'n1');
    expect(body['date'], '2026-07-16');
    expect(body['skipped'], false);
    expect(body['lanes'], [2]);
    expect(body['starts_at'], '18:00:00');
    expect(body['ends_at'], '20:00:00');
    expect(body['renter_name'], 'Firma X');
    expect(body['color'], 3);
    expect(body['weekday'], isNull);
    expect(find.text('Výjimka uložena.'), findsOneWidget);
    expect(find.text('Výjimka pronájmu'), findsNothing);
  });

  testWidgets('a lane outside the series says colliding reservations were '
      'cancelled', (tester) async {
    await open(
        tester,
        RentalOccurrenceDialog(
            parent: parent, date: thursday, existing: child, laneCount: 3));
    await tester.tap(find.text('Dráha 3'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();

    final body = jsonDecode(patchOf('c1').body) as Map<String, dynamic>;
    expect(body['lanes'], [1, 3]);
    expect(find.text('Výjimka uložena. Kolidující rezervace byly zrušeny.'),
        findsOneWidget);
  });

  testWidgets("Vynechat tento den saves skipped with the series' lanes and "
      'times', (tester) async {
    await open(
        tester,
        RentalOccurrenceDialog(
            parent: parent, date: thursday, existing: child, laneCount: 3));
    await tester.tap(find.text('Vynechat tento den'));
    await tester.pumpAndSettle();

    final body = jsonDecode(patchOf('c1').body) as Map<String, dynamic>;
    expect(body['skipped'], true);
    expect(body['lanes'], [1, 2]);
    expect(body['ends_at'], '20:00:00');
    expect(find.text('Pronájem v tento den vynechán.'), findsOneWidget);
    expect(find.text('Výjimka pronájmu'), findsNothing);
  });

  testWidgets('Zrušit výjimku warns about meanwhile bookings, then DELETEs',
      (tester) async {
    await open(
        tester,
        RentalOccurrenceDialog(
            parent: parent, date: thursday, existing: child, laneCount: 3));
    await tester.tap(find.text('Zrušit výjimku'));
    await tester.pumpAndSettle();

    expect(find.textContaining('budou zrušeny'), findsOneWidget);
    await tester.tap(find.text('Ano'));
    await tester.pumpAndSettle();

    final del = requests.firstWhere((r) =>
        r.method == 'DELETE' && r.url.path.contains('rentals'));
    expect(del.url.queryParameters['id'], 'eq.c1');
    expect(find.text('Výjimka zrušena.'), findsOneWidget);
    expect(find.text('Výjimka pronájmu'), findsNothing);
  });

  testWidgets('a new exception without a known date is refused until one is '
      'picked', (tester) async {
    await open(tester, RentalOccurrenceDialog(parent: parent, laneCount: 3));
    expect(find.text('Zrušit výjimku'), findsNothing);
    // Lanes differ from the series, so only the date is missing.
    await tester.tap(find.text('Dráha 2'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();

    expect(find.text('Vyber datum.'), findsOneWidget);
    expect(requests, isEmpty);
  });

  testWidgets('the date dropdown lists the upcoming series dates minus the '
      'taken ones', (tester) async {
    final t = today();
    final series = Rental(
      id: 'n2',
      renterName: 'Firma Y',
      lanes: const [1],
      date: null,
      weekday: t.weekday,
      startsAt: const HourMinute(18, 0),
      endsAt: const HourMinute(20, 0),
      validFrom: null,
      validUntil: t.addDays(20),
      note: '',
    );
    await open(
        tester,
        RentalOccurrenceDialog(
            parent: series, laneCount: 3, takenDates: {t.addDays(7)}));
    expect(find.text('Datum'), findsOneWidget);

    await tester.tap(find.text('Datum'));
    await tester.pumpAndSettle();

    expect(find.text(dayFull(t)), findsOneWidget);
    expect(find.text(dayFull(t.addDays(14))), findsOneWidget);
    expect(find.text(dayFull(t.addDays(7))), findsNothing);
    expect(find.text(dayFull(t.addDays(21))), findsNothing);
  });
}

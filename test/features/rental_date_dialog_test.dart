import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/admin/widgets/rental_date_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Pins the date dialog at the HTTP layer: a new date goes through the RPC,
/// an edit is a plain row update carrying the group's name, and the form
/// refuses what the server would.
void main() {
  final anchor = Rental(
    id: 'r1',
    renterName: 'Firma Trak',
    lanes: const [1, 2],
    date: Day(2026, 10, 15),
    weekday: null,
    startsAt: const HourMinute(18, 0),
    endsAt: const HourMinute(20, 0),
    validFrom: null,
    validUntil: null,
    note: '',
    color: 3,
    groupId: 'g1',
  );
  final existing = Rental(
    id: 'r2',
    renterName: 'Firma Trak',
    lanes: const [2],
    date: Day(2026, 10, 22),
    weekday: null,
    startsAt: const HourMinute(19, 0),
    endsAt: const HourMinute(21, 0),
    validFrom: null,
    validUntil: null,
    note: 'bez rozbrusu',
    color: 3,
    groupId: 'g1',
  );

  late List<http.Request> requests;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final mock = MockClient((request) async {
      requests.add(request);
      final body = request.url.path.endsWith('/rpc/rental_add_date')
          ? '"new-id"'
          : '{}';
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

  setUp(() => requests = []);

  Future<void> open(WidgetTester tester, RentalDateDialog dialog) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: const [Locale('cs')],
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
  }

  Map<String, dynamic> bodyOf(http.Request r) =>
      jsonDecode(r.body) as Map<String, dynamic>;

  testWidgets('a new date pre-fills lanes and times from the anchor and is '
      'added through rental_add_date', (tester) async {
    await open(tester, RentalDateDialog(anchor: anchor, laneCount: 3));
    expect(find.text('Přidat termín'), findsOneWidget);
    expect(find.text('Vybrat'), findsOneWidget, reason: 'the date is not guessed');
    expect(find.text('18:00'), findsOneWidget);
    expect(find.text('20:00'), findsOneWidget);

    // Pick the 20th of the anchor's month in the calendar.
    await tester.tap(find.text('Vybrat'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('20'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();

    final rpc = requests.singleWhere(
        (r) => r.url.path.endsWith('/rpc/rental_add_date'));
    expect(rpc.method, 'POST');
    final body = bodyOf(rpc);
    expect(body['p_rental'], 'r1');
    expect(body['p_date'], '2026-10-20');
    expect(body['p_starts_at'], '18:00:00');
    expect(body['p_ends_at'], '20:00:00');
    expect(body['p_lanes'], [1, 2]);
    expect(body['p_note'], '');
    expect(find.text('Přidat termín'), findsNothing, reason: 'popped');
  });

  testWidgets('editing a date updates its row and carries the group name',
      (tester) async {
    await open(tester,
        RentalDateDialog(anchor: anchor, existing: existing, laneCount: 3));
    expect(find.text('Upravit termín'), findsOneWidget);
    expect(find.text('bez rozbrusu'), findsOneWidget);

    await tester.tap(find.text('Dráha 3'));
    await tester.pump();
    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();

    final patch = requests.singleWhere((r) => r.method == 'PATCH');
    expect(patch.url.path, '/rest/v1/rentals');
    expect(patch.url.queryParameters['id'], 'eq.r2');
    final body = bodyOf(patch);
    expect(body['renter_name'], 'Firma Trak');
    expect(body['color'], 3);
    expect(body['date'], '2026-10-22');
    expect(body['lanes'], [2, 3]);
    expect(body['note'], 'bez rozbrusu');
    expect(body.containsKey('group_id'), isFalse,
        reason: 'the row keeps its group; the update must not touch it');
  });

  testWidgets('refuses a missing date and an empty lane set', (tester) async {
    await open(tester, RentalDateDialog(anchor: anchor, laneCount: 3));
    await tester.tap(find.text('Uložit'));
    await tester.pump();
    expect(find.text('Vyber datum.'), findsOneWidget);
    expect(requests, isEmpty);
  });
}

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/rental_groups.dart';
import 'package:rezervator/features/admin/widgets/rental_group_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  Rental row({String? group}) => Rental(
        id: 'r1',
        renterName: 'Firma Trak',
        lanes: const [1, 2],
        date: Day(2026, 10, 15),
        weekday: null,
        startsAt: const HourMinute(18, 0),
        endsAt: const HourMinute(20, 0),
        validFrom: null,
        validUntil: null,
        note: 'faktura',
        color: 3,
        groupId: group,
      );

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
        detectSessionInUri: false,
        localStorage: EmptyLocalStorage(),
      ),
    );
  });

  setUp(() => requests = []);

  Future<void> open(WidgetTester tester, RentalGroup group) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showDialog<bool>(
                  context: context,
                  builder: (_) => RentalGroupDialog(group: group)),
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

  testWidgets('a grouped rental updates rental_groups', (tester) async {
    await open(tester, RentalGroup(
        id: 'g1', renterName: 'Firma Trak', color: 3, dates: [row(group: 'g1')]));
    expect(find.text('Upravit pronájem'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Nájemce'), 'Firma Trak s.r.o.');
    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();
    final patch = requests.singleWhere((r) => r.method == 'PATCH');
    expect(patch.url.path, '/rest/v1/rental_groups');
    expect(patch.url.queryParameters['id'], 'eq.g1');
    expect(bodyOf(patch), {'renter_name': 'Firma Trak s.r.o.', 'color': 3});
  });

  testWidgets('a lone rental updates its own row, keeping date, lanes and '
      'note', (tester) async {
    await open(tester,
        RentalGroup(id: null, renterName: 'Firma Trak', color: 3, dates: [row()]));
    await tester.enterText(find.widgetWithText(TextField, 'Nájemce'), 'Nové jméno');
    await tester.tap(find.text('Uložit'));
    await tester.pumpAndSettle();
    final patch = requests.singleWhere((r) => r.method == 'PATCH');
    expect(patch.url.path, '/rest/v1/rentals');
    expect(patch.url.queryParameters['id'], 'eq.r1');
    final body = bodyOf(patch);
    expect(body['renter_name'], 'Nové jméno');
    expect(body['date'], '2026-10-15');
    expect(body['lanes'], [1, 2]);
    expect(body['note'], 'faktura');
    expect(body['color'], 3);
  });

  testWidgets('refuses an empty name', (tester) async {
    await open(tester, RentalGroup(
        id: 'g1', renterName: 'Firma Trak', color: 3, dates: [row(group: 'g1')]));
    await tester.enterText(find.widgetWithText(TextField, 'Nájemce'), '  ');
    await tester.tap(find.text('Uložit'));
    await tester.pump();
    expect(find.text('Vyplň nájemce.'), findsOneWidget);
    expect(requests, isEmpty);
  });
}

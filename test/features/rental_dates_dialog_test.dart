import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rezervator/core/ui.dart' show dayFull, today;
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/rental_groups.dart';
import 'package:rezervator/features/admin/widgets/rental_dates_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  final next = today().addDays(10);
  final later = today().addDays(20);
  final past = today().addDays(-5);
  Rental date({
    required String id,
    required Day day,
    List<int> lanes = const [1, 2],
    String note = '',
  }) =>
      Rental(
        id: id,
        renterName: 'Firma Trak',
        lanes: lanes,
        date: day,
        weekday: null,
        startsAt: const HourMinute(18, 0),
        endsAt: const HourMinute(20, 0),
        validFrom: null,
        validUntil: null,
        note: note,
        color: 3,
        groupId: 'g1',
      );
  final rows = [
    date(id: 'd-past', day: past, lanes: const [1]),
    date(id: 'd-next', day: next, note: 'bez rozbrusu'),
    date(id: 'd-later', day: later, lanes: const [2]),
  ];

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

  Future<void> open(WidgetTester tester, List<Rental> rentals) async {
    final group = rentalGroupsOf(rentals, today: today()).single;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        rentalsProvider.overrideWith((ref) => Stream.value(rentals)),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) =>
                      RentalDatesDialog(group: group, laneCount: 3),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  // Same dialog, but on a stream that can emit again — production re-emits
  // after every delete.
  Future<void> openLive(
    WidgetTester tester,
    List<Rental> rentals,
    Stream<List<Rental>> stream,
  ) async {
    final group = rentalGroupsOf(rentals, today: today()).single;
    await tester.pumpWidget(ProviderScope(
      overrides: [rentalsProvider.overrideWith((ref) => stream)],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => RentalDatesDialog(group: group, laneCount: 3),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('lists the dates chronologically with lanes, times and note; '
      'a past date is shown but inert', (tester) async {
    await open(tester, rows);
    expect(find.text('Termíny · Firma Trak'), findsOneWidget);
    expect(find.text(dayFull(past)), findsOneWidget);
    expect(find.text(dayFull(next)), findsOneWidget);
    expect(find.text(dayFull(later)), findsOneWidget);
    expect(find.text('18:00–20:00 · dráhy 1, 2 · bez rozbrusu'), findsOneWidget);
    expect(find.text('18:00–20:00 · dráhy 2'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text(dayFull(past))).dy,
      lessThan(tester.getTopLeft(find.text(dayFull(next))).dy),
    );
    final pastTile = tester.widget<ListTile>(find.ancestor(
        of: find.text(dayFull(past)), matching: find.byType(ListTile)));
    expect(pastTile.enabled, isFalse);
    expect(find.text('Přidat termín'), findsOneWidget);
    expect(find.text('Zavřít'), findsOneWidget);
  });

  testWidgets('Přidat termín opens the date dialog anchored on the last date',
      (tester) async {
    await open(tester, rows);
    await tester.tap(find.text('Přidat termín'));
    await tester.pumpAndSettle();
    // Title of the inner dialog plus the list's button: two.
    expect(find.text('Přidat termín'), findsNWidgets(2));
    // The last date (d-later) is the anchor: lane 2 only, pre-selected.
    final chip2 = tester.widget<FilterChip>(find.ancestor(
        of: find.text('Dráha 2'), matching: find.byType(FilterChip)));
    final chip1 = tester.widget<FilterChip>(find.ancestor(
        of: find.text('Dráha 1'), matching: find.byType(FilterChip)));
    expect(chip2.selected, isTrue);
    expect(chip1.selected, isFalse);
  });

  testWidgets('tapping a date opens it for editing', (tester) async {
    await open(tester, rows);
    await tester.tap(find.text(dayFull(next)));
    await tester.pumpAndSettle();
    expect(find.text('Upravit termín'), findsOneWidget);
    expect(find.text('bez rozbrusu'), findsOneWidget);
  });

  testWidgets('deleting a date confirms and deletes just that row',
      (tester) async {
    await open(tester, rows);
    final deleteButtons = find.byTooltip('Smazat termín');
    expect(deleteButtons, findsNWidgets(2), reason: 'not on the past date');
    await tester.tap(deleteButtons.first);
    await tester.pumpAndSettle();
    expect(find.text('Smazat termín?'), findsOneWidget);
    expect(find.textContaining(dayFull(next)), findsWidgets);
    await tester.tap(find.text('Ano'));
    await tester.pumpAndSettle();
    final del = requests.singleWhere((r) => r.method == 'DELETE');
    expect(del.url.path, '/rest/v1/rentals');
    expect(del.url.queryParameters['id'], 'eq.d-next');
  });

  testWidgets('deleting the EARLIEST date really removes it from the list',
      (tester) async {
    // Every date ahead, so the first row is deletable too — the group is
    // re-found on the stream, and it must survive losing that very row.
    final ahead = [
      date(id: 'd-next', day: next, note: 'bez rozbrusu'),
      date(id: 'd-later', day: later, lanes: const [2]),
    ];
    final live = StreamController<List<Rental>>();
    addTearDown(live.close);
    await openLive(tester, ahead, live.stream);
    live.add(ahead);
    await tester.pumpAndSettle();
    expect(find.text(dayFull(next)), findsOneWidget);

    await tester.tap(find.byTooltip('Smazat termín').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ano'));
    await tester.pumpAndSettle();
    final del = requests.singleWhere((r) => r.method == 'DELETE');
    expect(del.url.queryParameters['id'], 'eq.d-next');

    live.add([ahead.last]);
    await tester.pumpAndSettle();
    expect(find.text(dayFull(next)), findsNothing,
        reason: 'the deleted date must not come back on the stale snapshot');
    expect(find.text(dayFull(later)), findsOneWidget);
    expect(find.text('Termíny · Firma Trak'), findsOneWidget);
  });
}

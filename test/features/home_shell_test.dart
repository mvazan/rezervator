import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/schedule/home_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  late List<http.Request> requests;

  // The visiting banner's "Zpět domů" calls Api.switchTenant, which needs a
  // live Supabase client — stub its HTTP so the RPC can be asserted.
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final mock = MockClient((request) async {
      requests.add(request);
      return http.Response('{}', 200,
          headers: {'content-type': 'application/json'});
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

  // HomeShell embeds WeekScreen, which reads the schedule_view preference on
  // its first frame — a mock handler is required or pumpAndSettle hangs.
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    requests = [];
  });

  const settings = ScheduleSettings(
    laneCount: 1,
    trainingWeekdays: {1, 2, 3, 4, 5, 6, 7},
    bookingHorizonDays: 14,
    maxActiveReservations: 3,
  );

  const me = Profile(
    id: 'me',
    displayName: 'Já Hráč',
    club: '',
    email: 'me@example.com',
    role: Role.player,
    status: ProfileStatus.approved,
  );

  /// Superadmin switched into someone else's kuželna (0015).
  const visiting = Profile(
    id: 'me',
    displayName: 'Miloš',
    club: '',
    email: 'milos.vazan@gmail.com',
    role: Role.admin,
    status: ProfileStatus.approved,
    superadmin: true,
    tenantId: 't-demo',
    homeTenantId: 't-home',
  );

  Widget app({Profile profile = me}) => ProviderScope(
    overrides: [
      settingsProvider.overrideWith((ref) => Stream.value(settings)),
      timeBlocksProvider.overrideWith((ref) => Stream.value(const [])),
      dayOverridesProvider.overrideWith((ref) => Stream.value(const [])),
      prioritySlotsProvider.overrideWithValue(const []),
      rentalsProvider.overrideWith((ref) => Stream.value(const [])),
      weekReservationsProvider.overrideWith(
        (ref, monday) => StreamController<List<Reservation>>().stream,
      ),
      myActiveReservationsProvider.overrideWith(
        (ref) => Stream.value(const []),
      ),
      myProfileProvider.overrideWith((ref) => Stream.value(profile)),
      playersProvider.overrideWith((ref) async => const []),
      tenantNameProvider.overrideWith((ref, id) async => 'Demo'),
    ],
    child: const MaterialApp(home: HomeShell()),
  );

  testWidgets('AppBar has no logout icon; profile icon is the entry point', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    // Logout now lives on the profile screen, not the AppBar.
    expect(find.byIcon(Icons.logout), findsNothing);
    expect(find.byIcon(Icons.account_circle_outlined), findsOneWidget);
  });

  testWidgets('a regular member sees no visiting banner', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.byType(MaterialBanner), findsNothing);
  });

  testWidgets('a visiting superadmin gets a named banner whose "Zpět domů" '
      'switches back to the home kuželna', (tester) async {
    await tester.pumpWidget(app(profile: visiting));
    await tester.pumpAndSettle();

    expect(find.text('Prohlížíš kuželnu Demo'), findsOneWidget);
    expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);

    await tester.tap(find.text('Zpět domů'));
    await tester.pumpAndSettle();

    final rpc = requests.firstWhere(
      (r) => r.method == 'POST' && r.url.path.contains('switch_tenant'),
    );
    expect(jsonDecode(rpc.body), {'p_tenant_id': 't-home'});
  });
}

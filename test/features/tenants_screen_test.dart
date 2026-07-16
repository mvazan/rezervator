import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/admin/admin_screen.dart';
import 'package:rezervator/features/admin/tenants_screen.dart';
import 'package:rezervator/features/auth/waiting_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Superadmin tenants hub (0014): hub tile visibility, the approval flow's
/// RPC (pinned via a stubbed HTTP client) and the tenant waiting screen.
void main() {
  const admin = Profile(
    id: 'a1',
    displayName: 'Správce',
    club: '',
    email: 'admin@example.com',
    role: Role.admin,
    status: ProfileStatus.approved,
    tenantId: 't-home',
  );

  const superadmin = Profile(
    id: 's1',
    displayName: 'Miloš',
    club: '',
    email: 'milos.vazan@gmail.com',
    role: Role.admin,
    status: ProfileStatus.approved,
    tenantId: 't-home',
    homeTenantId: 't-home',
    superadmin: true,
  );

  /// The same superadmin, switched into someone else's kuželna (0015).
  const visitingSuperadmin = Profile(
    id: 's1',
    displayName: 'Miloš',
    club: '',
    email: 'milos.vazan@gmail.com',
    role: Role.admin,
    status: ProfileStatus.approved,
    tenantId: 't-demo',
    homeTenantId: 't-home',
    superadmin: true,
  );

  const pendingTenant = AdminTenant(
    id: 't-new',
    name: 'Nová kuželna',
    status: 'pending',
    founderEmail: 'zakladatel@example.com',
    memberCount: 1,
  );

  const homeTenant = AdminTenant(
    id: 't-home',
    name: 'Veveří',
    status: 'approved',
    founderEmail: 'milos.vazan@gmail.com',
    memberCount: 12,
  );

  late List<http.Request> requests;

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

  setUp(() => requests = []);

  /// The hub is a lazy ListView — its superadmin section sits below the 8
  /// regular tiles, so a default 600px-tall surface never mounts it.
  void tallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Widget hub(Profile me) => ProviderScope(
        overrides: [
          myProfileProvider.overrideWith((ref) => Stream.value(me)),
          tenantNameProvider.overrideWith((ref, id) async => 'TJ Sokol Brno IV'),
        ],
        child: const MaterialApp(home: AdminScreen()),
      );

  Widget tenantsScreen(Profile me) => ProviderScope(
        overrides: [
          myProfileProvider.overrideWith((ref) => Stream.value(me)),
          adminTenantsProvider
              .overrideWith((ref) async => const [pendingTenant, homeTenant]),
        ],
        child: const MaterialApp(home: TenantsScreen()),
      );

  testWidgets('the superadmin sees the Kuželny hub tile in its own '
      '"Správce aplikace" section', (tester) async {
    tallSurface(tester);
    await tester.pumpWidget(hub(superadmin));
    await tester.pumpAndSettle();
    expect(find.text('Kuželny'), findsOneWidget);
    expect(find.text('Správce aplikace'), findsOneWidget);
    expect(find.text('schvalování a přepínání kuželen'), findsOneWidget);
  });

  testWidgets('a regular admin gets no Kuželny hub tile', (tester) async {
    tallSurface(tester);
    await tester.pumpWidget(hub(admin));
    await tester.pumpAndSettle();
    expect(find.text('Kuželny'), findsNothing);
    expect(find.text('Hráči'), findsOneWidget); // regular hub still renders
  });

  testWidgets('at home there is no "back home" tile', (tester) async {
    tallSurface(tester);
    await tester.pumpWidget(hub(superadmin));
    await tester.pumpAndSettle();
    expect(find.text('Zpět domů'), findsNothing);
  });

  testWidgets('while visiting, a second tile names the home kuželna and '
      'switches back to it', (tester) async {
    tallSurface(tester);
    await tester.pumpWidget(hub(visitingSuperadmin));
    await tester.pumpAndSettle();

    // Both tiles live in the superadmin section. The home kuželna is named
    // as an apposition ('do kuželny X'), never declined into the preposition.
    expect(find.text('Kuželny'), findsOneWidget);
    expect(find.text('Zpět domů'), findsOneWidget);
    expect(find.text('do kuželny TJ Sokol Brno IV'), findsOneWidget);

    await tester.tap(find.text('Zpět domů'));
    await tester.pumpAndSettle();

    final rpc = requests.firstWhere(
      (r) => r.method == 'POST' && r.url.path.contains('switch_tenant'),
    );
    expect(jsonDecode(rpc.body), {'p_tenant_id': 't-home'});
  });

  testWidgets('pending kuželna offers approve/reject; approving fires the '
      'approve_tenant RPC', (tester) async {
    await tester.pumpWidget(tenantsScreen(superadmin));
    await tester.pumpAndSettle();

    expect(find.text('Čekají na schválení'), findsOneWidget);
    expect(find.text('Nová kuželna'), findsOneWidget);
    expect(find.textContaining('zakladatel@example.com'), findsOneWidget);
    // The superadmin's current kuželna is marked and not switchable.
    expect(find.text('aktuální'), findsOneWidget);
    expect(find.text('Přepnout se'), findsNothing);

    await tester.tap(find.text('Schválit'));
    await tester.pumpAndSettle();

    final rpc = requests.firstWhere(
      (r) => r.method == 'POST' && r.url.path.contains('approve_tenant'),
    );
    expect(jsonDecode(rpc.body), {'p_tenant_id': 't-new'});
  });

  testWidgets('switching into another kuželna fires switch_tenant',
      (tester) async {
    const other = AdminTenant(
      id: 't-other',
      name: 'Jiná kuželna',
      status: 'approved',
      memberCount: 3,
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        myProfileProvider.overrideWith((ref) => Stream.value(superadmin)),
        adminTenantsProvider
            .overrideWith((ref) async => const [homeTenant, other]),
      ],
      child: const MaterialApp(home: TenantsScreen()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Přepnout se'));
    await tester.pumpAndSettle();

    final rpc = requests.firstWhere(
      (r) => r.method == 'POST' && r.url.path.contains('switch_tenant'),
    );
    expect(jsonDecode(rpc.body), {'p_tenant_id': 't-other'});
  });

  testWidgets('regular admin opening TenantsScreen is refused',
      (tester) async {
    await tester.pumpWidget(tenantsScreen(admin));
    await tester.pumpAndSettle();
    expect(find.text('Jen pro správce aplikace.'), findsOneWidget);
  });

  testWidgets('the tenant-approval waiting screen explains itself',
      (tester) async {
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(
        home: WaitingScreen(reason: WaitingReason.tenantApproval),
      ),
    ));
    await tester.pump();
    expect(find.text('Kuželna čeká na schválení'), findsOneWidget);
    expect(find.textContaining('správce aplikace'), findsOneWidget);
    // Tear the periodic recheck timer down before the test ends.
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

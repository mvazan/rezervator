import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/schedule/home_shell.dart';
import 'package:rezervator/features/schedule/my_trainings_screen.dart';
import 'package:rezervator/features/schedule/week_screen.dart';
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
        detectSessionInUri: false,
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

  // Pinned (as in week_screen_test.dart / my_trainings_screen_test.dart) so
  // the week header's range text is deterministic instead of depending on
  // whatever day the suite happens to run on.
  final now = DateTime(2026, 9, 9, 10, 0); // středa dopoledne
  final today = Day.fromDateTime(now);

  const me = Profile(
    id: 'me',
    displayName: 'Já Hráč',
    email: 'me@example.com',
    role: Role.player,
    status: ProfileStatus.approved,
  );

  /// Superadmin switched into someone else's kuželna (0015).
  const visiting = Profile(
    id: 'me',
    displayName: 'Miloš',
    email: 'milos.vazan@gmail.com',
    role: Role.admin,
    status: ProfileStatus.approved,
    superadmin: true,
    tenantId: 't-demo',
    homeTenantId: 't-home',
  );

  Widget app({Profile profile = me, Stream<Profile>? profileStream}) =>
      ProviderScope(
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
          myProfileProvider.overrideWith(
            (ref) => profileStream ?? Stream.value(profile),
          ),
          playersProvider.overrideWith((ref) async => const []),
          tenantNameProvider.overrideWith((ref, id) async => 'Demo'),
          nowProvider.overrideWith((ref) => Stream.value(now)),
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

  const listFirst = Profile(
    id: 'me',
    displayName: 'Já Hráč',
    email: 'me@example.com',
    role: Role.player,
    status: ProfileStatus.approved,
    defaultView: HomeView.trainings,
  );

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  void wide(WidgetTester tester) {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// A phone turned sideways: plenty of width, a short height — the
  /// breakpoint must key off the width, not the shorter side, or this looks
  /// exactly like `phone()` and gets the same cramped bottom tabs.
  void phoneLandscape(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// The narrowest landscape phone that still gets the rail: the strip left
  /// for the header is ~80dp narrower than the screen, which is exactly the
  /// band where measuring the screen instead of the strip overflowed.
  void narrowLandscape(WidgetTester tester) {
    tester.view.physicalSize = const Size(640, 360);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// Wide enough for the rail, far too short for it (the two destinations
  /// need ~150dp): a browser window squashed down to a strip. Unreachable
  /// while the breakpoint keyed off the shorter side — the rail then implied
  /// a height of 600 too — so the rail has to survive it on its own now.
  void shortStrip(WidgetTester tester) {
    tester.view.physicalSize = const Size(700, 130);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  group('two views', () {
    testWidgets('opens on the profile\'s launch view: calendar by default',
        (tester) async {
      phone(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.byType(WeekScreen), findsOneWidget);
      expect(find.byType(MyTrainingsScreen), findsNothing);
    });

    testWidgets('…and on the list when the profile says so', (tester) async {
      phone(tester);
      await tester.pumpWidget(app(profile: listFirst));
      await tester.pumpAndSettle();
      expect(find.byType(MyTrainingsScreen), findsOneWidget);
      expect(find.byType(WeekScreen), findsNothing);
    });

    testWidgets('the launch view is read once; a later profile change does '
        'not move the app, a tap does', (tester) async {
      phone(tester);
      final profiles = StreamController<Profile>();
      await tester.pumpWidget(app(profileStream: profiles.stream));
      profiles.add(me); // calendar-first
      await tester.pumpAndSettle();
      expect(find.byType(WeekScreen), findsOneWidget);

      // The profile now says list-first (changed in Můj profil meanwhile);
      // the running app stays where it is.
      profiles.add(listFirst);
      await tester.pumpAndSettle();
      expect(find.byType(WeekScreen), findsOneWidget);

      await tester.tap(find.text('Můj přehled'));
      await tester.pumpAndSettle();
      expect(find.byType(MyTrainingsScreen), findsOneWidget);
      await profiles.close();
    });

    testWidgets('a phone gets bottom tabs, a wide screen a rail', (tester) async {
      phone(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
    });

    testWidgets('…rail on a wide screen, and it switches too', (tester) async {
      wide(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);

      await tester.tap(find.text('Můj přehled'));
      await tester.pumpAndSettle();
      expect(find.byType(MyTrainingsScreen), findsOneWidget);
    });

    testWidgets('…and a phone turned sideways also gets the rail, not a '
        'bottom bar stretched thin', (tester) async {
      phoneLandscape(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
    });

    testWidgets('a narrow landscape phone fits the header beside the rail',
        (tester) async {
      narrowLandscape(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(tester.takeException(), isNull,
          reason: 'the header measures the strip it got, not the screen');
    });

    testWidgets('the rail survives a window too short to hold it', (tester) async {
      shortStrip(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(tester.takeException(), isNull,
          reason: 'the rail scrolls instead of overflowing');
    });

    testWidgets('the banners stay above the view on the list too', (tester) async {
      phone(tester);
      await tester.pumpWidget(app(profile: visiting));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Můj přehled'));
      await tester.pumpAndSettle();
      expect(find.text('Prohlížíš kuželnu Demo'), findsOneWidget);
      expect(find.byType(MyTrainingsScreen), findsOneWidget);
    });

    testWidgets(
        'switching tabs keeps the calendar\'s paged week (both views stay '
        'mounted in an IndexedStack)', (tester) async {
      phone(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      final monday = today.addDays(1 - today.weekday);
      expect(find.text(rangeLabel(monday, monday.addDays(6))), findsOneWidget);

      // Page the calendar one week ahead.
      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();
      final paged = monday.addDays(7);
      expect(find.text(rangeLabel(paged, paged.addDays(6))), findsOneWidget);

      // A glance at Můj přehled and back must not reset it.
      await tester.tap(find.text('Můj přehled'));
      await tester.pumpAndSettle();
      expect(find.byType(MyTrainingsScreen), findsOneWidget);

      await tester.tap(find.text('Kalendář'));
      await tester.pumpAndSettle();
      expect(find.byType(WeekScreen), findsOneWidget);
      expect(find.text(rangeLabel(paged, paged.addDays(6))), findsOneWidget);
    });

    testWidgets(
        'a back gesture away from Můj přehled returns to the calendar '
        'instead of popping the route', (tester) async {
      phone(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Můj přehled'));
      await tester.pumpAndSettle();
      expect(find.byType(MyTrainingsScreen), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      // Back switched the view instead of popping the (only) route away.
      expect(find.byType(HomeShell), findsOneWidget);
      expect(find.byType(WeekScreen), findsOneWidget);
      expect(find.byType(MyTrainingsScreen), findsNothing);
    });
  });
}

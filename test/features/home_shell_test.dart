import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rezervator/data/clock.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/groups.dart';
import 'package:rezervator/domain/duties.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/clubhouse/message_detail_screen.dart';
import 'package:rezervator/features/admin/players_screen.dart';
import 'package:rezervator/features/admin/tenants_screen.dart';
import 'package:rezervator/features/clubhouse/notice_board_screen.dart';
import 'package:rezervator/features/schedule/calendar_focus.dart';
import 'package:rezervator/features/schedule/home_shell.dart';
import 'package:rezervator/features/schedule/my_trainings_screen.dart';
import 'package:rezervator/features/schedule/week_screen.dart';
import 'package:rezervator/push/pending_link.dart';
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

  Reservation res(String id, Day date) => Reservation(
        id: id,
        playerId: me.id,
        date: date,
        blockId: 'b1',
        lane: 1,
        createdVia: 'app',
        createdAt: DateTime.utc(2026, 1, 1),
      );

  Widget app({
    Profile profile = me,
    Stream<Profile>? profileStream,
    List<Reservation> mine = const [],
    MyDuty duty = MyDuty.none,
    MyGroup group = MyGroup.none,
    List<Message> messages = const [],
    List<MessageRecipient> messageRecipients = const [],
    PendingLink? pendingLink,
    // A factory, not a stream: Riverpod retries a failed provider and
    // would listen to a single-subscription stream twice.
    Stream<List<Message>> Function()? messagesStream,
    Future<bool> Function(String id)? messageExists,
  }) =>
      ProviderScope(
        overrides: [
          // A link already pending when HomeShell mounts — what a cold
          // start (getInitialMessage) or a /zpravy/:id route leaves behind.
          if (pendingLink != null)
            pendingLinkProvider.overrideWith(
              () => PendingLinkNotifier(initial: pendingLink),
            ),
          // The detail screen's tile reads the other participants' rows.
          messageParticipantsProvider.overrideWith(
            (ref, id) => Stream.value(const []),
          ),
          // The Klubovna dot (unreadCountsProvider) reads these.
          messagesProvider.overrideWith(
            (ref) => messagesStream?.call() ?? Stream.value(messages),
          ),
          myMessageRecipientsProvider.overrideWith(
            (ref) => Stream.value(messageRecipients),
          ),
          settingsProvider.overrideWith((ref) => Stream.value(settings)),
          timeBlocksProvider.overrideWith((ref) => Stream.value(const [])),
          dayOverridesProvider.overrideWith((ref) => Stream.value(const [])),
          prioritySlotsProvider.overrideWithValue(const []),
          rentalsProvider.overrideWith((ref) => Stream.value(const [])),
          weekReservationsProvider.overrideWith(
            (ref, monday) => StreamController<List<Reservation>>().stream,
          ),
          myActiveReservationsProvider.overrideWith((ref) => Stream.value(mine)),
          myProfileProvider.overrideWith(
            (ref) => profileStream ?? Stream.value(profile),
          ),
          playersProvider.overrideWith((ref) async => const []),
          // The approval screens a deep link can open.
          profilesProvider.overrideWith((ref) => Stream.value(const [])),
          clubsProvider.overrideWith((ref) => Stream.value(const [])),
          groupRowsProvider.overrideWith((ref) => Stream.value(const [])),
          tenantsProvider.overrideWith((ref) async => const []),
          tenantNameProvider.overrideWith((ref, id) async => 'Demo'),
          nowProvider.overrideWith((ref) => Stream.value(now)),
          myGroupProvider.overrideWithValue(group),
          myDutyProvider.overrideWithValue(duty),
          dutyPeriodsProvider.overrideWith((ref) => Stream.value(const [])),
          dutyAssignmentsProvider.overrideWith(
            (ref) => Stream.value(const []),
          ),
        ],
        child: MaterialApp(
          home: messageExists == null
              ? const HomeShell()
              : HomeShell(messageExists: messageExists),
        ),
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

  // At the cap both views stop offering ＋ — without a word, that reads as a
  // broken screen. The banner is the word. settings.maxActiveReservations
  // is 3 in this suite.
  testWidgets('the reservation cap is announced, and only at the cap',
      (tester) async {
    await tester.pumpWidget(app(mine: [
      res('r1', today),
      res('r2', today.addDays(1)),
      res('r3', today.addDays(2)),
    ]));
    await tester.pumpAndSettle();
    expect(
      find.text('Máš maximální počet rezervací (3). Další půjde, až jedna '
          'proběhne nebo ji zrušíš.'),
      findsOneWidget,
    );

  });

  // On canteen duty (0050) the ＋ stays — the duty books for the others —
  // so the banner says that instead of "wait until one is over".
  testWidgets('on duty the cap banner says the ＋ is for the others',
      (tester) async {
    await tester.pumpWidget(app(
      mine: [
        res('r1', today),
        res('r2', today.addDays(1)),
        res('r3', today.addDays(2)),
      ],
      duty: MyDuty(
        current: DutyPeriod(id: 'd1', startsOn: today, endsOn: today),
      ),
    ));
    await tester.pumpAndSettle();
    expect(
      find.text('Máš maximální počet rezervací — jako služba můžeš rezervovat '
          'jen pro ostatní.'),
      findsOneWidget,
    );
    expect(find.textContaining('Další půjde'), findsNothing);
  });

  // A group member (0044) at their own cap keeps the ＋ — they may still
  // book for their mates — so "wait until one is over" would be false.
  const myGroup = MyGroup(groupId: 'g1', memberIds: ['me', 'p2']);

  testWidgets('in a group the cap banner says the ＋ is for the mates',
      (tester) async {
    await tester.pumpWidget(app(
      mine: [
        res('r1', today),
        res('r2', today.addDays(1)),
        res('r3', today.addDays(2)),
      ],
      group: myGroup,
    ));
    await tester.pumpAndSettle();
    expect(
      find.text('Máš maximální počet rezervací — ve skupině můžeš rezervovat '
          'jen pro spoluhráče.'),
      findsOneWidget,
    );
    expect(find.textContaining('Další půjde'), findsNothing);
  });

  // The duty books for anyone, the group only for the mates — the wider
  // promise wins.
  testWidgets('on duty in a group the duty banner wins', (tester) async {
    await tester.pumpWidget(app(
      mine: [
        res('r1', today),
        res('r2', today.addDays(1)),
        res('r3', today.addDays(2)),
      ],
      duty: MyDuty(
        current: DutyPeriod(id: 'd1', startsOn: today, endsOn: today),
      ),
      group: myGroup,
    ));
    await tester.pumpAndSettle();
    expect(
      find.text('Máš maximální počet rezervací — jako služba můžeš rezervovat '
          'jen pro ostatní.'),
      findsOneWidget,
    );
    expect(find.textContaining('spoluhráče'), findsNothing);
  });

  // A group whose other members have all left has nobody to book for.
  testWidgets('a group without mates keeps the plain cap banner',
      (tester) async {
    await tester.pumpWidget(app(
      mine: [
        res('r1', today),
        res('r2', today.addDays(1)),
        res('r3', today.addDays(2)),
      ],
      group: const MyGroup(groupId: 'g1', memberIds: ['me']),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('Další půjde'), findsOneWidget);
    expect(find.textContaining('spoluhráče'), findsNothing);
  });

  // The cap does not bind an admin: create_reservation lets them book past
  // it, so the banner's promise ("another one once this is over") would be
  // a lie. They get the booking dialog's warning instead.
  testWidgets('…and never to an admin, whom the cap does not stop',
      (tester) async {
    const boss = Profile(
      id: 'me',
      displayName: 'Správce',
      email: 'admin@example.com',
      role: Role.admin,
      status: ProfileStatus.approved,
    );
    await tester.pumpWidget(app(
      profile: boss,
      mine: [
        res('r1', today),
        res('r2', today.addDays(1)),
        res('r3', today.addDays(2)),
      ],
      group: myGroup,
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('maximální počet rezervací'), findsNothing);
  });

  // A second pumpWidget would keep the first ProviderScope's overrides, so
  // "under the cap" is a test of its own.
  testWidgets('…and stays quiet under the cap', (tester) async {
    await tester.pumpWidget(app(mine: [res('r1', today), res('r2', today)]));
    await tester.pumpAndSettle();
    expect(find.textContaining('maximální počet rezervací'), findsNothing);
  });

  testWidgets('a cancelled or past reservation does not count towards the cap',
      (tester) async {
    await tester.pumpWidget(app(mine: [
      res('r1', today),
      res('r2', today.addDays(-1)), // played
      Reservation(
        id: 'r3',
        playerId: me.id,
        date: today.addDays(3),
        blockId: 'b1',
        lane: 1,
        createdVia: 'app',
        createdAt: DateTime.utc(2026, 1, 1),
        cancelledAt: DateTime.utc(2026, 9, 1),
      ),
    ]));
    await tester.pumpAndSettle();
    expect(find.textContaining('maximální počet rezervací'), findsNothing);
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

    // Rotating a phone crosses the 600dp breakpoint, so the shell swaps
    // bottom tabs for a rail — and the calendar underneath must not take
    // that as a reason to start over on this week.
    testWidgets('turning the phone sideways keeps the paged week',
        (tester) async {
      phone(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      final monday = today.addDays(1 - today.weekday);
      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();
      final paged = monday.addDays(7);
      expect(find.text(rangeLabel(paged, paged.addDays(6))), findsOneWidget);

      // The same phone, turned sideways.
      tester.view.physicalSize = const Size(800, 400);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), findsOneWidget,
          reason: 'the layout did change — that is the point');
      expect(find.text(rangeLabel(paged, paged.addDays(6))), findsOneWidget,
          reason: 'the week the user chose survives the rotation');

      // And back again.
      tester.view.physicalSize = const Size(400, 800);
      await tester.pumpAndSettle();
      expect(find.text(rangeLabel(paged, paged.addDays(6))), findsOneWidget);
    });

    // Můj přehled is the first destination — the personal view leads, the
    // calendar follows. The order lives in HomeView's declaration, which
    // also indexes the IndexedStack, so a swap that forgot the children
    // would put the wrong screen behind the tab (the taps below catch that).
    testWidgets('Můj přehled leads the bottom tabs', (tester) async {
      phone(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(
        tester.getCenter(find.text('Můj přehled')).dx,
        lessThan(tester.getCenter(find.text('Kalendář')).dx),
      );

      await tester.tap(find.text('Můj přehled'));
      await tester.pumpAndSettle();
      expect(find.byType(MyTrainingsScreen), findsOneWidget);
    });

    testWidgets('…and the rail, top to bottom', (tester) async {
      wide(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(
        tester.getCenter(find.text('Můj přehled')).dy,
        lessThan(tester.getCenter(find.text('Kalendář')).dy),
      );
    });

    // Both views draw the SAME top strip, so the profile (and admin) icon
    // must not move a pixel when the tabs switch — a header that shifts
    // makes the icons a moving target and reads as two different screens.
    const admin = Profile(
      id: 'me',
      displayName: 'Já Správce',
      email: 'me@example.com',
      role: Role.admin,
      status: ProfileStatus.approved,
    );

    Future<void> expectHeaderHoldsStill(
      WidgetTester tester, {
      bool withTitle = true,
    }) async {
      await tester.pumpWidget(app(profile: admin));
      await tester.pumpAndSettle();

      Rect iconAt(IconData icon) => tester.getRect(find.byIcon(icon));
      final onCalendar = [
        iconAt(Icons.admin_panel_settings_outlined),
        iconAt(Icons.account_circle_outlined),
        if (withTitle) tester.getRect(find.text('Rezervátor')),
      ];

      await tester.tap(find.text('Můj přehled'));
      await tester.pumpAndSettle();
      expect(find.byType(MyTrainingsScreen), findsOneWidget);

      expect([
        iconAt(Icons.admin_panel_settings_outlined),
        iconAt(Icons.account_circle_outlined),
        if (withTitle) tester.getRect(find.text('Rezervátor')),
      ], onCalendar);
    }

    testWidgets('the header holds still across the tabs: phone portrait',
        (tester) async {
      phone(tester);
      await expectHeaderHoldsStill(tester);
    });

    // A landscape phone spends ~150dp on the rail, which leaves the strip
    // under the 700dp the title needs — both views drop it, and the icons
    // still land in the same place.
    testWidgets('…a landscape phone, where the title does not fit',
        (tester) async {
      phoneLandscape(tester);
      await expectHeaderHoldsStill(tester, withTitle: false);
      expect(find.text('Rezervátor'), findsNothing);
    });

    testWidgets('…and a wide screen', (tester) async {
      wide(tester);
      await expectHeaderHoldsStill(tester);
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

  group('Klubovna tab', () {
    testWidgets('a phone sees all three destinations, in order', (tester) async {
      phone(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(find.byType(NavigationBar), findsOneWidget);
      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.destinations, hasLength(3));
      expect(find.text('Můj přehled'), findsOneWidget);
      expect(find.text('Kalendář'), findsOneWidget);
      expect(find.text('Klubovna'), findsOneWidget);
      expect(
        tester.getCenter(find.text('Kalendář')).dx,
        lessThan(tester.getCenter(find.text('Klubovna')).dx),
      );
    });

    testWidgets('…and so does the rail on a wide screen', (tester) async {
      wide(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(find.byType(NavigationRail), findsOneWidget);
      final rail = tester.widget<NavigationRail>(find.byType(NavigationRail));
      expect(rail.destinations, hasLength(3));
      expect(find.text('Klubovna'), findsOneWidget);
    });

    testWidgets('tapping Klubovna shows the Výsledky and Kuželny hub entries',
        (tester) async {
      phone(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Klubovna'));
      await tester.pumpAndSettle();

      expect(find.text('Výsledky'), findsOneWidget);
      expect(find.text('Kuželny'), findsOneWidget);
      expect(find.byType(WeekScreen), findsNothing);
      expect(find.byType(MyTrainingsScreen), findsNothing);
    });

    testWidgets(
        'a back gesture away from Klubovna returns to the calendar too',
        (tester) async {
      phone(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Klubovna'));
      await tester.pumpAndSettle();
      expect(find.text('Výsledky'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byType(HomeShell), findsOneWidget);
      expect(find.byType(WeekScreen), findsOneWidget);
    });

    testWidgets('the header holds still when switching into Klubovna too',
        (tester) async {
      phone(tester);
      const admin = Profile(
        id: 'me',
        displayName: 'Já Správce',
        email: 'me@example.com',
        role: Role.admin,
        status: ProfileStatus.approved,
      );
      await tester.pumpWidget(app(profile: admin));
      await tester.pumpAndSettle();

      Rect iconAt(IconData icon) => tester.getRect(find.byIcon(icon));
      final onCalendar = [
        iconAt(Icons.admin_panel_settings_outlined),
        iconAt(Icons.account_circle_outlined),
      ];

      await tester.tap(find.text('Klubovna'));
      await tester.pumpAndSettle();

      expect([
        iconAt(Icons.admin_panel_settings_outlined),
        iconAt(Icons.account_circle_outlined),
      ], onCalendar);
    });
  });

  testWidgets('Klubovna carries a dot while a message or notice is unread', (tester) async {
    phone(tester);
    final msg = Message(
      id: 'm1', kind: MessageKind.message, audience: MessageAudience.day,
      authorId: 'staff', authorRole: MessageAuthorRole.player,
      onDate: today, blockId: null, title: null, body: 'Přijďte dřív.',
      expiresAt: null, notify: true, createdAt: now, updatedAt: now,
    );
    MessageRecipient row({DateTime? readAt}) => MessageRecipient(
        messageId: 'm1', userId: 'me', readAt: readAt,
        reaction: null, reply: null, reactedAt: null);

    await tester.pumpWidget(app(messages: [msg], messageRecipients: [row()]));
    await tester.pumpAndSettle();
    final dot =
        find.descendant(of: find.byType(NavigationBar), matching: find.byType(Badge));
    expect(dot, findsOneWidget);
    // A screen reader hears the tab with its count, not just „Klubovna“.
    expect(tester.getSemantics(dot).label, allOf(contains('Klubovna'), contains('1')));

    // A fresh scope: re-pumping the same ProviderScope keeps the stream
    // overrides' first values.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app(messages: [msg], messageRecipients: [row(readAt: now)]));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(NavigationBar), matching: find.byType(Badge)),
        findsNothing);

    // An unread notice alone keeps the dot: the message half of the sum is 0.
    final notice = Message(
      id: 'n1', kind: MessageKind.notice, audience: MessageAudience.all,
      authorId: 'staff', authorRole: MessageAuthorRole.admin,
      onDate: null, blockId: null, title: 'Úklid', body: 'V sobotu.',
      expiresAt: null, notify: true, createdAt: now, updatedAt: now,
    );
    MessageRecipient noticeRow() => MessageRecipient(
        messageId: 'n1', userId: 'me', readAt: null,
        reaction: null, reply: null, reactedAt: null);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app(
        messages: [msg, notice], messageRecipients: [row(readAt: now), noticeRow()]));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(NavigationBar), matching: find.byType(Badge)),
        findsOneWidget);
  });

  // Deep links (0051): a push tap or a /zpravy/:id, /nastenka/:id route
  // leaves a PendingLink; HomeShell opens it once and clears it.
  group('pending link', () {
    Message msg(String id, {MessageKind kind = MessageKind.message}) =>
        Message(
          id: id, kind: kind,
          audience: kind == MessageKind.notice
              ? MessageAudience.all
              : MessageAudience.admins,
          authorId: 'p1', authorRole: MessageAuthorRole.player,
          onDate: null, blockId: null,
          title: kind == MessageKind.notice ? 'Úklid' : null,
          body: 'Ahoj.', expiresAt: null, notify: true,
          createdAt: DateTime(2026, 9, 1), updatedAt: DateTime(2026, 9, 1),
        );

    testWidgets('a pending message link set while running opens '
        'MessageDetailScreen', (tester) async {
      await tester.pumpWidget(app(messages: [msg('m1')]));
      await tester.pumpAndSettle();
      final container =
          ProviderScope.containerOf(tester.element(find.byType(HomeShell)));
      container.read(pendingLinkProvider.notifier)
          .set(const PendingLink(kind: PendingLinkKind.message, id: 'm1'));
      await tester.pumpAndSettle();
      expect(find.byType(MessageDetailScreen), findsOneWidget);
      expect(container.read(pendingLinkProvider), isNull,
          reason: 'cleared after consuming');
    });

    testWidgets('a link already pending when HomeShell mounts (cold start, '
        '/zpravy/:id) opens too', (tester) async {
      await tester.pumpWidget(app(
        messages: [msg('m1')],
        pendingLink: const PendingLink(kind: PendingLinkKind.message, id: 'm1'),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(MessageDetailScreen), findsOneWidget);
    });

    // A push carries the alley it was sent for; a superadmin visiting
    // another alley (or another account on a shared phone) cannot read
    // that message, and „Zpráva už neexistuje.“ would be wrong.
    testWidgets('a link from another alley is dropped silently: no detail, '
        'no snack, nothing left pending', (tester) async {
      await tester.pumpWidget(app(profile: visiting, messages: [msg('m1')]));
      await tester.pumpAndSettle();
      final container =
          ProviderScope.containerOf(tester.element(find.byType(HomeShell)));
      container.read(pendingLinkProvider.notifier).set(const PendingLink(
          kind: PendingLinkKind.message, id: 'm1', tenantId: 't-home'));
      await tester.pumpAndSettle();
      expect(find.byType(MessageDetailScreen), findsNothing);
      expect(find.text('Zpráva už neexistuje.'), findsNothing);
      expect(container.read(pendingLinkProvider), isNull);
      // A notice link from another alley does not open the board either.
      container.read(pendingLinkProvider.notifier).set(const PendingLink(
          kind: PendingLinkKind.notice, id: 'n1', tenantId: 't-home'));
      await tester.pumpAndSettle();
      expect(find.byType(NoticeBoardScreen), findsNothing);
      expect(find.text('Oznámení už neexistuje.'), findsNothing);
      expect(container.read(pendingLinkProvider), isNull);
    });

    testWidgets('…while a link of my own alley opens as before', (tester) async {
      await tester.pumpWidget(app(profile: visiting, messages: [msg('m1')]));
      await tester.pumpAndSettle();
      ProviderScope.containerOf(tester.element(find.byType(HomeShell)))
          .read(pendingLinkProvider.notifier)
          .set(const PendingLink(
              kind: PendingLinkKind.message, id: 'm1', tenantId: 't-demo'));
      await tester.pumpAndSettle();
      expect(find.byType(MessageDetailScreen), findsOneWidget);
    });

    testWidgets('a freed-spot link brings the calendar up at that spot; one '
        'sent for another alley is dropped', (tester) async {
      await tester.pumpWidget(app(profile: visiting));
      await tester.pumpAndSettle();
      final container =
          ProviderScope.containerOf(tester.element(find.byType(HomeShell)));
      container.read(pendingLinkProvider.notifier).set(const PendingLink(
          kind: PendingLinkKind.freedSpot,
          tenantId: 't-home',
          date: '2026-09-10',
          blockId: 'b1',
          lane: 1));
      await tester.pump();
      await tester.pump();
      expect(container.read(calendarFocusProvider), isNull);
      expect(container.read(pendingLinkProvider), isNull);

      container.read(pendingLinkProvider.notifier).set(const PendingLink(
          kind: PendingLinkKind.freedSpot,
          tenantId: 't-demo',
          date: '2026-09-10',
          blockId: 'b1',
          lane: 1));
      await tester.pump();
      await tester.pump();
      final focus = container.read(calendarFocusProvider);
      expect(focus?.date, Day(2026, 9, 10));
      expect(focus?.blockId, 'b1');
      expect(focus?.lane, 1);
      await tester.pumpAndSettle(const Duration(seconds: 10));
    });

    testWidgets('a „new player waits“ link opens the admin\'s players list; '
        'one sent for another alley is dropped', (tester) async {
      await tester.pumpWidget(app(profile: visiting));
      await tester.pumpAndSettle();
      final container =
          ProviderScope.containerOf(tester.element(find.byType(HomeShell)));
      container.read(pendingLinkProvider.notifier).set(const PendingLink(
          kind: PendingLinkKind.pendingPlayer, tenantId: 't-home'));
      await tester.pumpAndSettle();
      expect(find.byType(PlayersScreen), findsNothing);
      expect(container.read(pendingLinkProvider), isNull);

      container.read(pendingLinkProvider.notifier).set(const PendingLink(
          kind: PendingLinkKind.pendingPlayer, tenantId: 't-demo'));
      await tester.pumpAndSettle();
      expect(find.byType(PlayersScreen), findsOneWidget);
    });

    testWidgets('a „new kuželna waits“ link opens the superadmin\'s kuželny '
        'list', (tester) async {
      await tester.pumpWidget(app(
        profile: visiting,
        pendingLink: const PendingLink(kind: PendingLinkKind.pendingTenant),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(TenantsScreen), findsOneWidget);
    });

    testWidgets('a pending link for an id that does not exist shows the '
        'not-found snack', (tester) async {
      await tester.pumpWidget(app(messageExists: (_) async => false));
      await tester.pumpAndSettle();
      final container =
          ProviderScope.containerOf(tester.element(find.byType(HomeShell)));
      container.read(pendingLinkProvider.notifier).set(
          const PendingLink(kind: PendingLinkKind.message, id: 'missing'));
      await tester.pumpAndSettle();
      expect(find.text('Zpráva už neexistuje.'), findsOneWidget);
      expect(find.byType(MessageDetailScreen), findsNothing);
    });

    const noticeLink = PendingLink(kind: PendingLinkKind.notice, id: 'n1');

    testWidgets('a notice link opens the board; a notice the server calls '
        'gone adds „Oznámení už neexistuje.“', (tester) async {
      final asked = <String>[];
      await tester.pumpWidget(app(
        pendingLink: noticeLink,
        messageExists: (id) async {
          asked.add(id);
          return false;
        },
      ));
      await tester.pumpAndSettle();
      expect(find.byType(NoticeBoardScreen), findsOneWidget);
      expect(find.text('Oznámení už neexistuje.'), findsOneWidget);
      expect(find.text('Zpráva už neexistuje.'), findsNothing);
      expect(asked, ['n1']);
    });

    testWidgets('…and a notice already in the snapshot opens the board '
        'without one, and without asking the server', (tester) async {
      final asked = <String>[];
      await tester.pumpWidget(app(
        messages: [msg('n1', kind: MessageKind.notice)],
        pendingLink: noticeLink,
        messageExists: (id) async {
          asked.add(id);
          return false;
        },
      ));
      await tester.pumpAndSettle();
      expect(find.byType(NoticeBoardScreen), findsOneWidget);
      expect(find.text('Oznámení už neexistuje.'), findsNothing);
      expect(asked, isEmpty);
    });

    // cachedRows replays the on-disk cache first (cold start), and a warm
    // tap finds the pre-background list: either way the notice the push
    // announced is usually newer than the first snapshot.
    testWidgets('a stale first snapshot without the notice is no proof: the '
        'server says it exists, so no snack once the live list has it',
        (tester) async {
      final asked = <String>[];
      Stream<List<Message>> staleThenLive() async* {
        yield const [];
        await Future<void>.delayed(const Duration(milliseconds: 300));
        yield [msg('n1', kind: MessageKind.notice)];
      }

      await tester.pumpWidget(app(
        messagesStream: staleThenLive,
        pendingLink: noticeLink,
        messageExists: (id) async {
          asked.add(id);
          return true;
        },
      ));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.byType(NoticeBoardScreen), findsOneWidget);
      expect(find.text('Úklid'), findsOneWidget);
      expect(find.text('Oznámení už neexistuje.'), findsNothing);
      expect(asked, ['n1']);
    });

    testWidgets('offline (the server cannot be asked): no snack, no error',
        (tester) async {
      await tester.pumpWidget(app(
        pendingLink: noticeLink,
        messageExists: (_) async => throw Exception('offline'),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(NoticeBoardScreen), findsOneWidget);
      expect(find.text('Oznámení už neexistuje.'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no cache and no network (the messages stream fails): no '
        'snack and no uncaught error', (tester) async {
      await tester.pumpWidget(app(
        messagesStream: () => Stream.error(Exception('offline')),
        pendingLink: noticeLink,
        messageExists: (_) async => throw Exception('offline'),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(NoticeBoardScreen), findsOneWidget);
      expect(find.text('Oznámení už neexistuje.'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}

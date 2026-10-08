import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/admin/kiosk_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Verifies the kiosk theme `SwitchListTile` calls Api.setKioskDark, which
/// PATCHes `schedule_settings.kiosk_dark` — asserted here by inspecting the
/// stubbed HTTP request rather than hitting a real backend.
void main() {
  const admin = Profile(
    id: 'admin1',
    displayName: 'Správce',
    email: 'admin@example.com',
    role: Role.admin,
    status: ProfileStatus.approved,
  );

  const defaults0 = ScheduleSettings(
    laneCount: 4,
    trainingWeekdays: {1, 2, 4},
    bookingHorizonDays: 14,
    maxActiveReservations: 3,
    kioskDark: true,
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
        detectSessionInUri: false,
        localStorage: EmptyLocalStorage(),
      ),
    );
  });

  setUp(() => requests = []);

  // The page is long (the panel options sit above the address): a tall
  // window keeps every section built.
  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Widget app({
    List<Profile> roster = const [admin],
    Future<String> Function(String)? resetPassword,
    ScheduleSettings? settings,
    bool? panelEnabled,
  }) {
    final shown = settings ??
        (panelEnabled == null
            ? defaults0
            : ScheduleSettings(
                laneCount: 4,
                trainingWeekdays: const {1, 2, 4},
                bookingHorizonDays: 14,
                maxActiveReservations: 3,
                kioskPanelEnabled: panelEnabled,
              ));
    return ProviderScope(
      overrides: [
        myProfileProvider.overrideWith((ref) => Stream.value(admin)),
        settingsProvider.overrideWith((ref) => Stream.value(shown)),
        clubsProvider.overrideWith((ref) => Stream.value(const [])),
        profilesProvider.overrideWith((ref) => Stream.value(roster)),
      ],
      child: MaterialApp(
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: const [Locale('cs'), Locale('en')],
        home: KioskSettingsScreen(
          resetPassword:
              resetPassword ?? (_) async => 'abcd-efgh-jkmn-pqrt',
        ),
      ),
    );
  }

  testWidgets(
      'toggling "Kiosk: tmavý režim" PATCHes schedule_settings.kiosk_dark',
      (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Kiosk: tmavý režim'), findsOneWidget);

    await tester.tap(find.widgetWithText(SwitchListTile, 'Kiosk: tmavý režim'));
    await tester.pumpAndSettle();

    final patch = requests.firstWhere(
      (r) => r.method == 'PATCH' && r.url.path.contains('schedule_settings'),
    );
    final body = jsonDecode(patch.body) as Map<String, dynamic>;
    // Started `true` (dark); toggling flips it to `false`.
    expect(body['kiosk_dark'], false);
  });

  testWidgets(
      'toggling "Kiosk: celý den na obrazovku" PATCHes '
      'schedule_settings.kiosk_fit_day', (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    final tile =
        find.widgetWithText(SwitchListTile, 'Kiosk: celý den na obrazovku');
    expect(tile, findsOneWidget);
    await tester.ensureVisible(tile);
    await tester.tap(tile);
    await tester.pumpAndSettle();

    final patch = requests.firstWhere(
      (r) =>
          r.method == 'PATCH' &&
          r.url.path.contains('schedule_settings') &&
          r.body.contains('kiosk_fit_day'),
    );
    final body = jsonDecode(patch.body) as Map<String, dynamic>;
    // Started `true` (fit); toggling flips it to `false` (scroll mode).
    expect(body['kiosk_fit_day'], false);
  });

  testWidgets('kiosk accounts are administered here, not among Hráči',
      (tester) async {
    tall(tester);
    const kiosk = Profile(
      id: 'k1',
      displayName: 'Kiosk u dráhy',
      email: 'kiosk@veverky.cz',
      role: Role.kiosk,
      status: ProfileStatus.approved,
    );
    await tester.pumpWidget(app(roster: const [admin, kiosk]));
    await tester.pumpAndSettle();

    expect(find.text('Kioskové účty'), findsOneWidget);
    expect(find.text('Kiosk u dráhy'), findsOneWidget);
    expect(find.text('kiosk@veverky.cz'), findsOneWidget);
    // Only kiosk accounts — the admin is a person and belongs in Hráči.
    expect(find.text('Správce'), findsNothing);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Vrátit mezi hráče'));
    await tester.pumpAndSettle();

    final call = requests.last;
    expect(call.url.path, endsWith('/rpc/set_role'));
    expect(jsonDecode(call.body), {'p_user_id': 'k1', 'p_role': 'player'});
  });

  testWidgets('a new kiosk password is asked for, then shown once',
      (tester) async {
    tall(tester);
    const kiosk = Profile(
      id: 'k1',
      displayName: 'Kiosk u dráhy',
      email: 'kiosk@veverky.cz',
      role: Role.kiosk,
      status: ProfileStatus.approved,
    );
    final asked = <String>[];
    await tester.pumpWidget(app(
      roster: const [admin, kiosk],
      resetPassword: (id) async {
        asked.add(id);
        return 'abcd-efgh-jkmn-pqrt';
      },
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nastavit nové heslo…'));
    await tester.pumpAndSettle();

    // Asked first: the current password stops working.
    expect(find.text('Nastavit nové heslo?'), findsOneWidget);
    expect(find.textContaining('přestane platit'), findsOneWidget);
    await tester.tap(find.text('Nastavit'));
    await tester.pumpAndSettle();

    // The answer is shown once, with the login it belongs to.
    expect(asked, ['k1']);
    expect(find.text('Nové heslo kiosku'), findsOneWidget);
    expect(find.text('abcd-efgh-jkmn-pqrt'), findsOneWidget);
    expect(find.text('Přihlašovací jméno: kiosk@veverky.cz'), findsOneWidget);
  });

  testWidgets('a refused reset shows why and no password', (tester) async {
    tall(tester);
    const kiosk = Profile(
      id: 'k1',
      displayName: 'Kiosk u dráhy',
      email: 'kiosk@veverky.cz',
      role: Role.kiosk,
      status: ProfileStatus.approved,
    );
    await tester.pumpWidget(app(
      roster: const [admin, kiosk],
      resetPassword: (_) async => throw Exception('not_allowed'),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nastavit nové heslo…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nastavit'));
    await tester.pumpAndSettle();

    expect(find.text('Nové heslo kiosku'), findsNothing);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  // Setting a tablet up needs two things from this screen: where to point
  // its browser, and an account to log in with. The address is derived from
  // where the app runs (kioskUrlFrom), so the test asserts the route and
  // the clipboard, not a hard-coded host.
  testWidgets('the kiosk address is shown and copies to the clipboard',
      (tester) async {
    tall(tester);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Adresa pro tablet'), findsOneWidget);
    final shown = tester
        .widget<SelectableText>(find.byType(SelectableText))
        .data!;
    expect(shown, endsWith('/#/kiosk-login'));

    await tester.tap(find.byIcon(Icons.copy_outlined));
    await tester.pumpAndSettle();
    expect(copied, shown);
    expect(find.text('Adresa zkopírována.'), findsOneWidget);
  });

  testWidgets('without a kiosk account the section explains how to make one',
      (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Kioskové účty'), findsOneWidget);
    expect(find.textContaining('Nastavit jako kiosk'), findsOneWidget);
    expect(find.text('Vrátit mezi hráče'), findsNothing);
  });

  testWidgets('the panel options PATCH their own columns', (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    Map<String, dynamic> lastPatch() => jsonDecode(
          requests.lastWhere((r) => r.method == 'PATCH').body,
        ) as Map<String, dynamic>;

    await tester.ensureVisible(find.text('Nástěnka na kiosku'));
    await tester.tap(find.text('V záhlaví i v panelu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('V záhlaví').last);
    await tester.pumpAndSettle();
    expect(lastPatch(), {'kiosk_notices_mode': 'header'});

    await tester.tap(find.widgetWithText(SwitchListTile, 'Zápasy v panelu'));
    await tester.pumpAndSettle();
    expect(lastPatch(), {'kiosk_show_matches': false});

    await tester.tap(
        find.widgetWithText(SwitchListTile, 'Panel je výchozně rozbalený'));
    await tester.pumpAndSettle();
    expect(lastPatch(), {'kiosk_drawer_open': true});
  });

  testWidgets('the weeks of matches, width, share, Zápis size and the two '
      'rotations are chosen from lists', (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    Future<void> pick(String field, String current, String wanted) async {
      await tester.ensureVisible(find.text(field));
      await tester.tap(find.text(current).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(wanted).last);
      await tester.pumpAndSettle();
    }

    Map<String, dynamic> lastPatch() => jsonDecode(
          requests.lastWhere((r) => r.method == 'PATCH').body,
        ) as Map<String, dynamic>;

    // The defaults: 2 weeks back, 1 ahead, 440 px, 40 %, 80 %, 12 s each.
    await pick('Odehrané zápasy', '2 týdny zpět', 'Jen aktuální týden');
    expect(lastPatch(), {'kiosk_weeks_back': 0});
    await pick('Budoucí zápasy', '1 týden dopředu', '3 týdny dopředu');
    expect(lastPatch(), {'kiosk_weeks_ahead': 3});
    await pick('Šířka panelu', '440 px', '600 px');
    expect(lastPatch(), {'kiosk_drawer_width': 600});
    await pick('Podíl nástěnky na výšce panelu', '40 %', '60 %');
    expect(lastPatch(), {'kiosk_notices_share': 60});
    await pick('Velikost zápisu', '80 % obrazovky',
        'Celá obrazovka (s křížkem)');
    expect(lastPatch(), {'kiosk_zapis_percent': 100});
    await pick('Střídání oznamů', 'po 12 s', 'po 20 s');
    expect(lastPatch(), {'kiosk_notices_rotation_seconds': 20});
    await pick('Střídání aktuálních zápasů', 'po 12 s', 'po 30 s');
    expect(lastPatch(), {'kiosk_live_rotation_seconds': 30});
  });

  testWidgets('the idle time is chosen from a list', (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    // The default is a minute.
    await tester.ensureVisible(find.text('Doba nečinnosti'));
    await tester.tap(find.text('1 min').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('5 min').last);
    await tester.pumpAndSettle();
    expect(jsonDecode(requests.lastWhere((r) => r.method == 'PATCH').body),
        {'kiosk_idle_seconds': 300});
  });

  testWidgets('the ranges say they are only the default', (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.textContaining('Jen výchozí rozsah'), findsNWidgets(2));
  });

  testWidgets('the panel switch comes first, and what needs it hides with it',
      (tester) async {
    tall(tester);
    await tester.pumpWidget(app(panelEnabled: false));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(SwitchListTile, 'Panel vpravo'), findsOneWidget);
    for (final dependent in [
      'Panel je výchozně rozbalený',
      'Zápasy v panelu',
      'Aktuální zápas přes celý panel',
    ]) {
      expect(find.widgetWithText(SwitchListTile, dependent), findsNothing);
    }
    expect(find.text('Šířka panelu'), findsNothing);
    // The notices can still go to the status bar without the panel.
    expect(find.text('Nástěnka na kiosku'), findsOneWidget);

    await tester.tap(find.widgetWithText(SwitchListTile, 'Panel vpravo'));
    await tester.pumpAndSettle();
    expect(jsonDecode(requests.lastWhere((r) => r.method == 'PATCH').body),
        {'kiosk_panel_enabled': true});
  });

  testWidgets('a rotation shows only with what it rotates', (tester) async {
    tall(tester);
    await tester.pumpWidget(app(
      settings: const ScheduleSettings(
        laneCount: 4,
        trainingWeekdays: {1},
        bookingHorizonDays: 14,
        maxActiveReservations: 3,
        kioskNoticesMode: KioskNoticesMode.off,
        kioskLiveMode: false,
        tenantId: 't',
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Střídání oznamů'), findsNothing);
    expect(find.text('Střídání aktuálních zápasů'), findsNothing);
    // Without the notices the notices' share has nothing to share either.
    expect(find.text('Podíl nástěnky na výšce panelu'), findsNothing);
  });

  testWidgets('the look back into the past is an on/off and a number of days',
      (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    Map<String, dynamic> lastPatch() => jsonDecode(
          requests.lastWhere((r) => r.method == 'PATCH').body,
        ) as Map<String, dynamic>;

    // Off by default: no number to choose.
    expect(find.text('Jak daleko zpět'), findsNothing);
    await tester.tap(
        find.widgetWithText(SwitchListTile, 'Kiosk: posun do minulosti'));
    await tester.pumpAndSettle();
    expect(lastPatch(), {'kiosk_past_days': 7});
  });

  testWidgets('the upcoming matches and the live match have their switches',
      (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    Map<String, dynamic> lastPatch() => jsonDecode(
          requests.lastWhere((r) => r.method == 'PATCH').body,
        ) as Map<String, dynamic>;

    await tester.tap(find.widgetWithText(SwitchListTile, 'Následující zápasy'));
    await tester.pumpAndSettle();
    expect(lastPatch(), {'kiosk_show_upcoming': false});

    await tester.tap(find.widgetWithText(
        SwitchListTile, 'Aktuální zápas přes celý panel'));
    await tester.pumpAndSettle();
    expect(lastPatch(), {'kiosk_live_mode': false});
  });
}

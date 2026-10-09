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
    tester.view.physicalSize = const Size(800, 4200);
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
      'toggling "Tmavý režim" PATCHes schedule_settings.kiosk_dark',
      (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Tmavý režim'), findsOneWidget);

    await tester.tap(find.widgetWithText(SwitchListTile, 'Tmavý režim'));
    await tester.pumpAndSettle();

    final patch = requests.firstWhere(
      (r) => r.method == 'PATCH' && r.url.path.contains('schedule_settings'),
    );
    final body = jsonDecode(patch.body) as Map<String, dynamic>;
    // Started `true` (dark); toggling flips it to `false`.
    expect(body['kiosk_dark'], false);
  });

  testWidgets(
      'toggling "Celý den na obrazovku" PATCHes '
      'schedule_settings.kiosk_fit_day', (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    final tile =
        find.widgetWithText(SwitchListTile, 'Celý den na obrazovku');
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

    await tester.ensureVisible(find.text('Kde se oznamy zobrazí'));
    await tester.tap(find.text('V záhlaví i v panelu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Jen v záhlaví').last);
    await tester.pumpAndSettle();
    expect(lastPatch(), {'kiosk_notices_mode': 'header'});

    await tester.tap(find.widgetWithText(SwitchListTile, 'Zápasy v panelu'));
    await tester.pumpAndSettle();
    expect(lastPatch(), {'kiosk_show_matches': false});

    await tester.tap(
        find.widgetWithText(SwitchListTile, 'Výchozně rozbalený'));
    await tester.pumpAndSettle();
    expect(lastPatch(), {'kiosk_drawer_open': true});
  });

  /// Types [text] into the number field [label] and presses Enter.
  Future<void> enter(WidgetTester tester, String label, String text) async {
    final field = find.widgetWithText(TextField, label);
    await tester.ensureVisible(field);
    await tester.enterText(field, text);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  testWidgets('the numbers are typed in: each PATCHes its own column on '
      'Enter', (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    Map<String, dynamic> lastPatch() => jsonDecode(
          requests.lastWhere((r) => r.method == 'PATCH').body,
        ) as Map<String, dynamic>;

    // The defaults are in the fields: 60 s, 2 columns, 2 weeks back.
    String shown(String label) =>
        tester.widget<TextField>(find.widgetWithText(TextField, label))
            .controller!.text;
    expect(shown('Doba nečinnosti'), '60');
    expect(shown('Šířka panelu'), '2');
    expect(shown('Odehrané zápasy: týdnů zpět'), '2');

    await enter(tester, 'Doba nečinnosti', '300');
    expect(lastPatch(), {'kiosk_idle_seconds': 300});
    await enter(tester, 'Střídání oznamů', '20');
    expect(lastPatch(), {'kiosk_notices_rotation_seconds': 20});
    await enter(tester, 'Šířka panelu', '3');
    expect(lastPatch(), {'kiosk_drawer_columns': 3});
    await enter(tester, 'Podíl nástěnky na výšce panelu', '60');
    expect(lastPatch(), {'kiosk_notices_share': 60});
    await enter(tester, 'Odehrané zápasy: týdnů zpět', '0');
    expect(lastPatch(), {'kiosk_weeks_back': 0});
    await enter(tester, 'Budoucí zápasy: týdnů dopředu', '3');
    expect(lastPatch(), {'kiosk_weeks_ahead': 3});
    await enter(tester, 'Kontrola výsledků', '120');
    expect(lastPatch(), {'kiosk_live_refresh_seconds': 120});
    await enter(tester, 'Střídání hraných zápasů', '30');
    expect(lastPatch(), {'kiosk_live_rotation_seconds': 30});
    await enter(tester, 'Velikost zápisu', '100');
    expect(lastPatch(), {'kiosk_zapis_percent': 100});
  });

  testWidgets('a number out of its range is refused: the field says the '
      'range and nothing is written; the same number writes nothing either',
      (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    int patches() => requests.where((r) => r.method == 'PATCH').length;

    await enter(tester, 'Velikost zápisu', '120');
    expect(find.text('Zadej číslo od 50 do 100.'), findsOneWidget);
    expect(patches(), 0);
    await enter(tester, 'Doba nečinnosti', '');
    expect(find.text('Zadej číslo od 15 do 600.'), findsOneWidget);
    expect(patches(), 0);
    // The default again: no write, and the error goes away.
    await enter(tester, 'Doba nečinnosti', '60');
    expect(find.text('Zadej číslo od 15 do 600.'), findsNothing);
    expect(patches(), 0);
  });

  testWidgets('the screen block: dark mode, then the idle time and the Zápis '
      'size, then the day on the screen and the days on the screen', (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    double top(Finder f) => tester.getTopLeft(f).dy;
    final order = [
      top(find.text('Tmavý režim')),
      top(find.widgetWithText(TextField, 'Doba nečinnosti')),
      top(find.widgetWithText(TextField, 'Velikost zápisu')),
      top(find.text('Celý den na obrazovku')),
      top(find.widgetWithText(TextField, 'Dní na obrazovce')),
      top(find.text('Posun tabule do minulosti')),
      top(find.text('Nástěnka')),
    ];
    for (var i = 1; i < order.length; i++) {
      expect(order[i - 1], lessThan(order[i]), reason: 'option $i');
    }
    // The Zápis size moved out of the live match's block.
    expect(find.widgetWithText(TextField, 'Velikost zápisu'), findsOneWidget);
  });

  testWidgets('the days on the screen: 2–14, a week by default', (
    tester,
  ) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    Map<String, dynamic> lastPatch() => jsonDecode(
          requests.lastWhere((r) => r.method == 'PATCH').body,
        ) as Map<String, dynamic>;
    String shown(String label) =>
        tester.widget<TextField>(find.widgetWithText(TextField, label))
            .controller!.text;
    expect(shown('Dní na obrazovce'), '7');

    await enter(tester, 'Dní na obrazovce', '1');
    expect(find.text('Zadej číslo od 2 do 14.'), findsOneWidget);
    expect(requests.where((r) => r.method == 'PATCH'), isEmpty);
    await enter(tester, 'Dní na obrazovce', '5');
    expect(lastPatch(), {'kiosk_visible_days': 5});
  });

  testWidgets('the lane row height shows only while the day scrolls', (
    tester,
  ) async {
    tall(tester);
    // Fit day on (the default): no row height.
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Výška řádku dráhy'), findsNothing);
    await tester.pumpWidget(const SizedBox());

    await tester.pumpWidget(app(
      settings: const ScheduleSettings(
        laneCount: 4,
        trainingWeekdays: {1},
        bookingHorizonDays: 14,
        maxActiveReservations: 3,
        kioskFitDay: false,
        tenantId: 't',
      ),
    ));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Výška řádku dráhy'))
          .controller!
          .text,
      '40',
    );
    await enter(tester, 'Výška řádku dráhy', '56');
    expect(jsonDecode(requests.lastWhere((r) => r.method == 'PATCH').body),
        {'kiosk_row_height': 56});
  });

  testWidgets('leaving a number field writes it too', (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final field = find.widgetWithText(TextField, 'Šířka panelu');
    await tester.ensureVisible(field);
    await tester.enterText(field, '3');
    // Focus moves on to another field: the first one commits.
    await tester.tap(find.widgetWithText(TextField, 'Doba nečinnosti'));
    await tester.pumpAndSettle();
    expect(jsonDecode(requests.lastWhere((r) => r.method == 'PATCH').body),
        {'kiosk_drawer_columns': 3});
  });

  testWidgets('the options come in sections: screen, notices, panel, live '
      'match, then the address and the accounts', (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    double top(String text) => tester.getTopLeft(find.text(text)).dy;
    final order = [
      top('Obrazovka kiosku'),
      top('Nástěnka'),
      top('Postranní panel'),
      top('Hraný zápas'),
      top('Adresa pro tablet'),
      top('Kioskové účty'),
    ];
    for (var i = 1; i < order.length; i++) {
      expect(order[i - 1], lessThan(order[i]), reason: 'section $i');
    }
  });

  testWidgets('the live match\'s drawing is chosen from a list', (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    Map<String, dynamic> lastPatch() => jsonDecode(
          requests.lastWhere((r) => r.method == 'PATCH').body,
        ) as Map<String, dynamic>;
    await tester.ensureVisible(find.text('Zobrazení hraného zápasu'));
    // The default: the cards. Zápis is the app's own layout, never offered.
    await tester.tap(find.text('Podrobné — karty soubojů').first);
    await tester.pumpAndSettle();
    expect(find.text('Kompaktní — bez posouvání'), findsOneWidget);
    expect(find.text('Tabulka — souboj na řádek'), findsOneWidget);
    expect(find.text('Zápis'), findsNothing);
    await tester.tap(find.text('Tabulka — souboj na řádek').last);
    await tester.pumpAndSettle();
    expect(lastPatch(), {'kiosk_live_layout': 'table'});
  });

  testWidgets('the ranges say they are only the default', (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.textContaining('Jen výchozí rozsah'), findsNWidgets(2));
    // Each names the kiosk's button for its own direction.
    expect(find.textContaining('(„Zobrazit předchozí“)'), findsOneWidget);
    expect(find.textContaining('(„Zobrazit další“)'), findsOneWidget);
  });

  testWidgets('the panel switch comes first, and what needs it hides with it',
      (tester) async {
    tall(tester);
    await tester.pumpWidget(app(panelEnabled: false));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(SwitchListTile, 'Panel zapnutý'), findsOneWidget);
    for (final dependent in [
      'Výchozně rozbalený',
      'Zápasy v panelu',
      'Hraný zápas přes celý panel',
    ]) {
      expect(find.widgetWithText(SwitchListTile, dependent), findsNothing);
    }
    expect(find.text('Šířka panelu'), findsNothing);
    expect(find.text('Hraný zápas'), findsNothing);
    // The notices can still go to the status bar without the panel.
    expect(find.text('Kde se oznamy zobrazí'), findsOneWidget);

    await tester.tap(find.widgetWithText(SwitchListTile, 'Panel zapnutý'));
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
    expect(find.text('Střídání hraných zápasů'), findsNothing);
    expect(find.text('Kontrola výsledků'), findsNothing);
    // Without the notices the notices' share has nothing to share either.
    expect(find.text('Podíl nástěnky na výšce panelu'), findsNothing);
    // The Zápis size is not the live match's alone: a finished match in the
    // list opens one too.
    expect(find.text('Velikost zápisu'), findsOneWidget);
  });

  testWidgets('the look back into the past is an on/off and a number of days',
      (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    Map<String, dynamic> lastPatch() => jsonDecode(
          requests.lastWhere((r) => r.method == 'PATCH').body,
        ) as Map<String, dynamic>;

    // Off by default: no number to type.
    expect(find.text('Kolik dní zpět'), findsNothing);
    await tester.tap(
        find.widgetWithText(SwitchListTile, 'Posun tabule do minulosti'));
    await tester.pumpAndSettle();
    expect(lastPatch(), {'kiosk_past_days': 7});

    // On: the number shows and is typed in. (A fresh scope: a ProviderScope
    // keeps the overrides it was born with.)
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.pumpWidget(app(
      settings: const ScheduleSettings(
        laneCount: 4,
        trainingWeekdays: {1},
        bookingHorizonDays: 14,
        maxActiveReservations: 3,
        kioskPastDays: 7,
        tenantId: 't',
      ),
    ));
    await tester.pumpAndSettle();
    await enter(tester, 'Kolik dní zpět', '14');
    expect(lastPatch(), {'kiosk_past_days': 14});
  });

  testWidgets('the upcoming matches and the live match have their switches',
      (tester) async {
    tall(tester);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    Map<String, dynamic> lastPatch() => jsonDecode(
          requests.lastWhere((r) => r.method == 'PATCH').body,
        ) as Map<String, dynamic>;

    await tester.tap(find.widgetWithText(SwitchListTile, 'I budoucí zápasy'));
    await tester.pumpAndSettle();
    expect(lastPatch(), {'kiosk_show_upcoming': false});

    await tester.tap(find.widgetWithText(
        SwitchListTile, 'Hraný zápas přes celý panel'));
    await tester.pumpAndSettle();
    expect(lastPatch(), {'kiosk_live_mode': false});
  });
}

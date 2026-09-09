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

  const settings = ScheduleSettings(
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

  Widget app({
    List<Profile> roster = const [admin],
    Future<String> Function(String)? resetPassword,
  }) {
    return ProviderScope(
      overrides: [
        myProfileProvider.overrideWith((ref) => Stream.value(admin)),
        settingsProvider.overrideWith((ref) => Stream.value(settings)),
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
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Kioskové účty'), findsOneWidget);
    expect(find.textContaining('Nastavit jako kiosk'), findsOneWidget);
    expect(find.text('Vrátit mezi hráče'), findsNothing);
  });
}

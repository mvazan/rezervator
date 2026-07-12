import 'dart:convert';

import 'package:flutter/material.dart';
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
    club: '',
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
        localStorage: EmptyLocalStorage(),
      ),
    );
  });

  setUp(() => requests = []);

  Widget app() {
    return ProviderScope(
      overrides: [
        myProfileProvider.overrideWith((ref) => Stream.value(admin)),
        settingsProvider.overrideWith((ref) => Stream.value(settings)),
        clubsProvider.overrideWith((ref) => Stream.value(const [])),
      ],
      child: const MaterialApp(
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: [Locale('cs'), Locale('en')],
        home: KioskSettingsScreen(),
      ),
    );
  }

  testWidgets(
      'toggling "Kiosk: tmavý režim" PATCHes schedule_settings.kiosk_dark',
      (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    expect(find.text('Kiosk: tmavý režim'), findsOneWidget);

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    final patch = requests.firstWhere(
      (r) => r.method == 'PATCH' && r.url.path.contains('schedule_settings'),
    );
    final body = jsonDecode(patch.body) as Map<String, dynamic>;
    // Started `true` (dark); toggling flips it to `false`.
    expect(body['kiosk_dark'], false);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/auth/login_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Stubs every Supabase HTTP call with a 200 so the magic-link send in the
/// login screen resolves successfully — the login screen then flips to its
/// "sent" state, which is the only state where the OTP-code fallback button
/// is offered. We assert that gating: the button appears only after send.
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // Supabase.initialize reaches for shared_preferences (PKCE async storage),
    // which has no plugin under flutter_test — register an in-memory mock.
    SharedPreferences.setMockInitialValues({});
    final mock = MockClient((request) async {
      // /auth/v1/otp (magic-link send) — any 200 body is fine.
      return http.Response('{}', 200,
          headers: {'content-type': 'application/json'});
    });
    await Supabase.initialize(
      url: 'http://localhost:54321',
      publishableKey: 'test-anon-key',
      httpClient: mock,
      // In-memory session storage — avoids the shared_preferences plugin,
      // which has no implementation under flutter_test.
      authOptions: const FlutterAuthClientOptions(
        localStorage: EmptyLocalStorage(),
      ),
    );
  });

  Widget app() {
    return const ProviderScope(
      child: MaterialApp(
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: [Locale('cs'), Locale('en')],
        home: LoginScreen(),
      ),
    );
  }

  // The load-bearing RLS gate: while signed out, every RLS-dependent stream
  // must resolve to its empty snapshot WITHOUT opening a Supabase realtime
  // channel under the anon role. Reading them here (no session in
  // EmptyLocalStorage) exercises the `_authUidProvider == null` short-circuit;
  // if any provider forgot the gate it would instead try to open a stream.
  test('RLS-gated streams resolve empty while signed out', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    // Keeps every provider active for the test's lifetime — a bare read on a
    // StreamProvider never flushes its stream in a widget-less container, so
    // `.future` would hang without a live listener. For the gated signed-out
    // branch each provider resolves to its synchronous empty snapshot.
    final monday = Day.parse('2026-07-06');
    for (final sub in [
      container.listen(profilesProvider, (_, _) {}),
      container.listen(timeBlocksProvider, (_, _) {}),
      container.listen(settingsProvider, (_, _) {}),
      container.listen(dayOverridesProvider, (_, _) {}),
      container.listen(prioritySlotsProvider, (_, _) {}),
      container.listen(rentalsProvider, (_, _) {}),
      container.listen(myProfileProvider, (_, _) {}),
      container.listen(myActiveReservationsProvider, (_, _) {}),
      container.listen(weekReservationsProvider(monday), (_, _) {}),
    ]) {
      addTearDown(sub.close);
    }

    expect(await container.read(profilesProvider.future), isEmpty);
    expect(await container.read(timeBlocksProvider.future), isEmpty);
    expect(await container.read(settingsProvider.future), isNull);
    expect(await container.read(dayOverridesProvider.future), isEmpty);
    expect(await container.read(slotTypesProvider.future), isEmpty);
    expect(container.read(prioritySlotsProvider), isEmpty);
    expect(await container.read(rentalsProvider.future), isEmpty);
    expect(await container.read(myProfileProvider.future), isNull);
    expect(
        await container.read(myActiveReservationsProvider.future), isEmpty);
    expect(await container.read(weekReservationsProvider(monday).future),
        isEmpty);
    // playersProvider is a FutureProvider; its gated branch returns [] too.
    expect(await container.read(playersProvider.future), isEmpty);
  });

  testWidgets(
    'the "Zadat kód z e-mailu" button appears in the sent state',
    (tester) async {
      await tester.pumpWidget(app());
      await tester.pump();

      // Before sending: no OTP entry button, just the send form.
      expect(find.text('Zadat kód z e-mailu'), findsNothing);
      expect(find.text('Poslat přihlašovací odkaz'), findsOneWidget);

      // Request the magic link with a valid e-mail; the mocked HTTP client
      // makes the send succeed, flipping the screen to its sent state.
      await tester.enterText(find.byType(TextField), 'hrac@example.com');

      // The magic-link send hits Supabase over the mocked HTTP client, whose
      // Future resolves on the real event loop — runAsync lets it complete
      // (the default fake-async clock would leave it stuck on "Odesílám…").
      await tester.runAsync(() async {
        await tester.tap(find.byType(FilledButton));
        // Let the send Future settle, then rebuild into the sent state.
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();

      // In the sent state the OTP-code fallback button is now offered.
      expect(find.text('Poslat znovu / jiný e-mail'), findsOneWidget);
      expect(find.text('Zadat kód z e-mailu'), findsOneWidget);
    },
  );
}

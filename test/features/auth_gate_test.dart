import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/features/auth/auth_gate.dart';
import 'package:rezervator/features/auth/register_screen.dart';
import 'package:rezervator/features/auth/update_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The gate blocks a too-old build BEFORE anything else once a session
/// exists (0025), and lets a current build through to the usual routing.
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://localhost:54321',
      publishableKey: 'test-anon-key',
      httpClient: MockClient((request) async => http.Response('[]', 200,
          headers: {'content-type': 'application/json'}, request: request)),
      authOptions: const FlutterAuthClientOptions(
        detectSessionInUri: false,
        localStorage: EmptyLocalStorage(),
      ),
    );
  });

  final session = Session(
    accessToken: 'token',
    tokenType: 'bearer',
    user: const User(
      id: 'me',
      appMetadata: {},
      userMetadata: {},
      aud: 'authenticated',
      createdAt: '2026-01-01T00:00:00Z',
    ),
  );

  Widget app({required bool updateRequired}) => ProviderScope(
        overrides: [
          authStateProvider.overrideWith((ref) =>
              Stream.value(AuthState(AuthChangeEvent.initialSession, session))),
          updateRequiredProvider.overrideWithValue(updateRequired),
          myProfileProvider.overrideWith((ref) => Stream.value(null)),
          tenantsProvider.overrideWith((ref) async => const []),
        ],
        child: const MaterialApp(home: AuthGate()),
      );

  testWidgets('a too-old build sees the update screen and nothing else',
      (tester) async {
    await tester.pumpWidget(app(updateRequired: true));
    await tester.pumpAndSettle();
    expect(find.byType(UpdateScreen), findsOneWidget);
    expect(find.byType(RegisterScreen), findsNothing);
  });

  testWidgets('a current build goes on to the normal routing',
      (tester) async {
    await tester.pumpWidget(app(updateRequired: false));
    await tester.pumpAndSettle();
    expect(find.byType(UpdateScreen), findsNothing);
    expect(find.byType(RegisterScreen), findsOneWidget);
  });
}

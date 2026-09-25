import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rezervator/features/auth/auth_gate.dart';
import 'package:rezervator/features/auth/login_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// An expired or used magic link reaches the app as an error on
/// onAuthStateChange — supabase_flutter's notifyException, on a
/// ReplaySubject. The sign-in screen has to say so at once, not after
/// Riverpod's automatic retries (10 of them, ~38 s) during which the gate
/// showed only the splash.
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

  testWidgets('an expired magic link shows the sign-in screen with why, at once',
      (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: AuthGate())),
    );
    await tester.pump();
    expect(find.byType(LoginScreen), findsOneWidget);

    // ignore: invalid_use_of_internal_member
    Supabase.instance.client.auth.notifyException(const AuthException(
      'Email link is invalid or has expired',
      statusCode: 'otp_expired',
      code: 'access_denied',
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(LoginScreen), findsOneWidget);
    expect(find.textContaining('Odkaz už neplatí'), findsOneWidget);
  });
}

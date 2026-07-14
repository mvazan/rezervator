/// Build-time configuration. Values come from --dart-define (see SETUP.md):
///
///   flutter run \
///     --dart-define=SUPABASE_URL=https://xyz.supabase.co \
///     --dart-define=SUPABASE_ANON_KEY=eyJ... \
///     --dart-define=FIREBASE_API_KEY=... \
///     --dart-define=FIREBASE_APP_ID=... \
///     --dart-define=FIREBASE_SENDER_ID=... \
///     --dart-define=FIREBASE_PROJECT_ID=...
///
/// Supabase values are required; Firebase values are optional — without them
/// the app runs fine, just without push notifications.
library;

import 'package:flutter/foundation.dart' show kIsWeb;

class AppConfig {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  static const firebaseApiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const firebaseAppId = String.fromEnvironment('FIREBASE_APP_ID');
  static const firebaseSenderId = String.fromEnvironment('FIREBASE_SENDER_ID');
  static const firebaseProjectId =
      String.fromEnvironment('FIREBASE_PROJECT_ID');

  /// Sentry crash/error reporting DSN. Optional — without it Sentry stays off
  /// (debug builds run clean). The DSN is a public client key, safe to bake in.
  static const sentryDsn = String.fromEnvironment('SENTRY_DSN');

  /// Where the magic-link e-mail redirects back to: the current web origin+path
  /// on web builds (works on GitHub Pages subpaths), the Android deep link
  /// elsewhere. Both must be registered in Supabase dashboard redirect URLs.
  static String get authRedirectUrl => kIsWeb
      ? Uri.base.origin + Uri.base.path
      : 'cz.kuzelky.rezervator://login-callback';

  /// Demo account for the Google Play review team. The app has no password
  /// login (e-mail magic link only), so a reviewer can't receive a code. When
  /// this exact e-mail is entered on the login screen, the app asks for the
  /// fixed access code below and then signs in with a password instead of
  /// sending an e-mail. The password is NEVER in the codebase — it comes from
  /// --dart-define=DEMO_PASSWORD (a GitHub secret baked in at build time), so
  /// the bypass is inert unless a build carries the secret. Real users are
  /// unaffected: any other e-mail goes through the normal magic-link flow.
  static const demoEmail = 'playreview@vvrky.cz';
  static const demoPassword = String.fromEnvironment('DEMO_PASSWORD');

  /// The code the reviewer types (public, not a secret — it only gates the
  /// password path; the password itself is what actually authenticates).
  static const demoAccessCode = '126533';

  /// Demo login is available only when a password was baked in (release builds
  /// carrying the secret) and the entered e-mail matches the demo account.
  static bool isDemoLogin(String email) =>
      demoPassword.isNotEmpty &&
      email.trim().toLowerCase() == demoEmail.toLowerCase();

  static bool get hasSupabase =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  static bool get hasSentry => sentryDsn.isNotEmpty;

  static bool get hasFirebase =>
      firebaseApiKey.isNotEmpty &&
      firebaseAppId.isNotEmpty &&
      firebaseSenderId.isNotEmpty &&
      firebaseProjectId.isNotEmpty;
}

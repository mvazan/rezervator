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

  /// Where the magic-link e-mail redirects back to: the current web origin+path
  /// on web builds (works on GitHub Pages subpaths), the Android deep link
  /// elsewhere. Both must be registered in Supabase dashboard redirect URLs.
  static String get authRedirectUrl => kIsWeb
      ? Uri.base.origin + Uri.base.path
      : 'cz.kuzelky.rezervator://login-callback';

  static bool get hasSupabase =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  static bool get hasFirebase =>
      firebaseApiKey.isNotEmpty &&
      firebaseAppId.isNotEmpty &&
      firebaseSenderId.isNotEmpty &&
      firebaseProjectId.isNotEmpty;
}

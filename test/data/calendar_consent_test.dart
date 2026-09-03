import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/config.dart';
import 'package:rezervator/data/providers.dart';

void main() {
  test('the calendar feature is dormant without a baked-in GOOGLE_CLIENT_ID',
      () {
    // Tests build without --dart-define=GOOGLE_CLIENT_ID.
    expect(AppConfig.googleClientId, isEmpty);
    expect(AppConfig.hasGoogleCalendar, isFalse);
    expect(AppConfig.calendarRedirectUri,
        endsWith('/functions/v1/calendar-oauth-callback'));
  });

  group('calendarConsentUri', () {
    final uri = calendarConsentUri(nonce: 'a1b2c3');

    test("targets Google's OAuth 2.0 endpoint", () {
      expect(uri.scheme, 'https');
      expect(uri.host, 'accounts.google.com');
      expect(uri.path, '/o/oauth2/v2/auth');
    });

    test('runs the code flow with the client id and callback from AppConfig',
        () {
      expect(uri.queryParameters['response_type'], 'code');
      expect(uri.queryParameters['client_id'], AppConfig.googleClientId);
      expect(uri.queryParameters['redirect_uri'],
          AppConfig.calendarRedirectUri);
    });

    test('asks only for identity plus the app-created-calendar scope', () {
      expect(
        uri.queryParameters['scope'],
        'openid email https://www.googleapis.com/auth/calendar.app.created',
      );
    });

    test('offline access with forced consent, so a refresh token comes back',
        () {
      expect(uri.queryParameters['access_type'], 'offline');
      expect(uri.queryParameters['prompt'], 'consent');
    });

    test('carries the one-time nonce as the OAuth state', () {
      expect(uri.queryParameters['state'], 'a1b2c3');
      expect(calendarConsentUri(nonce: 'other').queryParameters['state'],
          'other');
    });
  });
}

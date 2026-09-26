import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/auth_redirect.dart';

void main() {
  group('authErrorRedirect', () {
    test('a failed magic link on the web (hash fragment as the location) '
        'goes to the sign-in screen', () {
      expect(
        authErrorRedirect(Uri.parse(
            '/error=access_denied&error_code=otp_expired&error_description='
            'Email+link+is+invalid+or+has+expired')),
        '/',
      );
      expect(authErrorRedirect(Uri.parse('/error_code=otp_expired')), '/');
    });

    test('a successful magic link leaves "#sb" behind — supabase_flutter '
        'strips the tokens but not GoTrue\'s own sb marker — and that goes '
        'home too, not to "Page Not Found"', () {
      for (final location in ['/sb', '/sb=', '/sb&x=1', '/access_token=abc',
          '/type=magiclink']) {
        expect(authErrorRedirect(Uri.parse(location)), '/', reason: location);
      }
    });

    test('real routes stay where they are', () {
      for (final location in [
        '/',
        '/kiosk-login',
        '/prehled/tj-sokol-brno-iv',
        '/?code=abc',
        '/?error=access_denied&error_code=otp_expired',
        '/sbirka',
      ]) {
        expect(authErrorRedirect(Uri.parse(location)), isNull,
            reason: location);
      }
    });
  });
}

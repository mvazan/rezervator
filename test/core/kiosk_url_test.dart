import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/kiosk_url.dart';

void main() {
  group('kioskUrlFrom', () {
    test('the app at the root gives the plain kiosk address', () {
      expect(kioskUrlFrom(Uri.parse('https://rezervator.online/')),
          'https://rezervator.online/#/kiosk-login');
      // No trailing slash on the way in, one on the way out.
      expect(kioskUrlFrom(Uri.parse('https://rezervator.online')),
          'https://rezervator.online/#/kiosk-login');
    });

    test('an alley hosting its own copy keeps its sub-path', () {
      expect(kioskUrlFrom(Uri.parse('https://kuzelky.example/rezervator/')),
          'https://kuzelky.example/rezervator/#/kiosk-login');
    });

    // Uri.base is whatever page the admin is on when they open this screen,
    // so the hash route and any query string have to fall away — otherwise
    // the address would carry the admin's own position in the app.
    test('the current route and query are dropped', () {
      expect(kioskUrlFrom(Uri.parse('https://rezervator.online/#/kiosk-login')),
          'https://rezervator.online/#/kiosk-login');
      expect(kioskUrlFrom(Uri.parse('https://rezervator.online/?code=abc#/')),
          'https://rezervator.online/#/kiosk-login');
      expect(
          kioskUrlFrom(
              Uri.parse('https://kuzelky.example/rezervator/?x=1#/profil')),
          'https://kuzelky.example/rezervator/#/kiosk-login');
    });

    test('a local preview keeps its port', () {
      expect(kioskUrlFrom(Uri.parse('http://localhost:8765/#/')),
          'http://localhost:8765/#/kiosk-login');
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/config.dart';

void main() {
  group('AppConfig demo bypass', () {
    test('is inert without a baked-in DEMO_PASSWORD', () {
      // Tests build without --dart-define=DEMO_PASSWORD, so the demo login
      // must stay off even for the exact demo e-mail — the guard hangs on
      // the password being present, not on the address alone.
      expect(AppConfig.demoPassword, isEmpty);
      expect(AppConfig.isDemoLogin(AppConfig.demoEmail), isFalse);
      expect(AppConfig.isDemoLogin('someone@else.cz'), isFalse);
    });

    test('demo access code is the fixed review gate', () {
      expect(AppConfig.demoAccessCode, '126533');
      expect(AppConfig.demoEmail, 'playreview@vvrky.cz');
    });
  });
}

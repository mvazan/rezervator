import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/push/push.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('Push.listenForSignIn', () {
    test('an expired magic link on the auth stream is not an uncaught error',
        () async {
      final uncaught = <Object>[];
      await runZonedGuarded(() async {
        final changes = StreamController<AuthState>.broadcast();
        final sub = Push.listenForSignIn(changes.stream, () {});
        changes.addError(const AuthException(
          'Email link is invalid or has expired',
          statusCode: 'otp_expired',
          code: 'access_denied',
        ));
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();
        await changes.close();
      }, (error, _) => uncaught.add(error));

      expect(uncaught, isEmpty);
    });

    test('a sign-in still saves the token', () async {
      final changes = StreamController<AuthState>.broadcast();
      var signedIn = 0;
      final sub = Push.listenForSignIn(changes.stream, () => signedIn++);

      changes
        ..add(const AuthState(AuthChangeEvent.signedIn, null))
        ..add(const AuthState(AuthChangeEvent.tokenRefreshed, null));
      await Future<void>.delayed(Duration.zero);

      expect(signedIn, 1);
      await sub.cancel();
      await changes.close();
    });
  });
}

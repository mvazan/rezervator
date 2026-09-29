import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/push/push.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('Push.listenForAuth', () {
    test('an expired magic link on the auth stream is not an uncaught error',
        () async {
      final uncaught = <Object>[];
      await runZonedGuarded(() async {
        final changes = StreamController<AuthState>.broadcast();
        final sub = Push.listenForAuth(changes.stream,
            onSignedIn: () {}, onSignedOut: () {});
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
      final sub = Push.listenForAuth(changes.stream,
          onSignedIn: () => signedIn++, onSignedOut: () {});

      changes
        ..add(const AuthState(AuthChangeEvent.signedIn, null))
        ..add(const AuthState(AuthChangeEvent.tokenRefreshed, null));
      await Future<void>.delayed(Duration.zero);

      expect(signedIn, 1);
      await sub.cancel();
      await changes.close();
    });

    // A session that ends — signed out here, or expired and dropped by
    // supabase — leaves the device without an account, so its token must
    // go: FCM would keep delivering to it whatever a profile still holds,
    // and the next account would register the very same token.
    test('a sign-out forgets the token', () async {
      final changes = StreamController<AuthState>.broadcast();
      var signedIn = 0;
      var signedOut = 0;
      final sub = Push.listenForAuth(changes.stream,
          onSignedIn: () => signedIn++, onSignedOut: () => signedOut++);

      changes
        ..add(const AuthState(AuthChangeEvent.signedOut, null))
        ..add(const AuthState(AuthChangeEvent.initialSession, null))
        ..add(const AuthState(AuthChangeEvent.tokenRefreshed, null));
      await Future<void>.delayed(Duration.zero);

      expect(signedOut, 1);
      expect(signedIn, 0);
      await sub.cancel();
      await changes.close();
    });
  });
}

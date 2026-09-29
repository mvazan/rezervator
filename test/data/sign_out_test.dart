import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rezervator/data/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Sign-out hands this device's push token back while the session can still
/// write the profile. notify pushes to every profile holding a token, so a
/// token left behind kept delivering the signed-out account's notifications
/// to the phone (0052 is the database side). Pinned at the HTTP layer: the
/// order (the write needs the JWT the sign-out throws away) and the filter
/// (only this device's token — the account's other phone keeps its own).
void main() {
  const uid = '10000000-0000-0000-0000-000000000001';
  late List<http.Request> requests;

  /// How PostgREST answers the profiles write; a test swaps in a failure.
  late Future<http.Response> Function(http.Request) profilesAnswer;

  http.Response json(http.Request request, Object body, [int status = 200]) =>
      http.Response(jsonEncode(body), status,
          headers: {'content-type': 'application/json'}, request: request);

  /// A password sign-in's answer: a session whose access token GoTrue can
  /// read the expiry from.
  Map<String, dynamic> session() {
    String part(Map<String, dynamic> m) =>
        base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
    final exp = DateTime.now().add(const Duration(hours: 1));
    final jwt = '${part({'alg': 'HS256', 'typ': 'JWT'})}.'
        '${part({
          'sub': uid,
          'role': 'authenticated',
          'exp': exp.millisecondsSinceEpoch ~/ 1000,
        })}.signature';
    return {
      'access_token': jwt,
      'token_type': 'bearer',
      'expires_in': 3600,
      'refresh_token': 'refresh',
      'user': {
        'id': uid,
        'aud': 'authenticated',
        'role': 'authenticated',
        'email': 'hrac@example.com',
        'app_metadata': <String, dynamic>{},
        'user_metadata': <String, dynamic>{},
        'created_at': '2026-01-01T00:00:00Z',
      },
    };
  }

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final mock = MockClient((request) async {
      requests.add(request);
      return switch (request.url.path) {
        '/auth/v1/token' => json(request, session()),
        '/auth/v1/logout' => http.Response('', 204, request: request),
        '/rest/v1/profiles' => profilesAnswer(request),
        _ => json(request, const []),
      };
    });
    await Supabase.initialize(
      url: 'http://localhost:54321',
      publishableKey: 'test-anon-key',
      httpClient: mock,
      authOptions: const FlutterAuthClientOptions(
        detectSessionInUri: false,
        localStorage: EmptyLocalStorage(),
      ),
    );
  });

  setUp(() async {
    requests = [];
    profilesAnswer = (request) async => http.Response('', 204, request: request);
    await Supabase.instance.client.auth
        .signInWithPassword(email: 'hrac@example.com', password: 'heslo');
    expect(currentUserId, uid);
  });

  /// Paths of the requests since [since], in order.
  List<String> pathsSince(int since) =>
      [for (final r in requests.skip(since)) r.url.path];

  test('clears the token this device registered, then signs out', () async {
    await Api.updateFcmToken('tok-this-phone');
    final since = requests.length;

    await Api.signOut();

    expect(pathsSince(since), ['/rest/v1/profiles', '/auth/v1/logout']);
    final handBack = requests[since];
    expect(handBack.method, 'PATCH');
    expect(handBack.url.queryParameters, {
      'id': 'eq.$uid',
      // Only while it is still this device's: if the account's other phone
      // registered since, that phone keeps its pushes.
      'fcm_token': 'eq.tok-this-phone',
    });
    expect(jsonDecode(handBack.body), {'fcm_token': null});
    expect(currentUserId, isNull);
  });

  test('a device with no token (web, no Firebase) leaves the profile alone',
      () async {
    final since = requests.length;

    await Api.signOut();

    // No write at all: an unfiltered clear would cut off the phone this
    // account is still signed in on.
    expect(pathsSince(since), ['/auth/v1/logout']);
    expect(currentUserId, isNull);
  });

  test('the next sign-in does not hand back the previous account\'s token',
      () async {
    await Api.updateFcmToken('tok-this-phone');
    await Api.signOut();
    await Supabase.instance.client.auth
        .signInWithPassword(email: 'hrac@example.com', password: 'heslo');
    final since = requests.length;

    await Api.signOut();

    expect(pathsSince(since), ['/auth/v1/logout']);
  });

  test('a refused write still signs out', () async {
    await Api.updateFcmToken('tok-this-phone');
    profilesAnswer = (request) async =>
        json(request, {'message': 'boom'}, 500);

    await Api.signOut();

    expect(requests.last.url.path, '/auth/v1/logout');
    expect(currentUserId, isNull);
  });

  test('offline: the write failing on the network still signs out', () async {
    await Api.updateFcmToken('tok-this-phone');
    profilesAnswer =
        (_) async => throw http.ClientException('Failed host lookup');

    await Api.signOut();

    expect(requests.last.url.path, '/auth/v1/logout');
    expect(currentUserId, isNull);
  });

  test('a write that never comes back gives up and signs out', () async {
    await Api.updateFcmToken('tok-this-phone');
    profilesAnswer = (_) => Completer<http.Response>().future;

    await Api.signOut().timeout(
      fcmHandBackTimeout + const Duration(seconds: 2),
      onTimeout: () => fail('sign-out waited on the hanging write'),
    );

    expect(requests.last.url.path, '/auth/v1/logout');
    expect(currentUserId, isNull);
  });
}

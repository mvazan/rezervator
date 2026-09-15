import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rezervator/data/backend_reachable.dart';

void main() {
  http.Client answering(int status) =>
      MockClient((_) async => http.Response('{}', status));

  http.Client throwing(Object error) => MockClient((_) async => throw error);

  group('backendReachable', () {
    test('an answer means the network path works', () async {
      expect(await backendReachable(client: answering(200)), isTrue);
    });

    test('a refusal is still an answer — 401 is not offline', () async {
      // The probe measures the ROUTE, not the credentials. A rotated key or
      // a moved endpoint would otherwise report the player as offline while
      // their connection is perfectly fine.
      expect(await backendReachable(client: answering(401)), isTrue);
      expect(await backendReachable(client: answering(404)), isTrue);
    });

    test('a broken backend counts as offline — the data will not load '
        'either way', () async {
      expect(await backendReachable(client: answering(502)), isFalse);
      expect(await backendReachable(client: answering(503)), isFalse);
    });

    test('a dead network is offline, whichever way it fails', () async {
      expect(
        await backendReachable(
            client: throwing(const SocketException('no route to host'))),
        isFalse,
      );
      expect(
        await backendReachable(client: throwing(http.ClientException('failed'))),
        isFalse,
      );
    });

    test('a request that never comes back is offline, not a hang', () async {
      // Without the timeout the whole poll would stall behind one request on
      // a network that accepts the connection and then says nothing.
      final hanging = MockClient((_) => Completer<http.Response>().future);
      expect(
        await backendReachable(client: hanging).timeout(
          probeTimeout + const Duration(seconds: 2),
          onTimeout: () => fail('the probe did not time out on its own'),
        ),
        isFalse,
      );
    });
  });

  group('probeDue', () {
    final t0 = DateTime(2026, 9, 15, 9, 0);

    test('the first tick always asks', () {
      expect(probeDue(now: t0, lastProbe: null, offline: false), isTrue);
    });

    test('while deciding it asks on every tick', () {
      expect(
        probeDue(
            now: t0.add(probeWhileDeciding), lastProbe: t0, offline: false),
        isTrue,
      );
      expect(
        probeDue(
            now: t0.add(const Duration(seconds: 1)),
            lastProbe: t0,
            offline: false),
        isFalse,
      );
    });

    test('once the banner is up it asks far less often', () {
      // The socket redials on its own, so a recovery is noticed without the
      // probe; this is only a backstop and must not hammer a dead network.
      expect(
        probeDue(
            now: t0.add(probeWhileDeciding), lastProbe: t0, offline: true),
        isFalse,
      );
      expect(
        probeDue(now: t0.add(probeWhileOffline), lastProbe: t0, offline: true),
        isTrue,
      );
    });
  });
}

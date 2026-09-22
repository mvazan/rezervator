import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/cache.dart';
import 'package:rezervator/data/live_refresh.dart';
import 'package:rezervator/data/optimistic.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LiveRefresh.resetThrottle();
  });

  test('RowCache round-trips rows per uid and clears on demand', () async {
    const rows = [
      {'id': 'b1', 'starts_at': '16:00:00'},
      {'id': 'b2', 'starts_at': '17:00:00'},
    ];
    RowCache.write('u1', 'time_blocks', rows);
    // write is fire-and-forget; give its future a tick.
    await Future<void>.delayed(Duration.zero);

    expect(await RowCache.read('u1', 'time_blocks'), rows);
    // A different uid sees nothing — keys are uid-scoped.
    expect(await RowCache.read('u2', 'time_blocks'), isNull);

    await RowCache.clear('u1');
    expect(await RowCache.read('u1', 'time_blocks'), isNull);
  });

  test('cachedRows replays the cache first, then live rows win and persist',
      () async {
    const cached = [
      {'id': 'old'},
    ];
    const fresh = [
      {'id': 'new'},
    ];
    RowCache.write('u1', 'clubs', cached);
    await Future<void>.delayed(Duration.zero);

    final live = StreamController<List<Map<String, dynamic>>>();
    final emissions = <List<Map<String, dynamic>>>[];
    final sub = cachedRows('u1', 'clubs', () => live.stream).listen(emissions.add);

    await Future<void>.delayed(Duration.zero);
    expect(emissions, [cached]); // cache unblocks the UI immediately

    live.add(fresh);
    await Future<void>.delayed(Duration.zero);
    expect(emissions, [cached, fresh]);

    // The live emission overwrote the cache for the next launch (the write
    // is fire-and-forget — give it a few event-loop turns).
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await RowCache.read('u1', 'clubs'), fresh);

    await sub.cancel();
    await live.close();
  });

  test('cachedRows keeps the cached data when the live stream errors '
      '(offline: no error surfaces, a retry is scheduled)', () async {
    const cached = [
      {'id': 'old'},
    ];
    RowCache.write('u1', 'blocks', cached);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    var subscriptions = 0;
    Stream<List<Map<String, dynamic>>> failingLive() async* {
      subscriptions++;
      throw Exception('offline: initial fetch failed');
    }

    final emissions = <List<Map<String, dynamic>>>[];
    Object? error;
    final sub = cachedRows('u1', 'blocks', failingLive)
        .listen(emissions.add, onError: (Object e) => error = e);

    await Future<void>.delayed(const Duration(milliseconds: 20));
    // The cached rows came through and the error was swallowed — the UI
    // keeps its last-known state instead of flipping to an error screen.
    expect(emissions, [cached]);
    expect(error, isNull);
    expect(subscriptions, 1); // first attempt made; retry waits on backoff

    // Not awaited: the generator only honors cancellation at its next yield
    // point, which sits behind the 5s retry backoff.
    unawaited(sub.cancel());
  });

  test('cachedRows with no cache rethrows the first live error', () async {
    Stream<List<Map<String, dynamic>>> failingLive() async* {
      throw Exception('offline');
    }

    Object? error;
    final sub = cachedRows('u9', 'blocks', failingLive)
        .listen((_) {}, onError: (Object e) => error = e);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(error, isNotNull);
    unawaited(sub.cancel());
  });

  test('cachedRows with an empty cache and a silent stream emits nothing '
      '(no crash, no phantom rows)', () async {
    final live = StreamController<List<Map<String, dynamic>>>();
    final emissions = <List<Map<String, dynamic>>>[];
    final sub = cachedRows('u1', 'nothing', () => live.stream).listen(emissions.add);
    await Future<void>.delayed(Duration.zero);
    expect(emissions, isEmpty);
    await sub.cancel();
    await live.close();
  });

  test('zavřený živý stream (spadlý socket) neukončí stream obrazovky',
      () async {
    final live = StreamController<List<Map<String, dynamic>>>();
    var done = false;
    final sub = cachedRows('u1', 'blocks', () => live.stream)
        .listen((_) {}, onDone: () => done = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // Supabase zavírá .stream() při ztrátě kanálu čistě, bez chyby.
    await live.close();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(done, isFalse,
        reason: 'ukončený stream = provider zamrzne na starých datech');
    unawaited(sub.cancel());
  });

  test('probuzení appky se přihlásí znovu hned, bez čekání na backoff',
      () async {
    final controllers = <StreamController<List<Map<String, dynamic>>>>[];
    Stream<List<Map<String, dynamic>>> live() {
      final c = StreamController<List<Map<String, dynamic>>>();
      controllers.add(c);
      return c.stream;
    }

    final emissions = <List<Map<String, dynamic>>>[];
    final sub = cachedRows('u1', 'blocks', live).listen(emissions.add);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await controllers.last.close(); // socket spadl, běží backoff
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(controllers, hasLength(1));

    LiveRefresh.request();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(controllers, hasLength(2), reason: 'hned, ne za 5 s');

    controllers.last.add([
      {'id': 'po probuzení'},
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(emissions.last.single['id'], 'po probuzení');
    unawaited(sub.cancel());
  });

  test('probuzení obnoví i stream, který se tváří zdravě (half-open socket)',
      () async {
    final controllers = <StreamController<List<Map<String, dynamic>>>>[];
    Stream<List<Map<String, dynamic>>> live() {
      final c = StreamController<List<Map<String, dynamic>>>();
      controllers.add(c);
      return c.stream;
    }

    final sub = cachedRows('u1', 'blocks', live).listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 20));
    controllers.last.add([
      {'id': 'stará data'},
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(controllers, hasLength(1));

    LiveRefresh.request();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(controllers, hasLength(2));
    unawaited(sub.cancel());
  });

  group('optimistic overlay (optimistic.dart)', () {
    test('a pending write shows up on cachedRows before anything arrives '
        'from live()', () async {
      final live = StreamController<List<Map<String, dynamic>>>();
      final emissions = <List<Map<String, dynamic>>>[];
      final sub =
          cachedRows('u1', 'opt-instant', () => live.stream).listen(emissions.add);
      live.add([
        {'id': 'p1', 'nick': ''},
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(emissions.last.single['nick'], '');

      unawaited(optimisticWrite(
        'u1',
        'opt-instant',
        patchRow('id', 'p1', {'nick': 'Péťa'}),
        () => Completer<void>().future, // never resolves in this test
      ));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(emissions.last.single['nick'], 'Péťa',
          reason: 'no delivery from live() was needed');

      unawaited(sub.cancel());
      await live.close();
    });

    test('a confirmed write re-subscribes THIS stream targetedly — a live '
        'controller error/close on another key is untouched', () async {
      final controllers = <StreamController<List<Map<String, dynamic>>>>[];
      Stream<List<Map<String, dynamic>>> live() {
        final c = StreamController<List<Map<String, dynamic>>>();
        controllers.add(c);
        return c.stream;
      }

      final emissions = <List<Map<String, dynamic>>>[];
      final sub = cachedRows('u1', 'opt-confirmed', live).listen(emissions.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      controllers.last.add([
        {'id': 'p1', 'nick': ''},
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(controllers, hasLength(1));

      await optimisticWrite('u1', 'opt-confirmed',
          patchRow('id', 'p1', {'nick': 'Péťa'}), () async {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // Optimistic patch visible, and the stream targetedly re-subscribed —
      // not waiting on the OLD controller for its own echo.
      expect(emissions.last.single['nick'], 'Péťa');
      expect(controllers, hasLength(2), reason: 'confirmed = re-subscribe now');

      // The server's own row (could differ from what we sent) wins once it
      // arrives on the fresh controller.
      controllers.last.add([
        {'id': 'p1', 'nick': 'Péťa'},
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(emissions.last.single['nick'], 'Péťa');
      expect(applyPending('u1', 'opt-confirmed', const []), const []);

      unawaited(sub.cancel());
      for (final c in controllers) {
        await c.close();
      }
    });

    test('a failed write leaves cachedRows on the last real rows', () async {
      final live = StreamController<List<Map<String, dynamic>>>();
      final emissions = <List<Map<String, dynamic>>>[];
      final sub =
          cachedRows('u1', 'opt-failed', () => live.stream).listen(emissions.add);
      live.add([
        {'id': 'p1', 'nick': ''},
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      await expectLater(
        optimisticWrite('u1', 'opt-failed', patchRow('id', 'p1', {'nick': 'X'}),
            () async => throw Exception('offline')),
        throwsException,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(emissions.last.single['nick'], '');

      unawaited(sub.cancel());
      await live.close();
    });

    test('a confirmed write on one key never re-subscribes a stream on a '
        'different key', () async {
      var subscriptionsA = 0;
      var subscriptionsB = 0;
      final liveControllers = <StreamController<List<Map<String, dynamic>>>>[];
      Stream<List<Map<String, dynamic>>> liveA() {
        subscriptionsA++;
        final c = StreamController<List<Map<String, dynamic>>>();
        liveControllers.add(c);
        return c.stream;
      }

      Stream<List<Map<String, dynamic>>> liveB() {
        subscriptionsB++;
        final c = StreamController<List<Map<String, dynamic>>>();
        liveControllers.add(c);
        return c.stream;
      }

      final subA = cachedRows('u1', 'opt-a', liveA).listen((_) {});
      final subB = cachedRows('u1', 'opt-b', liveB).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(subscriptionsA, 1);
      expect(subscriptionsB, 1);

      await optimisticWrite('u1', 'opt-a', (rows) => rows, () async {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(subscriptionsA, 2, reason: 'confirmed write on A re-subscribes A');
      expect(subscriptionsB, 1, reason: 'B is untouched');

      unawaited(subA.cancel());
      unawaited(subB.cancel());
      for (final c in liveControllers) {
        await c.close();
      }
    });

    test('a confirmed write landing mid-backoff wakes it immediately, not '
        'after the 5s timer', () async {
      final controllers = <StreamController<List<Map<String, dynamic>>>>[];
      Stream<List<Map<String, dynamic>>> live() {
        final c = StreamController<List<Map<String, dynamic>>>();
        controllers.add(c);
        return c.stream;
      }

      final sub = cachedRows('u1', 'opt-backoff', live).listen((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await controllers.last.close(); // socket spadl, běží 5s backoff
      await Future<void>.delayed(const Duration(milliseconds: 20));

      await optimisticWrite(
          'u1', 'opt-backoff', (rows) => rows, () async {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(controllers, hasLength(2), reason: 'hned, ne za 5 s');

      unawaited(sub.cancel());
      for (final c in controllers) {
        await c.close();
      }
    });
  });
}

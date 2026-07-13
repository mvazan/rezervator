import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

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
}

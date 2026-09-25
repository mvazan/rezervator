import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/data/optimistic.dart';

typedef Rows = List<Map<String, dynamic>>;

void main() {
  const uid = 'u1';
  const me = [
    {'id': 'u1', 'notify_before_minutes': <int>[]},
  ];

  Rows withMinutes(List<int> m) => patchRow(
        'id',
        uid,
        {'notify_before_minutes': m},
      )(me);

  /// The overlay over a raw stream the test drives by hand.
  (StreamController<Rows>, List<Rows>, StreamSubscription<Rows>) overlay(
      String name) {
    final raw = StreamController<Rows>();
    final out = <Rows>[];
    final sub = withOptimisticOverlay(uid, name, raw.stream).listen(out.add);
    return (raw, out, sub);
  }

  Future<void> tick() => Future<void>.delayed(Duration.zero);

  test('with nothing pending the rows pass through untouched', () {
    expect(applyPending(uid, 'idle', me), me);
  });

  test('the patch shows the moment the write starts, before it answers',
      () async {
    final (raw, out, sub) = overlay('instant');
    raw.add(me);
    await tick();

    final write = Completer<void>();
    final done = optimisticWrite(uid, 'instant',
        patchRow('id', uid, {'notify_before_minutes': [120]}),
        () => write.future);
    await tick();
    expect(out.last, withMinutes([120]));

    write.complete();
    await done;
    await sub.cancel();
    await raw.close();
  });

  test('an unrelated delivery while the write runs keeps the patch on top',
      () async {
    final (raw, out, sub) = overlay('unrelated');
    raw.add(me);
    await tick();

    final write = Completer<void>();
    final done = optimisticWrite(uid, 'unrelated',
        patchRow('id', uid, {'notify_before_minutes': [120]}),
        () => write.future);
    await tick();

    // The server still has the old list, plus someone else's change.
    raw.add([
      {'id': 'u1', 'notify_before_minutes': <int>[], 'nick': 'Péťa'},
    ]);
    await tick();
    expect(out.last.single['notify_before_minutes'], [120]);
    expect(out.last.single['nick'], 'Péťa');

    write.complete();
    await done;
    await sub.cancel();
    await raw.close();
  });

  test('after success the patch holds until the next delivery, which then '
      'wins — and the stream is asked to re-subscribe', () async {
    final (raw, out, sub) = overlay('confirmed');
    final refreshes = <void>[];
    final refreshSub =
        refreshRequests(uid, 'confirmed').listen(refreshes.add);
    raw.add(me);
    await tick();

    await optimisticWrite(uid, 'confirmed',
        patchRow('id', uid, {'notify_before_minutes': [120]}),
        () async {});
    await tick();
    // No flash back to the old list while the echo is on its way.
    expect(out.last, withMinutes([120]));
    expect(refreshes, hasLength(1));

    // The server's own version (it may have normalised the list) wins.
    raw.add(withMinutes([120, 60]));
    await tick();
    expect(out.last, withMinutes([120, 60]));
    expect(applyPending(uid, 'confirmed', me), me,
        reason: 'the confirmed patch is gone once the server spoke');

    await refreshSub.cancel();
    await sub.cancel();
    await raw.close();
  });

  test('a failed write falls back to the last real rows and rethrows',
      () async {
    final (raw, out, sub) = overlay('failed');
    final refreshes = <void>[];
    final refreshSub = refreshRequests(uid, 'failed').listen(refreshes.add);
    raw.add(me);
    await tick();

    await expectLater(
      optimisticWrite(uid, 'failed',
          patchRow('id', uid, {'notify_before_minutes': [120]}),
          () async => throw Exception('offline')),
      throwsException,
    );
    await tick();
    expect(out.last, me);
    expect(refreshes, isEmpty);

    await refreshSub.cancel();
    await sub.cancel();
    await raw.close();
  });

  test('a newer write on the same key is not undone when the older finishes',
      () async {
    final (raw, out, sub) = overlay('double');
    raw.add(me);
    await tick();

    final first = Completer<void>();
    final second = Completer<void>();
    final firstDone = optimisticWrite(uid, 'double',
        patchRow('id', uid, {'notify_before_minutes': [120]}),
        () => first.future);
    final secondDone = optimisticWrite(uid, 'double',
        patchRow('id', uid, {'notify_before_minutes': [120, 60]}),
        () => second.future);
    await tick();
    expect(out.last, withMinutes([120, 60]));

    // The older one fails — its caller hears about it, the newer patch stays.
    first.completeError(Exception('offline'));
    await expectLater(firstDone, throwsException);
    await tick();
    expect(out.last, withMinutes([120, 60]));

    second.complete();
    await secondDone;
    await sub.cancel();
    await raw.close();
  });

  test('a newer write on another field keeps the older one\'s change on '
      'screen until both are through', () async {
    final (raw, out, sub) = overlay('fields');
    const row = [
      {'id': 'u1', 'show_email': true, 'show_phone': true},
    ];
    raw.add(row);
    await tick();

    final first = Completer<void>();
    final second = Completer<void>();
    final firstDone = optimisticWrite(uid, 'fields',
        patchRow('id', uid, {'show_email': false}), () => first.future);
    final secondDone = optimisticWrite(uid, 'fields',
        patchRow('id', uid, {'show_phone': false}), () => second.future);
    await tick();
    expect(out.last, [
      {'id': 'u1', 'show_email': false, 'show_phone': false},
    ]);

    // The older one's echo arrives first: still both, the newer is pending.
    first.complete();
    await firstDone;
    raw.add([
      {'id': 'u1', 'show_email': false, 'show_phone': true},
    ]);
    await tick();
    expect(out.last, [
      {'id': 'u1', 'show_email': false, 'show_phone': false},
    ]);

    // The newer one is through; its echo takes over.
    second.complete();
    await secondDone;
    raw.add([
      {'id': 'u1', 'show_email': false, 'show_phone': false},
    ]);
    await tick();
    expect(out.last, [
      {'id': 'u1', 'show_email': false, 'show_phone': false},
    ]);
    expect(applyPending(uid, 'fields', row), row,
        reason: 'nothing left pending once the echo came');

    await sub.cancel();
    await raw.close();
  });

  const both = [
    {'id': 'u1', 'show_email': true, 'show_phone': true},
  ];
  Rows row({required bool email, required bool phone}) => [
        {'id': 'u1', 'show_email': email, 'show_phone': phone},
      ];

  test('the newer write failing does not take the older one\'s change with '
      'it; the older, once through, still asks for its echo', () async {
    final (raw, out, sub) = overlay('newerFails');
    final refreshes = <void>[];
    final refreshSub =
        refreshRequests(uid, 'newerFails').listen(refreshes.add);
    raw.add(both);
    await tick();

    final older = Completer<void>();
    final newer = Completer<void>();
    final olderDone = optimisticWrite(uid, 'newerFails',
        patchRow('id', uid, {'show_email': false}), () => older.future);
    final newerDone = optimisticWrite(uid, 'newerFails',
        patchRow('id', uid, {'show_phone': false}), () => newer.future);
    await tick();
    expect(out.last, row(email: false, phone: false));

    newer.completeError(Exception('offline'));
    await expectLater(newerDone, throwsException);
    await tick();
    expect(out.last, row(email: false, phone: true),
        reason: 'only the failed change goes');

    older.complete();
    await olderDone;
    await tick();
    expect(refreshes, hasLength(1), reason: 'the older asks for its echo');
    raw.add(row(email: false, phone: true));
    await tick();
    expect(out.last, row(email: false, phone: true));
    expect(applyPending(uid, 'newerFails', both), both);

    await refreshSub.cancel();
    await sub.cancel();
    await raw.close();
  });

  test('the newer write settling first leaves the older, still running, on '
      'screen', () async {
    final (raw, out, sub) = overlay('newerFirst');
    raw.add(both);
    await tick();

    final older = Completer<void>();
    final olderDone = optimisticWrite(uid, 'newerFirst',
        patchRow('id', uid, {'show_email': false}), () => older.future);
    await optimisticWrite(uid, 'newerFirst',
        patchRow('id', uid, {'show_phone': false}), () async {});
    // The newer one's echo, before the older one reached the server.
    raw.add(row(email: true, phone: false));
    await tick();
    expect(out.last, row(email: false, phone: false));

    older.complete();
    await olderDone;
    raw.add(row(email: false, phone: false));
    await tick();
    expect(out.last, row(email: false, phone: false));
    expect(applyPending(uid, 'newerFirst', both), both);

    await sub.cancel();
    await raw.close();
  });

  test('a failed older write leaves the screen at once, while the newer '
      'stays', () async {
    final (raw, out, sub) = overlay('olderFails');
    raw.add(both);
    await tick();

    final older = Completer<void>();
    final newer = Completer<void>();
    final olderDone = optimisticWrite(uid, 'olderFails',
        patchRow('id', uid, {'show_email': false}), () => older.future);
    final newerDone = optimisticWrite(uid, 'olderFails',
        patchRow('id', uid, {'show_phone': false}), () => newer.future);
    await tick();

    older.completeError(Exception('offline'));
    await expectLater(olderDone, throwsException);
    await tick();
    expect(out.last, row(email: true, phone: false));

    newer.complete();
    await newerDone;
    await sub.cancel();
    await raw.close();
  });

  test('signals stay on their own key', () async {
    final changes = <void>[];
    final refreshes = <void>[];
    final a = pendingChanges(uid, 'other').listen(changes.add);
    final b = refreshRequests(uid, 'other').listen(refreshes.add);

    await optimisticWrite(uid, 'mine', (rows) => rows, () async {});
    await tick();
    expect(changes, isEmpty);
    expect(refreshes, isEmpty);

    await a.cancel();
    await b.cancel();
  });

  group('patchRow', () {
    test('patches the matching row only', () {
      final rows = [
        {'id': 'a', 'x': 1, 'y': 1},
        {'id': 'b', 'x': 1, 'y': 1},
      ];
      expect(patchRow('id', 'b', {'x': 2})(rows), [
        {'id': 'a', 'x': 1, 'y': 1},
        {'id': 'b', 'x': 2, 'y': 1},
      ]);
    });

    test('no matching row leaves the rows as they are', () {
      final rows = [
        {'id': 'a', 'x': 1},
      ];
      expect(patchRow('id', 'z', {'x': 2})(rows), rows);
    });
  });

  group('upsertOrDeleteRows', () {
    String team(Map<String, dynamic> r) => r['team'] as String;
    final rows = [
      {'team': 'A', 'color_id': 1},
      {'team': 'B', 'color_id': 2},
      {'team': 'C', 'color_id': 3},
    ];

    test('replaces an existing row without doubling it', () {
      final out = upsertOrDeleteRows(
        matchKey: team,
        upserts: {
          'B': {'team': 'B', 'color_id': 9},
        },
        deletes: const {},
      )(rows);
      expect(out, hasLength(3));
      expect(out.where((r) => r['team'] == 'B').single['color_id'], 9);
    });

    test('adds a missing row, drops a deleted one, leaves the rest', () {
      final out = upsertOrDeleteRows(
        matchKey: team,
        upserts: {
          'D': {'team': 'D', 'color_id': 4},
        },
        deletes: {'A'},
      )(rows);
      expect(out.map(team).toSet(), {'B', 'C', 'D'});
      expect(out.where((r) => r['team'] == 'C').single['color_id'], 3);
    });
  });
}

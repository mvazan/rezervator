import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'live_refresh.dart';

/// Tiny JSON row cache behind the offline read-only mode: every data stream
/// writes its latest rows here and replays them as its first emission on the
/// next launch, so a signed-in user with no network still sees the last
/// known schedule instead of an infinite splash.
///
/// Keys are uid-scoped (`cache.{uid}.{name}`) so a shared device never leaks
/// another account's snapshot.
class RowCache {
  RowCache._();

  static String _key(String uid, String name) => 'cache.$uid.$name';

  /// Last cached rows for [name], or null when nothing was stored yet or the
  /// stored JSON is unreadable (treated as a cache miss, never an error).
  static Future<List<Map<String, dynamic>>?> read(
      String uid, String name) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(uid, name));
      if (raw == null) return null;
      final decoded = jsonDecode(raw) as List;
      return [for (final row in decoded) (row as Map).cast<String, dynamic>()];
    } catch (_) {
      return null;
    }
  }

  /// Fire-and-forget write; failures only cost the next offline launch.
  static void write(String uid, String name, List<Map<String, dynamic>> rows) {
    Future(() async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_key(uid, name), jsonEncode(rows));
      } catch (_) {
        // Best effort only.
      }
    });
  }

  /// Drops every cached row set of [uid] — called on sign-out.
  static Future<void> clear(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final prefix = 'cache.$uid.';
      for (final key in prefs.getKeys().where((k) => k.startsWith(prefix))) {
        await prefs.remove(key);
      }
    } catch (_) {
      // Best effort only.
    }
  }
}

/// Replays the cached rows for [name] first (when any), then follows the
/// [live] supabase stream, persisting each emission.
///
/// [live] is a FACTORY because supabase's `.stream()` addErrors AND CLOSES
/// when its initial PostgREST fetch fails (i.e. within ~100ms offline) — a
/// closed stream would otherwise leave the provider stale until restart.
/// Error policy: once ANYTHING was emitted (cache or live), errors are
/// swallowed and the subscription retries with 5/10/30s backoff, so the UI
/// keeps showing the last known state and self-heals when the network
/// returns; with nothing emitted yet the first error rethrows, so the
/// existing error screens (with their retry buttons) still work for
/// cache-less users.
Stream<List<Map<String, dynamic>>> cachedRows(
  String uid,
  String name,
  Stream<List<Map<String, dynamic>>> Function() live,
) async* {
  final cached = await RowCache.read(uid, name);
  var emitted = cached != null;
  if (cached != null) yield cached;

  var attempt = 0;
  while (true) {
    var woke = false;
    // yield* (not `await for`): consumer cancellation only terminates an
    // async* generator at a yield point, so an await-for loop would leave
    // the generator (and its supabase channel) alive after dispose.
    yield* _untilWake(live(), onWake: () => woke = true).map((rows) {
      attempt = 0;
      emitted = true;
      RowCache.write(uid, name, rows);
      return rows;
    }).handleError((Object e) {
      // Swallowing keeps the last-known state on screen; the throw path
      // forwards the error to cache-less consumers (their error screens
      // still need it).
      if (!emitted) throw e;
    });

    // The app came back to the foreground: re-subscribe right away. A fresh
    // subscription re-reads the table over HTTP, so the screen catches up
    // even when realtime is still limping — and it is the only cure for a
    // socket that looks alive but delivers nothing (half-open after the
    // phone slept).
    if (woke) {
      attempt = 0;
      continue;
    }

    // An error and a clean close mean the same thing here: the channel is
    // gone. Supabase closes .stream() cleanly when its realtime channel
    // does (and the socket is dropped on purpose whenever the app goes to
    // the background), so returning would leave the screen frozen on stale
    // rows until a restart.
    attempt++;
    final delay = switch (attempt) { 1 => 5, 2 => 10, _ => 30 };
    await _sleepOrWake(Duration(seconds: delay));
  }
}

/// [source] until it ends on its own — or until the app wakes up, whichever
/// comes first ([onWake] then tells the caller which of the two it was).
Stream<T> _untilWake<T>(Stream<T> source, {required void Function() onWake}) {
  final out = StreamController<T>();
  StreamSubscription<T>? src;
  StreamSubscription<void>? wake;

  Future<void> stop() async {
    await wake?.cancel();
    wake = null;
    await src?.cancel();
    src = null;
    if (!out.isClosed) await out.close();
  }

  out.onListen = () {
    src = source.listen(
      (data) {
        if (!out.isClosed) out.add(data);
      },
      onError: (Object e, StackTrace st) {
        if (!out.isClosed) out.addError(e, st);
      },
      onDone: stop,
    );
    wake = LiveRefresh.stream.listen((_) {
      onWake();
      stop();
    });
  };
  out.onCancel = stop;
  return out.stream;
}

/// Waits out the retry backoff — but no longer than the next wake-up.
Future<void> _sleepOrWake(Duration delay) async {
  final done = Completer<void>();
  void finish() {
    if (!done.isCompleted) done.complete();
  }

  final timer = Timer(delay, finish);
  final wake = LiveRefresh.stream.listen((_) => finish());
  try {
    await done.future;
  } finally {
    timer.cancel();
    await wake.cancel();
  }
}

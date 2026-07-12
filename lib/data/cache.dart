import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

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
/// [live] supabase stream, persisting each emission. The cached first
/// emission is what unblocks the UI offline — supabase's `.stream()` never
/// emits without a connection.
Stream<List<Map<String, dynamic>>> cachedRows(
  String uid,
  String name,
  Stream<List<Map<String, dynamic>>> live,
) async* {
  final cached = await RowCache.read(uid, name);
  if (cached != null) yield cached;
  yield* live.map((rows) {
    RowCache.write(uid, name, rows);
    return rows;
  });
}

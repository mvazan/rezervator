/// Riverpod providers over Supabase.
///
/// Data strategy for a ~50-person alley: stream whole (tiny) tables via
/// Supabase Realtime and filter/join client-side. Reservations will be
/// streamed per-week (Phase 1) so history growth never bloats the stream.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/models.dart';

SupabaseClient get _db => Supabase.instance.client;

final authStateProvider = StreamProvider<AuthState>(
  (ref) => _db.auth.onAuthStateChange,
);

String? get currentUserId => _db.auth.currentUser?.id;

/// The signed-in user's profile row (null before registration).
/// Live — flips when approved or when the role changes.
final myProfileProvider = StreamProvider<Profile?>((ref) {
  final uid = ref.watch(
          authStateProvider.select((a) => a.value?.session?.user.id)) ??
      currentUserId;
  if (uid == null) return Stream.value(null);
  return _db
      .from('profiles')
      .stream(primaryKey: ['id'])
      .eq('id', uid)
      .map((rows) => rows.isEmpty ? null : Profile.fromJson(rows.first));
});

/// All profile rows the caller may see. Admins receive everyone (drives the
/// approval screen); regular players only receive their own row under RLS.
final profilesProvider = StreamProvider<List<Profile>>((ref) {
  return _db.from('profiles').stream(primaryKey: ['id']).map(
      (rows) => rows.map(Profile.fromJson).toList()
        ..sort((a, b) => a.displayName.compareTo(b.displayName)));
});

/// Alley configuration singleton (null until the backend is seeded).
final settingsProvider = StreamProvider<ScheduleSettings?>((ref) {
  return _db.from('schedule_settings').stream(primaryKey: ['id']).map(
      (rows) => rows.isEmpty ? null : ScheduleSettings.fromJson(rows.first));
});

final timeBlocksProvider = StreamProvider<List<TimeBlock>>((ref) {
  return _db.from('time_blocks').stream(primaryKey: ['id']).map(
      (rows) => rows.map(TimeBlock.fromJson).toList()
        ..sort((a, b) => a.position.compareTo(b.position)));
});

/// Approved player names from the `players` view. Views cannot stream —
/// re-read on screen entry (and on kiosk idle reset in Phase 4).
final playersProvider = FutureProvider<List<PlayerName>>((ref) async {
  final rows = await _db.from('players').select();
  return (rows as List)
      .map((r) => PlayerName.fromJson(r as Map<String, dynamic>))
      .toList()
    ..sort((a, b) => a.displayName.compareTo(b.displayName));
});

// ---------------------------------------------------------------------------
// Actions (writes)
// ---------------------------------------------------------------------------

class Api {
  static Future<void> sendMagicLink(String email, String redirectTo) =>
      _db.auth.signInWithOtp(email: email, emailRedirectTo: redirectTo);

  static Future<void> signOut() => _db.auth.signOut();

  static Future<void> registerProfile(String displayName, String club) =>
      _db.rpc('register_profile', params: {
        'p_display_name': displayName,
        'p_club': club,
      });

  static Future<void> approvePlayer(String userId) =>
      _db.rpc('approve_player', params: {'p_user_id': userId});

  static Future<void> updateFcmToken(String? token) async {
    final uid = currentUserId;
    if (uid == null) return;
    await _db.from('profiles').update({'fcm_token': token}).eq('id', uid);
  }

  static Future<void> createReservation({
    required String playerId,
    required Day date,
    required String blockId,
    required int lane,
  }) =>
      _db.rpc('create_reservation', params: {
        'p_player_id': playerId,
        'p_date': date.toSql(),
        'p_block_id': blockId,
        'p_lane': lane,
      });

  static Future<void> cancelReservation(String id, {String note = ''}) =>
      _db.rpc('cancel_reservation', params: {'p_id': id, 'p_note': note});
}

// ---------------------------------------------------------------------------
// Reservation data streams (Phase 1)
// ---------------------------------------------------------------------------

/// Live reservations of one week (family key = that week's Monday).
/// Server-side lower bound keeps the stream bounded as history accumulates;
/// the upper bound and liveness are filtered client-side.
/// autoDispose: each distinct Monday otherwise leaks a permanent realtime
/// channel; autoDispose closes channels for weeks no longer on screen.
final weekReservationsProvider =
    StreamProvider.autoDispose.family<List<Reservation>, Day>((ref, monday) {
  final sunday = monday.addDays(6);
  return _db
      .from('reservations')
      .stream(primaryKey: ['id'])
      .gte('date', monday.toSql())
      .map((rows) => rows
          .map(Reservation.fromJson)
          .where((r) => r.isLive && !r.date.isAfter(sunday))
          .toList());
});

final dayOverridesProvider = StreamProvider<List<DayOverride>>((ref) {
  return _db.from('day_overrides').stream(primaryKey: ['date']).map(
      (rows) => rows.map(DayOverride.fromJson).toList());
});

final matchesProvider = StreamProvider<List<Match>>((ref) {
  return _db.from('matches').stream(primaryKey: ['id']).map(
      (rows) => rows.map(Match.fromJson).toList());
});

final rentalsProvider = StreamProvider<List<Rental>>((ref) {
  return _db.from('rentals').stream(primaryKey: ['id']).map(
      (rows) => rows.map(Rental.fromJson).toList());
});

/// The signed-in player's reservations (all of them; the UI derives the
/// active count via activeReservationCount).
final myActiveReservationsProvider =
    StreamProvider<List<Reservation>>((ref) {
  final uid = ref.watch(
      authStateProvider.select((a) => a.value?.session?.user.id)) ??
      currentUserId;
  if (uid == null) return Stream.value(const []);
  return _db
      .from('reservations')
      .stream(primaryKey: ['id'])
      .eq('player_id', uid)
      .map((rows) => rows.map(Reservation.fromJson).toList());
});

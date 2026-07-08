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

/// The signed-in user's id, tracked through auth changes. Every RLS-protected
/// data stream watches this so it is *recreated* on sign-in.
///
/// Why this matters: `.stream()` fetches its initial snapshot from PostgREST
/// with whatever JWT is current at subscription time, and only re-fetches on a
/// socket reconnect — not on a plain token update. On the OTP-code login path
/// the app is already running with no session, so streams first opened as anon
/// return nothing (RLS) and never refill. Rebuilding them on sign-in reopens
/// each stream under the authenticated JWT. (The magic-link path avoids this
/// because the session exists before any stream is first read.)
final _authUidProvider = Provider<String?>((ref) {
  ref.watch(authStateProvider);
  return currentUserId;
});

/// The signed-in user's profile row (null before registration).
/// Live — flips when approved or when the role changes.
final myProfileProvider = StreamProvider<Profile?>((ref) {
  final uid = ref.watch(_authUidProvider);
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
  if (ref.watch(_authUidProvider) == null) return Stream.value(const []);
  return _db.from('profiles').stream(primaryKey: ['id']).map(
      (rows) => rows.map(Profile.fromJson).toList()
        ..sort((a, b) => a.displayName.compareTo(b.displayName)));
});

/// Alley configuration singleton (null until the backend is seeded).
final settingsProvider = StreamProvider<ScheduleSettings?>((ref) {
  if (ref.watch(_authUidProvider) == null) return Stream.value(null);
  return _db.from('schedule_settings').stream(primaryKey: ['id']).map(
      (rows) => rows.isEmpty ? null : ScheduleSettings.fromJson(rows.first));
});

final timeBlocksProvider = StreamProvider<List<TimeBlock>>((ref) {
  if (ref.watch(_authUidProvider) == null) return Stream.value(const []);
  return _db.from('time_blocks').stream(primaryKey: ['id']).map(
      (rows) => rows.map(TimeBlock.fromJson).toList()
        ..sort((a, b) {
          final byStart = a.startsAt.minutesFromMidnight
              .compareTo(b.startsAt.minutesFromMidnight);
          return byStart != 0 ? byStart : a.position.compareTo(b.position);
        }));
});

/// Approved player names from the `players` view. Views cannot stream —
/// re-read on screen entry (and on kiosk idle reset in Phase 4).
final playersProvider = FutureProvider<List<PlayerName>>((ref) async {
  if (ref.watch(_authUidProvider) == null) return const [];
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

  /// Fallback for mail apps that drop the code from the magic link
  /// (e.g. Seznam's in-app browser): the e-mail also carries a numeric
  /// code the user can type in.
  static Future<void> verifyEmailOtp(String email, String code) =>
      _db.auth.verifyOTP(type: OtpType.email, email: email, token: code.trim());

  static Future<void> signInWithPassword(String email, String password) =>
      _db.auth.signInWithPassword(email: email, password: password);

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

  // --- admin: settings & blocks ---
  static Future<void> updateSettings({
    required int laneCount,
    required Set<int> trainingWeekdays,
    required int bookingHorizonDays,
    required int maxActiveReservations,
  }) =>
      _db.from('schedule_settings').update({
        'lane_count': laneCount,
        'training_weekdays': trainingWeekdays.toList()..sort(),
        'booking_horizon_days': bookingHorizonDays,
        'max_active_reservations': maxActiveReservations,
      }).eq('id', true);

  static Future<void> addTimeBlock(HourMinute startsAt, HourMinute endsAt, int position) =>
      _db.from('time_blocks').insert({
        'starts_at': startsAt.toSql(),
        'ends_at': endsAt.toSql(),
        'position': position,
      });

  /// Inserts a new inactive "special" block for the day-override custom-times
  /// editor (see [matchSpecialBlocks]) and returns its id.
  static Future<String> addSpecialTimeBlock(
    HourMinute start,
    HourMinute end,
  ) async {
    final row = await _db
        .from('time_blocks')
        .insert({
          'starts_at': start.toSql(),
          'ends_at': end.toSql(),
          'position': start.minutesFromMidnight,
          'active': false,
        })
        .select('id')
        .single();
    return row['id'] as String;
  }

  static Future<void> updateTimeBlock(String id,
          {HourMinute? startsAt, HourMinute? endsAt, int? position, bool? active}) =>
      _db.from('time_blocks').update({
        if (startsAt != null) 'starts_at': startsAt.toSql(),
        if (endsAt != null) 'ends_at': endsAt.toSql(),
        'position': ?position,
        'active': ?active,
      }).eq('id', id);

  /// Delete only works for never-referenced blocks (FK restrict) — callers
  /// fall back to deactivation on failure.
  static Future<void> deleteTimeBlock(String id) =>
      _db.from('time_blocks').delete().eq('id', id);

  // --- admin: day overrides (RPC — cascades reservation cancellations) ---
  static Future<void> setDayOverride({
    required Day date,
    required bool closed,
    String reason = '',
    List<String>? blockIds,
  }) =>
      _db.rpc('set_day_override', params: {
        'p_date': date.toSql(),
        'p_closed': closed,
        'p_reason': reason,
        'p_block_ids': blockIds,
      });

  static Future<void> deleteDayOverride(Day date) =>
      _db.from('day_overrides').delete().eq('date', date.toSql());

  // --- admin: matches ---
  static Future<void> saveMatch({
    String? id,
    required Day date,
    required HourMinute startsAt,
    required HourMinute endsAt,
    String homeTeam = '',
    required String awayTeam,
    int prepMinutes = 0,
    String description = '',
  }) async {
    final row = {
      'date': date.toSql(),
      'starts_at': startsAt.toSql(),
      'ends_at': endsAt.toSql(),
      'home_team': homeTeam,
      'away_team': awayTeam,
      'prep_minutes': prepMinutes,
      'description': description,
      if (id == null) 'created_by': currentUserId!,
    };
    if (id == null) {
      await _db.from('matches').insert(row);
    } else {
      await _db.from('matches').update(row).eq('id', id);
    }
  }

  static Future<void> deleteMatch(String id) =>
      _db.from('matches').delete().eq('id', id);

  // --- admin: rentals ---
  static Future<void> saveRental({
    String? id,
    required String renterName,
    required List<int> lanes,
    Day? date,
    int? weekday,
    required HourMinute startsAt,
    required HourMinute endsAt,
    Day? validFrom,
    Day? validUntil,
    String note = '',
  }) async {
    final row = {
      'renter_name': renterName,
      'lanes': lanes,
      'date': date?.toSql(),
      'weekday': weekday,
      'starts_at': startsAt.toSql(),
      'ends_at': endsAt.toSql(),
      'valid_from': validFrom?.toSql(),
      'valid_until': validUntil?.toSql(),
      'note': note,
      if (id == null) 'created_by': currentUserId!,
    };
    if (id == null) {
      await _db.from('rentals').insert(row);
    } else {
      await _db.from('rentals').update(row).eq('id', id);
    }
  }

  static Future<void> deleteRental(String id) =>
      _db.from('rentals').delete().eq('id', id);

  // --- admin: roles ---
  static Future<void> setRole(String userId, Role role) =>
      _db.rpc('set_role', params: {'p_user_id': userId, 'p_role': role.name});

  // --- admin: nick (board short name) ---
  static Future<void> setNick(String userId, String nick) =>
      _db.rpc('set_nick', params: {'p_user_id': userId, 'p_nick': nick});

  // --- admin: reports ---
  static Future<List<AttendanceRow>> monthlyAttendance(
      int year, int month) async {
    final rows = await _db.rpc('monthly_attendance', params: {
      'p_year': year,
      'p_month': month,
    });
    return (rows as List)
        .map((r) => AttendanceRow.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  // --- admin: stranded-reservation warnings ---
  /// Live reservations from [today] onward, as a light projection (not the
  /// full `Reservation` — this select only needs `date`/`lane`/`block_id`,
  /// and `Reservation.fromJson` requires columns like `id`/`player_id` this
  /// query doesn't fetch). Used by admin screens to warn before a config
  /// change (fewer lanes, a removed weekday, a deactivated block) would
  /// strand future reservations outside the grid.
  static Future<List<StrandableReservation>> futureLiveReservations(
      Day today) async {
    final rows = await _db
        .from('reservations')
        .select('date, lane, block_id')
        .gte('date', today.toSql())
        .isFilter('cancelled_at', null);
    return (rows as List)
        .map((r) => StrandableReservation.fromJson(r as Map<String, dynamic>))
        .toList();
  }
}

/// Light projection of a future live reservation — just enough to detect
/// whether it would fall outside the grid after a config change. See
/// [Api.futureLiveReservations].
class StrandableReservation {
  const StrandableReservation({
    required this.date,
    required this.lane,
    required this.blockId,
  });

  final Day date;
  final int lane;
  final String blockId;

  factory StrandableReservation.fromJson(Map<String, dynamic> json) =>
      StrandableReservation(
        date: Day.parse(json['date'] as String),
        lane: json['lane'] as int,
        blockId: json['block_id'] as String,
      );
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
  if (ref.watch(_authUidProvider) == null) return Stream.value(const []);
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
  if (ref.watch(_authUidProvider) == null) return Stream.value(const []);
  return _db.from('day_overrides').stream(primaryKey: ['date']).map(
      (rows) => rows.map(DayOverride.fromJson).toList());
});

final matchesProvider = StreamProvider<List<Match>>((ref) {
  if (ref.watch(_authUidProvider) == null) return Stream.value(const []);
  return _db.from('matches').stream(primaryKey: ['id']).map(
      (rows) => rows.map(Match.fromJson).toList());
});

final rentalsProvider = StreamProvider<List<Rental>>((ref) {
  if (ref.watch(_authUidProvider) == null) return Stream.value(const []);
  return _db.from('rentals').stream(primaryKey: ['id']).map(
      (rows) => rows.map(Rental.fromJson).toList());
});

/// The signed-in player's reservations (all of them; the UI derives the
/// active count via activeReservationCount).
final myActiveReservationsProvider =
    StreamProvider<List<Reservation>>((ref) {
  final uid = ref.watch(_authUidProvider);
  if (uid == null) return Stream.value(const []);
  return _db
      .from('reservations')
      .stream(primaryKey: ['id'])
      .eq('player_id', uid)
      .map((rows) => rows.map(Reservation.fromJson).toList());
});

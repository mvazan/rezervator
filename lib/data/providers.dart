/// Riverpod providers over Supabase.
///
/// Data strategy for a ~50-person alley: stream whole (tiny) tables via
/// Supabase Realtime and filter/join client-side. Reservations will be
/// streamed per-week (Phase 1) so history growth never bloats the stream.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'cache.dart';

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
  // cachedRows unblocks AuthGate offline: without it this stream never
  // emits without a connection and the app hangs on the splash forever.
  return cachedRows(uid, 'profile',
          () => _db.from('profiles').stream(primaryKey: ['id']).eq('id', uid))
      .map((rows) => rows.isEmpty ? null : Profile.fromJson(rows.first));
});

/// All profile rows the caller may see. Admins receive everyone (drives the
/// approval screen); regular players only receive their own row under RLS.
final profilesProvider = StreamProvider<List<Profile>>((ref) {
  final uid = ref.watch(_authUidProvider);
  if (uid == null) return Stream.value(const []);
  return cachedRows(uid, 'profiles',
          () => _db.from('profiles').stream(primaryKey: ['id']))
      .map(
      (rows) => rows.map(Profile.fromJson).toList()
        ..sort((a, b) => a.displayName.compareTo(b.displayName)));
});

/// Alley configuration singleton (null until the backend is seeded).
/// Alleys offered at registration (id + name; RLS exposes nothing more).
/// Session-gated, not profile-gated — the register screen runs pre-profile.
final tenantsProvider = FutureProvider<List<Tenant>>((ref) async {
  if (ref.watch(_authUidProvider) == null) return const [];
  final rows = await _db.from('tenants').select('id, name');
  return [for (final row in rows) Tenant.fromJson(row)]
    ..sort((a, b) => a.name.compareTo(b.name));
});

/// Clubs of one alley for the register screen's club picker. Goes through a
/// security-definer RPC — the caller has no profile yet, so plain RLS reads
/// would come back empty.
final registrationClubsProvider =
    FutureProvider.family<List<Club>, String>((ref, tenantId) async {
  if (ref.watch(_authUidProvider) == null) return const [];
  final List<dynamic> rows = await _db
      .rpc('registration_clubs', params: {'p_tenant_id': tenantId});
  return [
    for (final row in rows) Club.fromJson((row as Map).cast<String, dynamic>())
  ];
});

final settingsProvider = StreamProvider<ScheduleSettings?>((ref) {
  final uid = ref.watch(_authUidProvider);
  if (uid == null) return Stream.value(null);
  // primaryKey mirrors the 0005 PK (tenant_id): realtime DELETE events carry
  // only PK columns and bypass RLS, so the key must be tenant-scoped.
  return cachedRows(uid, 'settings',
          () => _db.from('schedule_settings').stream(primaryKey: ['tenant_id']))
      .map((rows) => rows.isEmpty ? null : ScheduleSettings.fromJson(rows.first));
});

/// Club roster (name + palette color), sorted by name.
final clubsProvider = StreamProvider<List<Club>>((ref) {
  final uid = ref.watch(_authUidProvider);
  if (uid == null) return Stream.value(const []);
  return cachedRows(
          uid, 'clubs', () => _db.from('clubs').stream(primaryKey: ['id']))
      .map((rows) =>
      rows.map(Club.fromJson).toList()
        ..sort((a, b) => a.name.compareTo(b.name)));
});

final timeBlocksProvider = StreamProvider<List<TimeBlock>>((ref) {
  final uid = ref.watch(_authUidProvider);
  if (uid == null) return Stream.value(const []);
  return cachedRows(uid, 'time_blocks',
          () => _db.from('time_blocks').stream(primaryKey: ['id']))
      .map(
      (rows) => rows.map(TimeBlock.fromJson).toList()
        ..sort((a, b) {
          final byStart = a.startsAt.minutesFromMidnight
              .compareTo(b.startsAt.minutesFromMidnight);
          return byStart != 0 ? byStart : a.position.compareTo(b.position);
        }));
});

/// True while the realtime socket is down — drives the "Offline" banner.
/// Polled (no extra dependency): the socket state flips within seconds of
/// losing/regaining the network, and a 3s poll is plenty for a banner.
final offlineProvider = StreamProvider<bool>((ref) async* {
  yield false;
  // Stream.periodic (not a delayed loop): its timer is cancelled the moment
  // the provider is disposed, so widget tests never leak a pending timer.
  yield* Stream.periodic(
      const Duration(seconds: 3), (_) => !_db.realtime.isConnected);
});

/// Approved player names from the `players` view. Views cannot stream —
/// re-read on screen entry (and on kiosk idle reset in Phase 4).
final playersProvider = FutureProvider<List<PlayerName>>((ref) async {
  final uid = ref.watch(_authUidProvider);
  if (uid == null) return const [];
  final List<dynamic> rows;
  try {
    rows = await _db.from('players').select();
    RowCache.write(uid, 'players', [
      for (final row in rows) (row as Map).cast<String, dynamic>(),
    ]);
  } catch (_) {
    // Offline: replay the cached roster (or none) instead of erroring.
    final cached = await RowCache.read(uid, 'players');
    if (cached == null) rethrow;
    return [for (final row in cached) PlayerName.fromJson(row)]
      ..sort((a, b) => a.displayName.compareTo(b.displayName));
  }
  return rows
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

  static Future<void> signOut() async {
    final uid = currentUserId;
    await _db.auth.signOut();
    if (uid != null) await RowCache.clear(uid);
  }

  static Future<void> registerProfile(String displayName, String tenantId,
          {String? clubId, String nick = ''}) =>
      _db.rpc('register_profile', params: {
        'p_display_name': displayName,
        'p_tenant_id': tenantId,
        'p_club_id': clubId,
        'p_nick': nick,
      });

  /// Founds a brand-new alley and registers the caller as its admin.
  static Future<void> createTenantAndRegister(
          String tenantName, String displayName, {String nick = ''}) =>
      _db.rpc('create_tenant_and_register', params: {
        'p_tenant_name': tenantName,
        'p_display_name': displayName,
        'p_nick': nick,
      });

  static Future<void> approvePlayer(String userId) =>
      _db.rpc('approve_player', params: {'p_user_id': userId});

  // --- admin: clubs ---
  static Future<void> setPlayerClub(String userId, String? clubId) =>
      _db.rpc('set_player_club', params: {
        'p_user_id': userId,
        'p_club_id': clubId,
      });

  static Future<void> upsertClub({
    String? id,
    required String name,
    required int colorIndex,
  }) =>
      _db.rpc('upsert_club', params: {
        'p_id': id,
        'p_name': name,
        'p_color': colorIndex,
      });

  static Future<void> deleteClub(String id) =>
      _db.rpc('delete_club', params: {'p_id': id});

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
    required String tenantId,
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
      }).eq('tenant_id', tenantId);

  /// Toggles the kiosk board's dark/light theme (spec §4).
  static Future<void> setKioskDark(bool kioskDark, {required String tenantId}) =>
      _db
          .from('schedule_settings')
          .update({'kiosk_dark': kioskDark}).eq('tenant_id', tenantId);

  static Future<void> addTimeBlock(HourMinute startsAt, HourMinute endsAt, int position) =>
      _db.from('time_blocks').insert({
        'starts_at': startsAt.toSql(),
        'ends_at': endsAt.toSql(),
        'position': position,
      });

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

  // --- admin: priority slots (matches & other blockages) ---
  static Future<void> savePrioritySlot({
    String? id,
    required Day date,
    required HourMinute startsAt,
    required HourMinute endsAt,
    required String typeId,
    String homeTeam = '',
    String awayTeam = '',
    int prepMinutes = 0,
    String description = '',
  }) async {
    final row = {
      'date': date.toSql(),
      'starts_at': startsAt.toSql(),
      'ends_at': endsAt.toSql(),
      'type_id': typeId,
      'home_team': homeTeam,
      'away_team': awayTeam,
      'prep_minutes': prepMinutes,
      'description': description,
      if (id == null) 'created_by': currentUserId!,
    };
    if (id == null) {
      await _db.from('priority_slots').insert(row);
    } else {
      await _db.from('priority_slots').update(row).eq('id', id);
    }
  }

  static Future<void> deletePrioritySlot(String id) =>
      _db.from('priority_slots').delete().eq('id', id);

  /// Upserts a priority-slot type. Only name/color/lanes are client-writable
  /// (column grants guard is_match/builtin server-side).
  static Future<void> upsertSlotType({
    String? id,
    required String name,
    required int colorIndex,
    required List<int>? lanes,
  }) async {
    final row = {'name': name, 'color': colorIndex, 'lanes': lanes};
    if (id == null) {
      await _db.from('priority_slot_types').insert(row);
    } else {
      await _db.from('priority_slot_types').update(row).eq('id', id);
    }
  }

  static Future<void> deleteSlotType(String id) =>
      _db.from('priority_slot_types').delete().eq('id', id);

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
    int color = -2,
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
      'color': color,
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
  final uid = ref.watch(_authUidProvider);
  if (uid == null) return Stream.value(const []);
  final sunday = monday.addDays(6);
  return cachedRows(
          uid,
          'res.${monday.toSql()}',
          () => _db
              .from('reservations')
              .stream(primaryKey: ['id'])
              .gte('date', monday.toSql()))
      .map((rows) => rows
          .map(Reservation.fromJson)
          .where((r) => r.isLive && !r.date.isAfter(sunday))
          .toList());
});

final dayOverridesProvider = StreamProvider<List<DayOverride>>((ref) {
  final uid = ref.watch(_authUidProvider);
  if (uid == null) return Stream.value(const []);
  return cachedRows(uid, 'day_overrides',
          () => _db.from('day_overrides').stream(primaryKey: ['tenant_id', 'date']))
      .map(
      (rows) => rows.map(DayOverride.fromJson).toList());
});

final slotTypesProvider = StreamProvider<List<PrioritySlotType>>((ref) {
  final uid = ref.watch(_authUidProvider);
  if (uid == null) return Stream.value(const []);
  return cachedRows(uid, 'slot_types',
          () => _db.from('priority_slot_types').stream(primaryKey: ['id']))
      .map(
      (rows) => rows.map(PrioritySlotType.fromJson).toList());
});

/// Raw priority_slots rows joined with the types stream into resolved
/// [PrioritySlot]s. Plain Provider (not Stream): recomputes whenever either
/// stream emits; use sites read the list directly.
final prioritySlotsProvider = Provider<List<PrioritySlot>>((ref) {
  final types = ref.watch(slotTypesProvider).value ?? const [];
  final typeById = {for (final t in types) t.id: t};
  final rows = ref.watch(_prioritySlotRowsProvider).value ?? const [];
  return [for (final row in rows) PrioritySlot.fromJson(row, typeById)];
});

final _prioritySlotRowsProvider =
    StreamProvider<List<Map<String, dynamic>>>((ref) {
  final uid = ref.watch(_authUidProvider);
  if (uid == null) return Stream.value(const []);
  return cachedRows(uid, 'priority_slots',
      () => _db.from('priority_slots').stream(primaryKey: ['id']));
});

final rentalsProvider = StreamProvider<List<Rental>>((ref) {
  final uid = ref.watch(_authUidProvider);
  if (uid == null) return Stream.value(const []);
  return cachedRows(uid, 'rentals',
          () => _db.from('rentals').stream(primaryKey: ['id']))
      .map(
      (rows) => rows.map(Rental.fromJson).toList());
});

/// The signed-in player's reservations (all of them; the UI derives the
/// active count via activeReservationCount).
final myActiveReservationsProvider =
    StreamProvider<List<Reservation>>((ref) {
  final uid = ref.watch(_authUidProvider);
  if (uid == null) return Stream.value(const []);
  return cachedRows(
          uid,
          'res.mine',
          () => _db
              .from('reservations')
              .stream(primaryKey: ['id'])
              .eq('player_id', uid))
      .map((rows) => rows.map(Reservation.fromJson).toList());
});

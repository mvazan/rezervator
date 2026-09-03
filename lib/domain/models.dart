/// Domain models mirroring the Supabase schema (supabase/migrations).
/// Pure Dart — no Flutter imports — so all logic on top is unit-testable.
library;

/// A wall-clock time of day, independent of Flutter's TimeOfDay.
class HourMinute implements Comparable<HourMinute> {
  const HourMinute(this.hour, this.minute)
      : assert(hour >= 0 && hour < 24),
        assert(minute >= 0 && minute < 60);

  final int hour;
  final int minute;

  /// Parses "HH:MM" or "HH:MM:SS" (Postgres `time` format).
  factory HourMinute.parse(String value) {
    final parts = value.split(':');
    return HourMinute(int.parse(parts[0]), int.parse(parts[1]));
  }

  int get minutesFromMidnight => hour * 60 + minute;

  /// "HH:MM:SS" for Postgres.
  String toSql() =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}:00';

  /// "H:MM" for people.
  String display() => '$hour:${minute.toString().padLeft(2, '0')}';

  @override
  int compareTo(HourMinute other) =>
      minutesFromMidnight.compareTo(other.minutesFromMidnight);

  @override
  bool operator ==(Object other) =>
      other is HourMinute && other.hour == hour && other.minute == minute;

  @override
  int get hashCode => Object.hash(hour, minute);

  @override
  String toString() => display();
}

/// A calendar date without time-of-day. Wraps a UTC DateTime internally so
/// date arithmetic is DST-safe.
class Day implements Comparable<Day> {
  Day(int year, int month, int day) : _dt = DateTime.utc(year, month, day);

  Day.fromDateTime(DateTime dt) : _dt = DateTime.utc(dt.year, dt.month, dt.day);

  /// Parses "YYYY-MM-DD" (Postgres `date` format).
  factory Day.parse(String value) => Day.fromDateTime(DateTime.parse(value));

  final DateTime _dt;

  int get year => _dt.year;
  int get month => _dt.month;
  int get day => _dt.day;

  /// DateTime.monday (1) .. DateTime.sunday (7)
  int get weekday => _dt.weekday;

  Day addDays(int days) => Day.fromDateTime(_dt.add(Duration(days: days)));

  int differenceInDays(Day other) => _dt.difference(other._dt).inDays;

  bool isAfter(Day other) => _dt.isAfter(other._dt);
  bool isBefore(Day other) => _dt.isBefore(other._dt);

  String toSql() => '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}-'
      '${day.toString().padLeft(2, '0')}';

  @override
  int compareTo(Day other) => _dt.compareTo(other._dt);

  @override
  bool operator ==(Object other) => other is Day && other._dt == _dt;

  @override
  int get hashCode => _dt.hashCode;

  @override
  String toString() => toSql();
}

/// Chronological ordering by date, then start time — the one comparator every
/// slot-like list in the app sorts by.
int compareDayTime(Day dateA, HourMinute timeA, Day dateB, HourMinute timeB) {
  final byDate = dateA.compareTo(dateB);
  return byDate != 0 ? byDate : timeA.compareTo(timeB);
}

/// "20.4.–3.5."
String rangeLabel(Day from, Day to) =>
    '${from.day}.${from.month}.–${to.day}.${to.month}.';

enum Role { player, admin, kiosk }

enum ProfileStatus { pending, approved }

class Profile {
  const Profile({
    required this.id,
    required this.displayName,
    required this.email,
    required this.role,
    required this.status,
    this.fcmToken,
    this.nick = '',
    this.clubId,
    this.tenantId = '',
    this.superadmin = false,
    this.homeTenantId = '',
    this.hasAccount = true,
  });

  final String id;
  final String displayName;
  final String email;
  final Role role;
  final ProfileStatus status;
  final String? fcmToken;

  /// False for a hand-made "hráč bez účtu" (0022, `placeholder` in the
  /// DB): no auth user, never signs in; the admin books them and they pick
  /// themselves on the kiosk. Always an approved plain player.
  final bool hasAccount;

  /// Short board name (<=14 chars); empty means "use displayName".
  final String nick;

  /// FK into `clubs`; null when the player has no assigned club.
  final String? clubId;

  /// The kuželna this profile belongs to.
  final String tenantId;

  /// App owner (0014): approves new kuželny and can switch tenants.
  final bool superadmin;

  /// Where the superadmin actually plays (0015) — switch_tenant moves
  /// [tenantId] but never this.
  final String homeTenantId;

  bool get isApproved => status == ProfileStatus.approved;
  bool get isAdmin => role == Role.admin && isApproved;
  bool get isSuperadmin => superadmin && isApproved;

  /// A superadmin switched into a foreign kuželna — hidden from its player
  /// lists and attendance (they are inspecting, not playing).
  bool get isVisiting =>
      superadmin && homeTenantId.isNotEmpty && homeTenantId != tenantId;

  factory Profile.fromJson(Map<String, dynamic> json) => Profile(
        id: json['id'] as String,
        displayName: json['display_name'] as String,
        email: json['email'] as String? ?? '',
        role: Role.values.asNameMap()[json['role']] ?? Role.player,
        status: json['status'] == 'approved'
            ? ProfileStatus.approved
            : ProfileStatus.pending,
        fcmToken: json['fcm_token'] as String?,
        nick: json['nick'] as String? ?? '',
        clubId: json['club_id'] as String?,
        tenantId: json['tenant_id'] as String? ?? '',
        superadmin: json['superadmin'] as bool? ?? false,
        homeTenantId: json['home_tenant_id'] as String? ?? '',
        hasAccount: !(json['placeholder'] as bool? ?? false),
      );
}

/// A club (spec §2): a named group of players sharing a palette color.
class Club {
  const Club({
    required this.id,
    required this.name,
    this.colorIndex = -1,
  });

  final String id;
  final String name;

  /// Palette index 0–11, or -1 for "no color assigned".
  final int colorIndex;

  factory Club.fromJson(Map<String, dynamic> json) => Club(
        id: json['id'] as String,
        name: json['name'] as String,
        colorIndex: json['color'] as int? ?? -1,
      );
}

/// Display name of [clubId] from the live club roster; '' when the profile
/// has no club or the club was deleted. (The old `profiles.club` text was a
/// registration-time copy that went stale on reassignment; dropped in 0019.)
String clubNameOf(String? clubId, Iterable<Club> clubs) {
  if (clubId == null) return '';
  for (final club in clubs) {
    if (club.id == clubId) return club.name;
  }
  return '';
}

/// A row of the `players` view — the only profile data the kiosk sees.
class PlayerName {
  const PlayerName({
    required this.id,
    required this.displayName,
    this.nick = '',
    this.clubId,
    this.clubColor = -1,
    this.hasAccount = true,
  });

  final String id;
  final String displayName;

  /// Short board name (<=14 chars); empty means "use displayName".
  final String nick;

  /// FK into `clubs`; null when the player has no assigned club.
  final String? clubId;

  /// Palette index 0–11 of the player's club, or -1 for "no color".
  final int clubColor;

  /// False for a hand-made "hráč bez účtu" (see [Profile.hasAccount]).
  final bool hasAccount;

  factory PlayerName.fromJson(Map<String, dynamic> json) => PlayerName(
        id: json['id'] as String,
        displayName: json['display_name'] as String,
        nick: json['nick'] as String? ?? '',
        clubId: json['club_id'] as String?,
        clubColor: json['club_color'] as int? ?? -1,
        hasAccount: !(json['placeholder'] as bool? ?? false),
      );
}

/// One alley (kuželna): fully isolated tenant. Players pick theirs at
/// registration; everything else scopes server-side by the profile's tenant.
class Tenant {
  const Tenant({required this.id, required this.name});

  final String id;
  final String name;

  factory Tenant.fromJson(Map<String, dynamic> json) =>
      Tenant(id: json['id'] as String, name: json['name'] as String);
}

/// One row of the superadmin's kuželny overview (admin_list_tenants RPC) —
/// includes the founder e-mail, which regular clients can never read.
class AdminTenant {
  const AdminTenant({
    required this.id,
    required this.name,
    required this.status,
    this.founderEmail = '',
    this.memberCount = 0,
  });

  final String id;
  final String name;
  final String status;
  final String founderEmail;
  final int memberCount;

  bool get pending => status == 'pending';

  factory AdminTenant.fromJson(Map<String, dynamic> json) => AdminTenant(
        id: json['id'] as String,
        name: json['name'] as String,
        status: json['status'] as String? ?? 'approved',
        founderEmail: json['founder_email'] as String? ?? '',
        memberCount: (json['member_count'] as num?)?.toInt() ?? 0,
      );
}

class ScheduleSettings {
  const ScheduleSettings({
    required this.laneCount,
    required this.trainingWeekdays,
    required this.bookingHorizonDays,
    required this.maxActiveReservations,
    this.kioskDark = true,
    this.kioskFitDay = true,
    this.tenantId = '',
  });

  final int laneCount;

  /// ISO weekdays with regular trainings (1 = Monday … 7 = Sunday).
  final Set<int> trainingWeekdays;
  final int bookingHorizonDays;
  final int maxActiveReservations;

  /// Whether the kiosk board renders in the dark theme (spec §4).
  final bool kioskDark;

  /// Kiosk display mode: true stretches the whole day onto the screen (no
  /// scrolling); false uses a fixed comfortable scale (lane rows sized like
  /// the app's week view) and lets the board scroll vertically.
  final bool kioskFitDay;

  /// The settings row's tenant — the update key since 0005 (one row per
  /// tenant instead of the old singleton).
  final String tenantId;

  static const defaults = ScheduleSettings(
    laneCount: 4,
    trainingWeekdays: {1, 2, 4},
    bookingHorizonDays: 14,
    maxActiveReservations: 3,
  );

  factory ScheduleSettings.fromJson(Map<String, dynamic> json) =>
      ScheduleSettings(
        laneCount: json['lane_count'] as int,
        trainingWeekdays: {
          for (final d in json['training_weekdays'] as List) d as int,
        },
        bookingHorizonDays: json['booking_horizon_days'] as int,
        maxActiveReservations: json['max_active_reservations'] as int,
        kioskDark: json['kiosk_dark'] as bool? ?? true,
        kioskFitDay: json['kiosk_fit_day'] as bool? ?? true,
        tenantId: json['tenant_id'] as String? ?? '',
      );
}

class TimeBlock {
  const TimeBlock({
    required this.id,
    required this.startsAt,
    required this.endsAt,
    required this.position,
    required this.active,
  });

  final String id;
  final HourMinute startsAt;
  final HourMinute endsAt;
  final int position;
  final bool active;

  /// "16:00–17:00"
  String get label => '${_pad(startsAt)}–${_pad(endsAt)}';

  int get durationMinutes =>
      endsAt.minutesFromMidnight - startsAt.minutesFromMidnight;

  static String _pad(HourMinute t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  factory TimeBlock.fromJson(Map<String, dynamic> json) => TimeBlock(
        id: json['id'] as String,
        startsAt: HourMinute.parse(json['starts_at'] as String),
        endsAt: HourMinute.parse(json['ends_at'] as String),
        position: json['position'] as int,
        active: json['active'] as bool? ?? true,
      );
}

/// Hourly 16–22 placeholder grid shown before the admin configures blocks.
List<TimeBlock> defaultTimeBlocks() => [
      for (var i = 0; i < 6; i++)
        TimeBlock(
          id: 'default-$i',
          startsAt: HourMinute(16 + i, 0),
          endsAt: HourMinute(17 + i, 0),
          position: i,
          active: true,
        ),
    ];

class DayOverride {
  const DayOverride({
    required this.date,
    required this.closed,
    required this.reason,
    this.blockIds,
  });

  final Day date;
  final bool closed;
  final String reason;

  /// null = the default active block set applies; set = exactly these blocks.
  final List<String>? blockIds;

  factory DayOverride.fromJson(Map<String, dynamic> json) => DayOverride(
        date: Day.parse(json['date'] as String),
        closed: json['closed'] as bool,
        reason: json['reason'] as String? ?? '',
        blockIds: (json['block_ids'] as List?)?.cast<String>(),
      );
}

/// A priority-slot šablóna: label, palette color and lane scope. 'Zápas' is
/// the seeded built-in kind ([isMatch]) that additionally carries teams and
/// a prep window on its slots.
class PrioritySlotType {
  const PrioritySlotType({
    required this.id,
    required this.name,
    this.colorIndex = -1,
    this.lanes,
    this.isMatch = false,
    this.builtin = false,
    this.unresolved = false,
  });

  final String id;
  final String name;

  /// Palette index (0–11); -1 = the default rose (match) tint.
  final int colorIndex;

  /// Lanes this type blocks; null = the whole alley.
  final List<int>? lanes;
  final bool isMatch;
  final bool builtin;

  /// True only for the placeholder used while the slot's real type row
  /// hasn't streamed in yet. An unresolved type renders like a whole-alley
  /// match but carries NO block-cancelling power — the two streams
  /// (slots/types) race on realtime delivery, and a lane-scoped slot must
  /// not transiently wipe blocks off every board just because its type row
  /// arrived a beat later.
  final bool unresolved;

  bool coversLane(int lane) => lanes == null || lanes!.contains(lane);

  factory PrioritySlotType.fromJson(Map<String, dynamic> json) =>
      PrioritySlotType(
        id: json['id'] as String,
        name: json['name'] as String,
        colorIndex: json['color'] as int? ?? -1,
        lanes: (json['lanes'] as List?)?.cast<int>(),
        isMatch: json['is_match'] as bool? ?? false,
        builtin: json['builtin'] as bool? ?? false,
      );
}

/// One dated priority slot (a match or any other typed blockage). Blocks
/// reservations on its type's lanes for exactly `[startsAt, endsAt)` and is
/// shown to spectators even on closed days. A match's lane prep is its own
/// linked "Úklid před zápasem" child slot ([parentId], server-maintained
/// from [prepMinutes]).
class PrioritySlot {
  const PrioritySlot({
    required this.id,
    required this.date,
    required this.startsAt,
    required this.endsAt,
    required this.type,
    this.homeTeam = '',
    this.awayTeam = '',
    this.prepMinutes = 0,
    this.description = '',
    this.parentId,
    this.isAway = false,
  });

  final String id;
  final Day date;
  final HourMinute startsAt;
  final HourMinute endsAt;
  final PrioritySlotType type;

  /// Team fields are only meaningful when [type.isMatch].
  final String homeTeam;
  final String awayTeam;

  /// Minutes of lane prep required before [startsAt]; reservations that
  /// overlap this window (as well as the slot itself) are blocked.
  final int prepMinutes;
  final String description;

  /// Set on an auto-managed "Úklid před zápasem" child — links it to its
  /// match (cascade-deleted with it, hidden from admin lists).
  final String? parentId;

  /// Venkovní zápas — played elsewhere. Listed in the day header but blocks
  /// nothing at the alley (no cancellations, no úklid child, no collisions).
  final bool isAway;

  /// Match kind: `'{home} – {away}'` (or just `away`); other kinds show the
  /// type's name.
  String get title => type.isMatch
      ? (homeTeam.isEmpty ? awayTeam : '$homeTeam – $awayTeam')
      : type.name;

  bool coversLane(int lane) => type.coversLane(lane);

  /// [type] is resolved by the caller (the provider joins the types stream);
  /// an unknown type_id falls back to a built-in-match placeholder so a
  /// mid-stream row never crashes the board.
  factory PrioritySlot.fromJson(
    Map<String, dynamic> json,
    Map<String, PrioritySlotType> typeById,
  ) =>
      PrioritySlot(
        id: json['id'] as String,
        date: Day.parse(json['date'] as String),
        startsAt: HourMinute.parse(json['starts_at'] as String),
        endsAt: HourMinute.parse(json['ends_at'] as String),
        type: typeById[json['type_id'] as String?] ?? unresolvedType,
        homeTeam: json['home_team'] as String? ?? '',
        awayTeam: json['away_team'] as String? ?? '',
        prepMinutes: json['prep_minutes'] as int? ?? 0,
        description: json['description'] as String? ?? '',
        parentId: json['parent_id'] as String?,
        isAway: json['is_away'] as bool? ?? false,
      );

  /// A fully-powered stand-in match type for tests and previews.
  static const fallbackMatchType = PrioritySlotType(
    id: 'fallback-match',
    name: 'Zápas',
    isMatch: true,
    builtin: true,
  );

  /// Placeholder while the types stream hasn't delivered the real row yet —
  /// renders like [fallbackMatchType] but never cancels blocks (see
  /// [PrioritySlotType.unresolved]).
  static const unresolvedType = PrioritySlotType(
    id: 'unresolved',
    name: 'Zápas',
    isMatch: true,
    builtin: true,
    unresolved: true,
  );

}

class Rental {
  const Rental({
    required this.id,
    required this.renterName,
    required this.lanes,
    required this.date,
    required this.weekday,
    required this.startsAt,
    required this.endsAt,
    required this.validFrom,
    required this.validUntil,
    required this.note,
    this.color = -2,
    this.parentId,
    this.skipped = false,
    this.overrideId,
  });

  final String id;
  final String renterName;
  final List<int> lanes;

  /// Palette index 0–11, or -2 for "use the default rental tint".
  final int color;

  /// Exception row: the weekly series this row overrides for [date]
  /// (null on series and one-time rows). Its lanes/times/note are the
  /// effective values for that one date; name and colour mirror the series.
  final String? parentId;

  /// Exception row: the series does not happen on [date] at all.
  final bool skipped;

  /// Set only on resolved per-day copies (see [overriddenBy] / `rentalsOn`):
  /// the id of the exception row that shaped this occurrence.
  final String? overrideId;

  /// Exactly one of [date] (one-time) and [weekday] (weekly, ISO) is set —
  /// enforced by a DB check constraint.
  final Day? date;
  final int? weekday;
  final HourMinute startsAt;
  final HourMinute endsAt;
  final Day? validFrom;
  final Day? validUntil;
  final String note;

  /// A weekly series (exceptions hang under these; one-time rows and
  /// exception rows are not series).
  bool get isSeries => parentId == null && weekday != null;

  /// A resolved occurrence shaped by an exception row.
  bool get isOverridden => overrideId != null;

  /// Does this series/one-time row occur on [day]? Exception rows answer
  /// for their own date only — resolve through `rentalsOn`, which applies
  /// them to their series instead of listing them on their own.
  bool occursOn(Day day) {
    if (date != null) return date == day;
    if (weekday != day.weekday) return false;
    if (validFrom != null && day.isBefore(validFrom!)) return false;
    if (validUntil != null && day.isAfter(validUntil!)) return false;
    return true;
  }

  /// This series as [child] shapes it on one date: the child's lanes, times
  /// and note; everything else (id, renter, colour, weekday, validity) from
  /// the series, so the calendar still opens the series by [id].
  Rental overriddenBy(Rental child) => Rental(
        id: id,
        renterName: renterName,
        lanes: child.lanes,
        date: date,
        weekday: weekday,
        startsAt: child.startsAt,
        endsAt: child.endsAt,
        validFrom: validFrom,
        validUntil: validUntil,
        note: child.note,
        color: color,
        overrideId: child.id,
      );

  factory Rental.fromJson(Map<String, dynamic> json) => Rental(
        id: json['id'] as String,
        renterName: json['renter_name'] as String,
        lanes: (json['lanes'] as List).cast<int>(),
        date: json['date'] == null ? null : Day.parse(json['date'] as String),
        weekday: json['weekday'] as int?,
        startsAt: HourMinute.parse(json['starts_at'] as String),
        endsAt: HourMinute.parse(json['ends_at'] as String),
        validFrom: json['valid_from'] == null
            ? null
            : Day.parse(json['valid_from'] as String),
        validUntil: json['valid_until'] == null
            ? null
            : Day.parse(json['valid_until'] as String),
        note: json['note'] as String? ?? '',
        color: json['color'] as int? ?? -2,
        parentId: json['parent_id'] as String?,
        skipped: json['skipped'] as bool? ?? false,
      );
}

class Reservation {
  const Reservation({
    required this.id,
    required this.playerId,
    required this.date,
    required this.blockId,
    required this.lane,
    required this.createdVia,
    required this.createdAt,
    this.cancelledAt,
    this.cancelledVia,
    this.cancelNote = '',
  });

  final String id;
  final String playerId;
  final Day date;
  final String blockId;
  final int lane;
  final String createdVia;
  final DateTime createdAt;
  final DateTime? cancelledAt;
  final String? cancelledVia;
  final String cancelNote;

  bool get isLive => cancelledAt == null;

  factory Reservation.fromJson(Map<String, dynamic> json) => Reservation(
        id: json['id'] as String,
        playerId: json['player_id'] as String,
        date: Day.parse(json['date'] as String),
        blockId: json['block_id'] as String,
        lane: json['lane'] as int,
        createdVia: json['created_via'] as String,
        createdAt: DateTime.parse(json['created_at'] as String),
        cancelledAt: json['cancelled_at'] == null
            ? null
            : DateTime.parse(json['cancelled_at'] as String),
        cancelledVia: json['cancelled_via'] as String?,
        cancelNote: json['cancel_note'] as String? ?? '',
      );
}

/// Light projection of a future live reservation — just enough to detect
/// whether it would fall outside the grid after a schedule change (see
/// `Api.futureLiveReservations` and `domain/day_edit.dart`).
class StrandableReservation {
  const StrandableReservation({
    required this.date,
    required this.lane,
    required this.blockId,
    this.playerId,
  });

  final Day date;
  final int lane;
  final String blockId;

  /// Who holds the slot — lets a move tell players with an inbox apart from
  /// hand-made "hráči bez účtu" (null when the query did not select it).
  final String? playerId;

  factory StrandableReservation.fromJson(Map<String, dynamic> json) =>
      StrandableReservation(
        date: Day.parse(json['date'] as String),
        lane: json['lane'] as int,
        blockId: json['block_id'] as String,
        playerId: json['player_id'] as String?,
      );
}

/// One row of the monthly_attendance RPC result.
class AttendanceRow {
  const AttendanceRow({
    required this.playerId,
    required this.displayName,
    required this.club,
    required this.attended,
  });

  final String playerId;
  final String displayName;
  final String club;
  final int attended;

  factory AttendanceRow.fromJson(Map<String, dynamic> json) => AttendanceRow(
        playerId: json['player_id'] as String,
        displayName: json['display_name'] as String,
        club: json['club'] as String? ?? '',
        attended: json['attended'] as int,
      );
}

// ---------------------------------------------------------------------------
// Google Calendar link (0023)
// ---------------------------------------------------------------------------

/// Where the user's Google Calendar link stands. No row at all means
/// [notLinked] — the app never writes this table, the backend does.
enum CalendarLinkStatus {
  /// No row, or a cleanly disconnected one (`unlinked` keeps the reminder
  /// preference for the next link).
  notLinked,

  /// Google said yes, but the "Rezervátor" calendar isn't created yet.
  pending,
  linked,

  /// Access revoked, or the calendar was deleted in Google — offer a re-link.
  broken;

  /// Anything this build has never heard of reads as [notLinked] rather
  /// than blowing up the profile card.
  static CalendarLinkStatus parse(String? value) => switch (value) {
        'pending' => CalendarLinkStatus.pending,
        'linked' => CalendarLinkStatus.linked,
        'broken' => CalendarLinkStatus.broken,
        _ => CalendarLinkStatus.notLinked,
      };
}

/// Google caps calendar reminders at 5 per event, each at most 4 weeks
/// (40320 minutes) before it. The UI and the RPC both enforce this.
const maxCalendarReminders = 5;
const maxReminderMinutes = 40320;

/// "za kolik předem" → human text: prefers the largest clean unit
/// (3 dny / 5 h / 45 min), zero means "at the start of the training".
String reminderOffsetLabel(int minutes) {
  if (minutes <= 0) return 'V čase začátku';
  if (minutes % 1440 == 0) {
    final d = minutes ~/ 1440;
    final unit = d == 1 ? 'den' : (d <= 4 ? 'dny' : 'dní');
    return '$d $unit předem';
  }
  if (minutes % 60 == 0) return '${minutes ~/ 60} h předem';
  return '$minutes min předem';
}

/// Profile-card summary of a reminder set: "Žádné" or the offsets from the
/// farthest ("1 den předem · 2 h předem").
String remindersSummary(List<int> minutes) {
  if (minutes.isEmpty) return 'Žádné';
  final sorted = [...minutes]..sort((a, b) => b.compareTo(a));
  return sorted.map(reminderOffsetLabel).join(' · ');
}

/// One row of `google_calendar_links` (the client-visible half of the link;
/// tokens live in a server-only table).
class CalendarLink {
  const CalendarLink({
    required this.status,
    this.googleEmail,
    this.lastError,
    this.updatedAt,
    this.reminderMinutes = const [],
  });

  static const none = CalendarLink(status: CalendarLinkStatus.notLinked);

  final CalendarLinkStatus status;

  /// The linked Google account, for the profile card. Never used for auth.
  final String? googleEmail;

  /// Why the link is pending/broken, in user-facing Czech, set by the backend.
  final String? lastError;
  final DateTime? updatedAt;

  /// Reminder offsets in minutes before a training, farthest first. Applied
  /// server-side to every upcoming event when changed.
  final List<int> reminderMinutes;

  bool get isLinked => status == CalendarLinkStatus.linked;

  factory CalendarLink.fromJson(Map<String, dynamic> json) => CalendarLink(
        status: CalendarLinkStatus.parse(json['status'] as String?),
        googleEmail: json['google_email'] as String?,
        lastError: json['last_error'] as String?,
        updatedAt: json['updated_at'] == null
            ? null
            : DateTime.parse(json['updated_at'] as String),
        reminderMinutes: [
          for (final m in json['reminder_minutes'] as List? ?? const [])
            (m as num).toInt(),
        ]..sort((a, b) => b.compareTo(a)),
      );
}

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
    required this.club,
    required this.email,
    required this.role,
    required this.status,
    this.fcmToken,
    this.nick = '',
    this.clubId,
  });

  final String id;
  final String displayName;
  final String club;
  final String email;
  final Role role;
  final ProfileStatus status;
  final String? fcmToken;

  /// Short board name (<=14 chars); empty means "use displayName".
  final String nick;

  /// FK into `clubs`; null when the player has no assigned club.
  final String? clubId;

  bool get isApproved => status == ProfileStatus.approved;
  bool get isAdmin => role == Role.admin && isApproved;

  factory Profile.fromJson(Map<String, dynamic> json) => Profile(
        id: json['id'] as String,
        displayName: json['display_name'] as String,
        club: json['club'] as String? ?? '',
        email: json['email'] as String? ?? '',
        role: Role.values.asNameMap()[json['role']] ?? Role.player,
        status: json['status'] == 'approved'
            ? ProfileStatus.approved
            : ProfileStatus.pending,
        fcmToken: json['fcm_token'] as String?,
        nick: json['nick'] as String? ?? '',
        clubId: json['club_id'] as String?,
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

/// A row of the `players` view — the only profile data the kiosk sees.
class PlayerName {
  const PlayerName({
    required this.id,
    required this.displayName,
    required this.club,
    this.nick = '',
    this.clubId,
    this.clubColor = -1,
  });

  final String id;
  final String displayName;
  final String club;

  /// Short board name (<=14 chars); empty means "use displayName".
  final String nick;

  /// FK into `clubs`; null when the player has no assigned club.
  final String? clubId;

  /// Palette index 0–11 of the player's club, or -1 for "no color".
  final int clubColor;

  factory PlayerName.fromJson(Map<String, dynamic> json) => PlayerName(
        id: json['id'] as String,
        displayName: json['display_name'] as String,
        club: json['club'] as String? ?? '',
        nick: json['nick'] as String? ?? '',
        clubId: json['club_id'] as String?,
        clubColor: json['club_color'] as int? ?? -1,
      );
}

class ScheduleSettings {
  const ScheduleSettings({
    required this.laneCount,
    required this.trainingWeekdays,
    required this.bookingHorizonDays,
    required this.maxActiveReservations,
    this.kioskDark = true,
  });

  final int laneCount;

  /// ISO weekdays with regular trainings (1 = Monday … 7 = Sunday).
  final Set<int> trainingWeekdays;
  final int bookingHorizonDays;
  final int maxActiveReservations;

  /// Whether the kiosk board renders in the dark theme (spec §4).
  final bool kioskDark;

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

class Match {
  const Match({
    required this.id,
    required this.date,
    required this.startsAt,
    required this.endsAt,
    required this.homeTeam,
    required this.awayTeam,
    this.prepMinutes = 0,
    required this.description,
  });

  final String id;
  final Day date;
  final HourMinute startsAt;
  final HourMinute endsAt;
  final String homeTeam;
  final String awayTeam;

  /// Minutes of lane prep required before [startsAt]; reservations that
  /// overlap this window (as well as the match itself) are blocked.
  final int prepMinutes;
  final String description;

  /// `'{home} – {away}'`, or just `away` when there's no home team.
  String get title => homeTeam.isEmpty ? awayTeam : '$homeTeam – $awayTeam';

  /// [startsAt] minus [prepMinutes], clamped to 00:00 (never wraps past
  /// midnight into the previous day).
  HourMinute get blockingStart {
    final minutes = startsAt.minutesFromMidnight - prepMinutes;
    if (minutes <= 0) return const HourMinute(0, 0);
    return HourMinute(minutes ~/ 60, minutes % 60);
  }

  factory Match.fromJson(Map<String, dynamic> json) => Match(
        id: json['id'] as String,
        date: Day.parse(json['date'] as String),
        startsAt: HourMinute.parse(json['starts_at'] as String),
        endsAt: HourMinute.parse(json['ends_at'] as String),
        homeTeam: json['home_team'] as String? ?? '',
        awayTeam: json['away_team'] as String,
        prepMinutes: json['prep_minutes'] as int? ?? 0,
        description: json['description'] as String? ?? '',
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
  });

  final String id;
  final String renterName;
  final List<int> lanes;

  /// Palette index 0–11, or -2 for "use the default rental tint".
  final int color;

  /// Exactly one of [date] (one-time) and [weekday] (weekly, ISO) is set —
  /// enforced by a DB check constraint.
  final Day? date;
  final int? weekday;
  final HourMinute startsAt;
  final HourMinute endsAt;
  final Day? validFrom;
  final Day? validUntil;
  final String note;

  bool occursOn(Day day) {
    if (date != null) return date == day;
    if (weekday != day.weekday) return false;
    if (validFrom != null && day.isBefore(validFrom!)) return false;
    if (validUntil != null && day.isAfter(validUntil!)) return false;
    return true;
  }

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

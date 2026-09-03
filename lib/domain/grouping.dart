/// List shaping shared by the admin screens: club sections and closure
/// runs. Pure Dart — no Flutter imports.
library;

import 'collation.dart';
import 'models.dart';

/// Clubs by name, members name-sorted within, (null, …) = "Bez oddílu" last
/// (moved from players_screen._byClub). A player whose club is missing from
/// [clubs] (deleted) counts as unaffiliated; clubs without members are
/// skipped.
List<(String? clubName, List<Profile> members)> playersByClub(
  List<Profile> approved,
  List<Club> clubs,
) {
  final sortedClubs = [...clubs]..sort((a, b) => compareCzech(a.name, b.name));
  List<Profile> membersOf(String? clubId) =>
      approved
          .where(
            (p) => clubId == null
                ? !clubs.any((c) => c.id == p.clubId)
                : p.clubId == clubId,
          )
          .toList()
        ..sort((a, b) => compareCzech(a.displayName, b.displayName));
  return [
    for (final club in sortedClubs)
      if (membersOf(club.id) case final members when members.isNotEmpty)
        (club.name, members),
    if (membersOf(null) case final members when members.isNotEmpty)
      (null, members),
  ];
}

/// Club sections alphabetically, 'Bez oddílu' last; players alphabetically
/// within a section (the count column carries the ranking, the list stays
/// findable by name like every other list in the app).
List<(String header, List<AttendanceRow> members)> attendanceByClub(
  List<AttendanceRow> rows,
) {
  final groups = <String, List<AttendanceRow>>{};
  for (final r in rows) {
    groups.putIfAbsent(r.club, () => []).add(r);
  }
  for (final members in groups.values) {
    members.sort((a, b) => compareCzech(a.displayName, b.displayName));
  }
  final named = [
    for (final entry in groups.entries)
      if (entry.key.isNotEmpty) entry,
  ]..sort((a, b) => compareCzech(a.key, b.key));
  return [
    for (final entry in named) (entry.key, entry.value),
    if (groups[''] case final unaffiliated?) ('Bez oddílu', unaffiliated),
  ];
}

/// Consecutive same-reason closures (e.g. a week of dovolená) folded into
/// runs, earliest first (moved verbatim from overrides_screen's runsOf). The
/// screen shows each run as one range tile and deletes it as a whole.
List<List<DayOverride>> closureRuns(List<DayOverride> overrides) {
  final sorted = [...overrides]..sort((a, b) => a.date.compareTo(b.date));
  final runs = <List<DayOverride>>[];
  for (final o in sorted) {
    if (runs.isNotEmpty &&
        runs.last.last.date.addDays(1) == o.date &&
        runs.last.last.reason == o.reason) {
      runs.last.add(o);
    } else {
      runs.add([o]);
    }
  }
  return runs;
}

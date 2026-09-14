/// What is coming for a player: their live future reservations, the future
/// matches of the teams they follow, and any single match they said they
/// are playing (0039) — one timeline by day. Pure Dart, unit-tested; the
/// screen only renders it.
library;

import 'models.dart';

sealed class UpcomingItem {
  const UpcomingItem();

  Day get date;
  HourMinute get startsAt;
}

/// One of the player's own reservations with the block it sits in.
class UpcomingTraining extends UpcomingItem {
  const UpcomingTraining(this.reservation, this.block);

  final Reservation reservation;
  final TimeBlock block;

  @override
  Day get date => reservation.date;
  @override
  HourMinute get startsAt => block.startsAt;
}

/// A match of a followed team — home or away.
class UpcomingMatch extends UpcomingItem {
  const UpcomingMatch(this.slot);

  final PrioritySlot slot;

  @override
  Day get date => slot.date;
  @override
  HourMinute get startsAt => slot.startsAt;
}

class UpcomingDay {
  UpcomingDay(this.date, this.items);

  final Day date;
  final List<UpcomingItem> items;
}

/// The colour to tint [slot]'s trophy in Můj přehled (0036, `team_colors`):
/// first pick WHICH of its two teams is [followedTeams]' own — home wins
/// when both are followed, same as `upcomingTimeline` already did to decide
/// the match belongs on this list at all — then take THAT team's shared
/// colour, or null if it has none. No fall-through to the other team's
/// colour: a colour set on a team the player does not follow must never
/// paint a match that is only showing because of the OTHER team (e.g. the
/// player follows only 'KS Devítka Brno B' and once coloured 'SKK Veverky
/// Brno A' red — their derby must show no colour at all, not Veverky's
/// red). `my_future_matches` (SQL, 0036) resolves the SAME shape — home
/// wins, then that team's colour, no fall-through — but over
/// `calendar_teams`, the calendar's own (deliberately different) team
/// list: the tie-break shape is shared, the list it runs over is not.
///
/// A match the player is playing as a GUEST (0039, `match_exceptions`) is on
/// the list without either of its teams being followed — there is no
/// followed team to take a colour from, so it takes the colour of OUR side
/// of the match (`isAway` says which side that is), which is what the alley
/// calls its own team. `my_future_matches` falls back the same way, so the
/// trophy and the Google event still agree.
int? matchColorOf(
  PrioritySlot slot,
  List<String> followedTeams,
  Map<String, int> teamColors, {
  Set<String> exceptions = const {},
}) {
  final team = followedTeams.contains(slot.homeTeam)
      ? slot.homeTeam
      : followedTeams.contains(slot.awayTeam)
          ? slot.awayTeam
          : exceptions.contains(slot.id)
              ? (slot.isAway ? slot.awayTeam : slot.homeTeam)
              : null;
  return team == null ? null : teamColors[team];
}

/// The matches worth offering on the Výjimky screen: upcoming matches the
/// player would NOT otherwise have.
///
/// "Would have" means both halves of what an exception grants — the match in
/// Můj přehled (a [followed] team) and, where a calendar is linked, the
/// match in the MAIN Google calendar (a [routed] team pointed at
/// `primary`). A team followed but routed to the second calendar is the
/// interesting case: its matches are on the list, because saying "I am
/// playing this one" is exactly how one match of it comes over to the main
/// calendar. Everything already excepted stays listed, or there would be no
/// way to take it back.
List<PrioritySlot> exceptionCandidates({
  required List<PrioritySlot> slots,
  required List<String> followed,
  required List<CalendarTeam> routed,
  required bool hasCalendar,
  required Set<String> exceptions,
  required Day today,
}) {
  bool mine(String team) {
    if (!followed.contains(team)) return false;
    if (!hasCalendar) return true;
    return routed.any((r) => r.team == team && r.calendar == CalendarSlot.primary);
  }

  return [
    for (final s in slots)
      if (s.type.isMatch && s.parentId == null && !s.date.isBefore(today))
        if (exceptions.contains(s.id) || !(mine(s.homeTeam) || mine(s.awayTeam)))
          s,
  ]..sort((a, b) => compareDayTime(a.date, a.startsAt, b.date, b.startsAt));
}

/// Live reservations from [today] on whose block still exists, plus match
/// slots (no úklid children) of [teams] from [today] on; days ascending,
/// within a day by start (chronological, `compareDayTime`), a training
/// before a match at the same start, and two tied trainings by lane.
List<UpcomingDay> upcomingTimeline({
  required List<Reservation> reservations,
  required List<TimeBlock> blocks,
  required List<PrioritySlot> slots,
  required List<String> teams,
  required Day today,
  Set<String> exceptions = const {},
}) {
  final blockById = {for (final b in blocks) b.id: b};
  final items = <UpcomingItem>[
    for (final r in reservations)
      if (r.isLive && !r.date.isBefore(today))
        if (blockById[r.blockId] case final block?)
          UpcomingTraining(r, block),
    for (final s in slots)
      if (s.type.isMatch && s.parentId == null && !s.date.isBefore(today))
        // A followed team's match, or one the player said they are playing
        // (0039) — which is the whole of what an exception does here.
        if (teams.contains(s.homeTeam) ||
            teams.contains(s.awayTeam) ||
            exceptions.contains(s.id))
          UpcomingMatch(s),
  ];
  items.sort((a, b) {
    final byDayTime = compareDayTime(a.date, a.startsAt, b.date, b.startsAt);
    if (byDayTime != 0) return byDayTime;
    final byKind = (a is UpcomingMatch ? 1 : 0) - (b is UpcomingMatch ? 1 : 0);
    if (byKind != 0) return byKind;
    // Two of the player's own trainings tied on date/start (same block):
    // break by lane so the order is deterministic instead of whatever the
    // reservations stream happened to deliver.
    if (a is UpcomingTraining && b is UpcomingTraining) {
      return a.reservation.lane.compareTo(b.reservation.lane);
    }
    return 0;
  });
  final days = <UpcomingDay>[];
  for (final item in items) {
    if (days.isNotEmpty && days.last.date == item.date) {
      days.last.items.add(item);
    } else {
      days.add(UpcomingDay(item.date, [item]));
    }
  }
  return days;
}

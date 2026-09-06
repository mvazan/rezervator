/// What is coming for a player: their live future reservations and the
/// future matches of the teams they follow, one timeline by day. Pure Dart,
/// unit-tested; the screen only renders it.
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

/// Live reservations from [today] on whose block still exists, plus match
/// slots (no úklid children) of [teams] from [today] on; days ascending,
/// within a day by start, a training before a match at the same start.
List<UpcomingDay> upcomingTimeline({
  required List<Reservation> reservations,
  required List<TimeBlock> blocks,
  required List<PrioritySlot> slots,
  required List<String> teams,
  required Day today,
}) {
  final blockById = {for (final b in blocks) b.id: b};
  final items = <UpcomingItem>[
    for (final r in reservations)
      if (r.isLive && !r.date.isBefore(today))
        if (blockById[r.blockId] case final block?)
          UpcomingTraining(r, block),
    for (final s in slots)
      if (s.type.isMatch && s.parentId == null && !s.date.isBefore(today))
        if (teams.contains(s.homeTeam) || teams.contains(s.awayTeam))
          UpcomingMatch(s),
  ];
  items.sort((a, b) {
    final byDate = a.date.compareTo(b.date);
    if (byDate != 0) return byDate;
    final byStart = a.startsAt.compareTo(b.startsAt);
    if (byStart != 0) return byStart;
    return (a is UpcomingMatch ? 1 : 0) - (b is UpcomingMatch ? 1 : 0);
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

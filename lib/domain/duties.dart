/// Služby na kantýně (0050), the pure half: the generator's preview, the
/// seasons and their counts, the Kalendář week header and "my duty". Pure
/// Dart over the `duty_periods`, `duty_assignments` and `duty_seasons` rows,
/// unit-tested; the screens only render it. The rights themselves are the
/// server's (`is_on_duty()` / `duty_gate()` for booking and cancelling,
/// `duty_edit_gate()` for the blocks of a day, in 0050_canteen_duty.sql) —
/// the app only hides what the server would refuse.
library;

import 'collation.dart';
import 'labels.dart' show czechCount;
import 'models.dart';

const _weekdays = ['po', 'út', 'st', 'čt', 'pá', 'so', 'ne'];

// ---------------------------------------------------------------------------
// Labels
// ---------------------------------------------------------------------------

/// „po 5. 10.“ — a duty's day as Správa → Služby, Klubovna → Služby and the
/// reminder (`_shared/duty_reminders.ts`) write it.
String dutyDayLabel(Day day) =>
    '${_weekdays[day.weekday - 1]} ${day.day}. ${day.month}.';

/// „po 5. 10. – ne 11. 10.“; a one-day duty names its day once.
String dutyRangeLabel(DutyPeriod period) => period.startsOn == period.endsOn
    ? dutyDayLabel(period.startsOn)
    : '${dutyDayLabel(period.startsOn)} – ${dutyDayLabel(period.endsOn)}';

/// [names] as a Czech list: „A“, „A a B“, „A, B a C“; '' for none. Keeps
/// the order it is given — sort with [compareCzech] first.
String joinNames(List<String> names) => switch (names.length) {
  0 => '',
  1 => names.single,
  _ => '${names.sublist(0, names.length - 1).join(', ')} a ${names.last}',
};

// ---------------------------------------------------------------------------
// The generator's preview
// ---------------------------------------------------------------------------

/// What `duty_generate` would do with a range — the generator dialog's
/// live preview („Vznikne 40 služeb, poslední zkrácená na 3 dny. 2 se
/// překrývají a přeskočí se.“).
class DutyPlan {
  const DutyPlan({
    this.periods = const [],
    this.skipped = 0,
    this.lastClippedDays,
    this.error,
  });

  /// The periods it would create, chronological.
  final List<({Day startsOn, Day endsOn})> periods;

  /// How many would overlap an existing period and be skipped whole.
  final int skipped;

  /// The length of the last created period when the end of the range cut
  /// it short; null when it runs its full length, or nothing is created.
  final int? lastClippedDays;

  /// The code `duty_generate` would raise instead — `invalid_days` or
  /// `invalid_range` — and then nothing is planned; null for a valid range.
  final String? error;

  int get created => periods.length;
}

/// Mirrors `duty_generate(p_from, p_days, p_until)`: periods
/// `[s, min(s + days − 1, until)]` for s = [from], from + [days], … up to
/// [until], so the last one is clipped. A period overlapping one of
/// [existing] (both ends included) is skipped whole, which makes a second
/// run over the same range create nothing. [days] must be 1–31
/// (`invalid_days`); [until] not before [from] and the range at most 400
/// days, both ends counted (`invalid_range`) — checked in the SQL's order.
DutyPlan planDutyPeriods(
  Day from,
  int days,
  Day until,
  Iterable<DutyPeriod> existing,
) {
  if (days < 1 || days > 31) return const DutyPlan(error: 'invalid_days');
  if (until.isBefore(from) || until.differenceInDays(from) + 1 > 400) {
    return const DutyPlan(error: 'invalid_range');
  }
  final taken = existing.toList();
  final periods = <({Day startsOn, Day endsOn})>[];
  var skipped = 0;
  int? lastClippedDays;
  for (var start = from; !start.isAfter(until); start = start.addDays(days)) {
    final full = start.addDays(days - 1);
    final end = full.isAfter(until) ? until : full;
    final overlaps = taken.any(
      (p) => !p.startsOn.isAfter(end) && !p.endsOn.isBefore(start),
    );
    if (overlaps) {
      skipped++;
      continue;
    }
    periods.add((startsOn: start, endsOn: end));
    // Only the range's last period can be clipped, so a later created one
    // resets this and a skipped last one leaves it null.
    lastClippedDays = end == full ? null : end.differenceInDays(start) + 1;
  }
  return DutyPlan(
    periods: periods,
    skipped: skipped,
    lastClippedDays: lastClippedDays,
  );
}

// ---------------------------------------------------------------------------
// Periods and assignees
// ---------------------------------------------------------------------------

/// The period covering [day] — at most one, as periods never overlap — or
/// null.
DutyPeriod? periodOn(Iterable<DutyPeriod> periods, Day day) {
  for (final period in periods) {
    if (period.covers(day)) return period;
  }
  return null;
}

/// The users assigned to [periodId], in no particular order.
List<String> assigneeIds(
  Iterable<DutyAssignment> assignments,
  String periodId,
) => [
  for (final a in assignments)
    if (a.periodId == periodId) a.userId,
];

// ---------------------------------------------------------------------------
// Seasons and counts
// ---------------------------------------------------------------------------

/// One season of the duty counts: from its boundary until the day before
/// the next one. A period belongs to the season its first day falls in, so
/// one straddling a boundary stays in the season where it started.
class SeasonRange {
  const SeasonRange({this.season, this.from, this.until});

  /// The boundary row; null for the implicit first season — the periods
  /// before the first boundary.
  final DutySeason? season;

  /// The first day; null for the implicit first season (since ever).
  final Day? from;

  /// The last day, included; null for the newest season (still open).
  final Day? until;

  /// The boundary's name („2026/27“); null for the implicit first season.
  String? get name => season?.name;

  bool get isImplicit => season == null;

  bool contains(Day day) =>
      (from == null || !day.isBefore(from!)) &&
      (until == null || !day.isAfter(until!));

  /// Whether [period] counts in this season: its first day is in it.
  bool containsPeriod(DutyPeriod period) => contains(period.startsOn);
}

/// Every season, chronological: the implicit first season, then one per
/// boundary of [seasons] (in any order). The ranges cover the whole
/// timeline without a gap or an overlap; the implicit one is always there,
/// even when no period falls in it.
List<SeasonRange> seasonRanges(Iterable<DutySeason> seasons) {
  final sorted = [...seasons]
    ..sort((a, b) => a.startedOn.compareTo(b.startedOn));
  return [
    SeasonRange(
      until: sorted.isEmpty ? null : sorted.first.startedOn.addDays(-1),
    ),
    for (final (i, season) in sorted.indexed)
      SeasonRange(
        season: season,
        from: season.startedOn,
        until: i + 1 < sorted.length
            ? sorted[i + 1].startedOn.addDays(-1)
            : null,
      ),
  ];
}

/// The season of [ranges] (from [seasonRanges]) that holds [today]. Not
/// simply the last one: an admin may start a season from a future date.
SeasonRange currentSeason(List<SeasonRange> ranges, Day today) =>
    ranges.firstWhere((r) => r.contains(today), orElse: () => ranges.last);

/// The name a season starting on [day] gets by default — the July–June
/// year the generator's default end (30. 6.) closes: „2026/27“ from
/// 1. 7. 2026 to 30. 6. 2027.
String seasonNameFor(Day day) {
  final first = day.month >= 7 ? day.year : day.year - 1;
  return '$first/${((first + 1) % 100).toString().padLeft(2, '0')}';
}

/// The last day of [day]'s July–June year: the next 30. 6., [day] itself
/// included — the generator's default „Do“.
Day seasonEndFor(Day day) =>
    Day(day.month >= 7 ? day.year + 1 : day.year, 6, 30);

/// One player's duties in a season: how many periods, how many days those
/// cover, and how many of them are over.
class DutyCount {
  const DutyCount({this.duties = 0, this.days = 0, this.served = 0});

  static const zero = DutyCount();

  final int duties;
  final int days;

  /// Duties whose last day is behind today (odslouženy).
  final int served;

  @override
  bool operator ==(Object other) =>
      other is DutyCount &&
      other.duties == duties &&
      other.days == days &&
      other.served == served;

  @override
  int get hashCode => Object.hash(duties, days, served);

  @override
  String toString() => 'DutyCount($duties, $days days, $served served)';
}

/// Per user: their duties among the periods that belong to [season]. A duty
/// is served once its last day is over by [today]. Players without a duty
/// in the season are missing — Přehled sezóny lists them with
/// [DutyCount.zero]. Computed from the unfiltered streams, so a season
/// counts right from its first day to its last.
Map<String, DutyCount> dutyCounts(
  Iterable<DutyPeriod> periods,
  Iterable<DutyAssignment> assignments,
  SeasonRange season, {
  required Day today,
}) {
  final inSeason = {
    for (final p in periods)
      if (season.containsPeriod(p)) p.id: p,
  };
  final counts = <String, DutyCount>{};
  for (final a in assignments) {
    final period = inSeason[a.periodId];
    if (period == null) continue;
    final count = counts[a.userId] ?? DutyCount.zero;
    counts[a.userId] = DutyCount(
      duties: count.duties + 1,
      days: count.days + period.days,
      served: count.served + (period.endsOn.isBefore(today) ? 1 : 0),
    );
  }
  return counts;
}

/// Přehled sezóny's count: „3 služby · 21 dní (2 odslouženy)“, without the
/// parenthesis while none is served yet, and „—“ for no duty at all.
String dutyCountLabel(DutyCount count) {
  if (count.duties == 0) return '—';
  final text =
      '${czechCount(count.duties, 'služba', 'služby', 'služeb')} · '
      '${czechCount(count.days, 'den', 'dny', 'dní')}';
  if (count.served == 0) return text;
  return '$text '
      '(${czechCount(count.served, 'odsloužena', 'odslouženy', 'odslouženo')})';
}

/// „1 den“, „2 dny“, „týden“ — the reminder's lead as Správa → Služby
/// offers it and Klubovna → Služby says it („Připomínku dostaneš 1 den
/// předem.“).
String dutyLeadLabel(int days) =>
    days == 7 ? 'týden' : czechCount(days, 'den', 'dny', 'dní');

/// Klubovna → Služby's list over [today]: the period running today (at most
/// one — periods never overlap), the ones ahead and the ones over, both in
/// date order. A period ending today still runs.
({DutyPeriod? current, List<DutyPeriod> upcoming, List<DutyPeriod> past})
splitDuties(Iterable<DutyPeriod> periods, Day today) {
  final sorted = [...periods]..sort((a, b) => a.startsOn.compareTo(b.startsOn));
  return (
    current: periodOn(sorted, today),
    upcoming: [
      for (final p in sorted)
        if (p.startsOn.isAfter(today)) p,
    ],
    past: [
      for (final p in sorted)
        if (p.endsOn.isBefore(today)) p,
    ],
  );
}

// ---------------------------------------------------------------------------
// The week header and my duty
// ---------------------------------------------------------------------------

/// The Kalendář week header's duty line.
class DutyHeader {
  const DutyHeader(this.text, {this.mine = false});

  final String text;

  /// „Sloužíš ty …“ — the header tints the line.
  final bool mine;

  @override
  bool operator ==(Object other) =>
      other is DutyHeader && other.text == text && other.mine == mine;

  @override
  int get hashCode => Object.hash(text, mine);

  @override
  String toString() => 'DutyHeader($text${mine ? ', mine' : ''})';
}

/// Who serves in the week of [monday], for the line under the week range:
///
/// * one period for the whole week: „Služba: Jan Novák a Petr Svoboda“;
/// * a change inside the week: „Služba: po–st Jan Novák · čt–ne Petr
///   Svoboda“ — each period's days within the week (one day named once);
/// * when [meId] is on duty [today] and the week holds today: „Sloužíš ty ·
///   do ne 11. 10.“, plus „ · spolu s: …“ (Czech-sorted) when others share
///   the period, [DutyHeader.mine];
/// * null when no one serves that week — no period, or only unassigned ones.
///
/// Wherever the lines list who serves, I am „ty“, not my name — after the
/// others, whatever the alphabet says („Služba: Petr Svoboda a ty“, „Služba:
/// po–st ty · čt–ne Petr Svoboda“) — even when the roster does not know me.
///
/// [names] maps user ids to display names (placeholders included); an id
/// it does not know is left out, and each period's names are
/// Czech-sorted. A period without a known name says nothing; adjacent
/// periods with the same names are one part („po–ne ty“, not „po–st ty ·
/// čt–ne ty“).
DutyHeader? dutyHeaderLabel(
  Day monday,
  Iterable<DutyPeriod> periods,
  Iterable<DutyAssignment> assignments,
  Map<String, String> names,
  String? meId, {
  required Day today,
}) {
  final sunday = monday.addDays(6);
  if (!today.isBefore(monday) && !today.isAfter(sunday)) {
    final my = myDuty(periods, assignments, meId, today);
    final current = my.current;
    if (current != null) {
      final co = [for (final id in my.coAssignees) ?names[id]]
        ..sort(compareCzech);
      final withCo = co.isEmpty ? '' : ' · spolu s: ${joinNames(co)}';
      return DutyHeader(
        'Sloužíš ty · do ${dutyDayLabel(current.endsOn)}$withCo',
        mine: true,
      );
    }
  }

  final inWeek = [
    for (final p in periods)
      if (!p.startsOn.isAfter(sunday) && !p.endsOn.isBefore(monday)) p,
  ]..sort((a, b) => a.startsOn.compareTo(b.startsOn));
  // The days of each period inside the week, with who serves; adjacent
  // periods (the next starts the day after the previous ends) with the very
  // same names are one part — „po–st ty · čt–ne ty“ would say it twice.
  final parts = <(Day, Day, String)>[];
  for (final period in inWeek) {
    final ids = assigneeIds(assignments, period.id);
    final who = [
      for (final id in ids)
        if (id != meId) ?names[id],
    ]..sort(compareCzech);
    // I am „ty“, last — like in a message's reaction line.
    if (meId != null && ids.contains(meId)) who.add('ty');
    if (who.isEmpty) continue;
    final from = period.startsOn.isBefore(monday) ? monday : period.startsOn;
    final to = period.endsOn.isAfter(sunday) ? sunday : period.endsOn;
    final text = joinNames(who);
    if (parts.isNotEmpty) {
      final (lastFrom, lastTo, lastWho) = parts.last;
      if (lastWho == text && lastTo.addDays(1) == from) {
        parts[parts.length - 1] = (lastFrom, to, text);
        continue;
      }
    }
    parts.add((from, to, text));
  }
  if (parts.isEmpty) return null;

  if (parts.length == 1) {
    final (from, to, who) = parts.single;
    if (from == monday && to == sunday && inWeek.length == 1) {
      return DutyHeader('Služba: $who');
    }
  }
  String days(Day from, Day to) {
    final first = _weekdays[from.weekday - 1];
    return from == to ? first : '$first–${_weekdays[to.weekday - 1]}';
  }

  return DutyHeader(
    'Služba: ${[for (final (from, to, who) in parts) '${days(from, to)} $who'].join(' · ')}',
  );
}

/// The signed-in player's duty, for Klubovna → Služby's card and the
/// calendar's rights. The rights have two clocks (0050): booking and
/// cancelling for others is held WHILE on duty ([onDuty], a period covering
/// today), editing the blocks of a day on the days of my OWN periods
/// ([coversDay]), on duty today or not.
class MyDuty {
  const MyDuty({
    this.current,
    this.next,
    this.mine = const [],
    this.coAssignees = const [],
  });

  static const none = MyDuty();

  /// My period covering today; null when I am not on duty.
  final DutyPeriod? current;

  /// My earliest period starting after today, whether or not I am on duty
  /// now.
  final DutyPeriod? next;

  /// Every period of mine that has not ended — the running one and all
  /// those ahead, chronological. What is over is left out: nothing in the
  /// past can be edited anyway.
  final List<DutyPeriod> mine;

  /// The others on [current] („spolu s: …“), as user ids in no particular
  /// order — sort their names with [compareCzech]. Empty off duty.
  final List<String> coAssignees;

  /// Assigned to a period covering today. The server says the same for an
  /// approved account player (`is_on_duty()`); an admin passes anyway. The
  /// clock of booking and cancelling for others — not of editing blocks,
  /// see [coversDay].
  bool get onDuty => current != null;

  /// Whether one of my periods covers [day]: the days whose blocks I may
  /// edit (`duty_edit_gate()`), whether or not I am on duty today — a duty
  /// next week Monday to Wednesday covers those three days from now on.
  /// The past is not judged here: a running period covers its own past
  /// days too, and the gestures refuse those (the server: `date_past`).
  bool coversDay(Day day) => mine.any((period) => period.covers(day));

  /// The first day on or after [from] that one of my periods covers — where
  /// a day to edit or to write about starts: today while I am on duty, else
  /// the first day of my next period. Null when none is left.
  Day? firstDayFrom(Day from) {
    Day? first;
    for (final period in mine) {
      if (period.endsOn.isBefore(from)) continue;
      final start = period.startsOn.isAfter(from) ? period.startsOn : from;
      if (first == null || start.isBefore(first)) first = start;
    }
    return first;
  }

  /// The last day of my latest period that has not ended; null with none.
  /// The far end of the days I may edit or write about.
  Day? get lastDay {
    Day? last;
    for (final period in mine) {
      if (last == null || period.endsOn.isAfter(last)) last = period.endsOn;
    }
    return last;
  }

  @override
  bool operator ==(Object other) =>
      other is MyDuty &&
      other.current == current &&
      other.next == next &&
      _samePeriods(other.mine, mine) &&
      _sameIds(other.coAssignees, coAssignees);

  @override
  int get hashCode => Object.hash(
    current,
    next,
    Object.hashAll(mine),
    Object.hashAll(coAssignees),
  );

  @override
  String toString() =>
      'MyDuty(current: $current, next: $next, mine: $mine, '
      'with: $coAssignees)';
}

bool _samePeriods(List<DutyPeriod> a, List<DutyPeriod> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _sameIds(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// [meId]'s duty on [today] (see [MyDuty]); [MyDuty.none] for nobody signed
/// in, or no duty now or ahead. A period that starts or ends today is the
/// current one, and one that ends today has not ended yet ([MyDuty.mine]).
MyDuty myDuty(
  Iterable<DutyPeriod> periods,
  Iterable<DutyAssignment> assignments,
  String? meId,
  Day today,
) {
  if (meId == null) return MyDuty.none;
  final mineIds = {
    for (final a in assignments)
      if (a.userId == meId) a.periodId,
  };
  DutyPeriod? current;
  DutyPeriod? next;
  final ahead = <DutyPeriod>[];
  for (final period in periods) {
    if (!mineIds.contains(period.id)) continue;
    if (!period.endsOn.isBefore(today)) ahead.add(period);
    if (period.covers(today)) {
      current = period;
    } else if (period.startsOn.isAfter(today) &&
        (next == null || period.startsOn.isBefore(next.startsOn))) {
      next = period;
    }
  }
  return MyDuty(
    current: current,
    next: next,
    mine: ahead..sort((a, b) => a.startsOn.compareTo(b.startsOn)),
    coAssignees: current == null
        ? const []
        : [
            for (final id in assigneeIds(assignments, current.id))
              if (id != meId) id,
          ],
  );
}

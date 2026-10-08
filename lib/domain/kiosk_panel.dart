/// The kiosk's side panel, the pure half: which notices are up, which matches
/// the list shows and which one is being played. Pure Dart, unit-tested;
/// `KioskInfoPanel` only renders it.
library;

import 'messages.dart' show splitNotices;
import 'models.dart';

/// The notices on the wall right now: kind notice, not expired, not hidden
/// from the kiosk by the admin, oldest posted first (the Nástěnka order).
List<Message> kioskNotices(Iterable<Message> messages, DateTime now) =>
    splitNotices(
      messages.where((m) => m.kind == MessageKind.notice && m.showOnKiosk),
      now,
    ).active;

bool _decided(MatchResult? r) =>
    r?.status == MatchStatus.finished || r?.status == MatchStatus.forfeit;

/// The competition year [today] is in: from 1 July to 30 June of the next
/// calendar year. The drawer never lists a match outside it.
({Day start, Day end}) kioskSeason(Day today) {
  final year = today.month >= 7 ? today.year : today.year - 1;
  return (start: Day(year, 7, 1), end: Day(year + 1, 6, 30));
}

/// The Monday of [day]'s ISO week.
Day mondayOf(Day day) => day.addDays(1 - day.weekday);

/// The matches the drawer lists, chronological.
typedef KioskMatchWindow = ({
  List<PrioritySlot> matches,

  /// There are matches of the season before the first listed day.
  bool moreBefore,

  /// There are matches of the season after the last listed day.
  bool moreAfter,
});

/// The alley's federation matches from [weeksBack] weeks before the current
/// week to [weeksAhead] weeks after it (the league plays in rounds a week
/// apart), both counted from the current Monday/Sunday and widened by
/// [extraBack]/[extraAhead] weeks the visitor asked for with „Zobrazit
/// další“. With [showUpcoming] off nothing after today is listed. Never
/// outside the current season ([kioskSeason]).
KioskMatchWindow kioskMatchWindow({
  required List<PrioritySlot> slots,
  required Day today,
  required int weeksBack,
  required int weeksAhead,
  required bool showUpcoming,
  int extraBack = 0,
  int extraAhead = 0,
}) {
  final season = kioskSeason(today);
  final thisMonday = mondayOf(today);
  var from = thisMonday.addDays(-7 * (weeksBack + extraBack));
  var to = showUpcoming
      ? thisMonday.addDays(6 + 7 * (weeksAhead + extraAhead))
      : today;
  if (from.isBefore(season.start)) from = season.start;
  if (to.isAfter(season.end)) to = season.end;
  final all = [
    for (final s in slots)
      if (s.type.isMatch &&
          s.parentId == null &&
          s.fromFederation &&
          !s.date.isBefore(season.start) &&
          !s.date.isAfter(season.end))
        s,
  ]..sort((a, b) {
      final byDay = a.date.compareTo(b.date);
      return byDay != 0 ? byDay : a.startsAt.compareTo(b.startsAt);
    });
  return (
    matches: [
      for (final s in all)
        if (!s.date.isBefore(from) && !s.date.isAfter(to)) s,
    ],
    moreBefore: all.any((s) => s.date.isBefore(from)),
    moreAfter: showUpcoming && all.any((s) => s.date.isAfter(to)),
  );
}

/// The match the list ends on when it opens (Výsledky's rule: as many
/// played and playing matches as fit above it): the first coming match —
/// from today on, neither decided nor being played — else the last one.
/// -1 for no match at all.
int kioskFirstUpcomingIndex(
  List<PrioritySlot> matches,
  Map<String, MatchResult> results,
  Day today,
) {
  for (var i = 0; i < matches.length; i++) {
    final r = results[matches[i].id];
    if (!matches[i].date.isBefore(today) &&
        !_decided(r) &&
        r?.status != MatchStatus.inProgress) {
      return i;
    }
  }
  return matches.length - 1;
}

/// The matches being played whose figures the drawer can show: status in
/// progress AND [withData] says the site has delivered their players — a
/// match merely marked as playing has nothing to put on the drawer yet.
/// Chronological, so the rotation order is stable.
List<PrioritySlot> kioskLiveMatches({
  required List<PrioritySlot> slots,
  required Map<String, MatchResult> results,
  required Set<String> withData,
}) {
  return [
    for (final s in slots)
      if (s.type.isMatch &&
          s.parentId == null &&
          s.fromFederation &&
          results[s.id]?.status == MatchStatus.inProgress &&
          withData.contains(s.id))
        s,
  ]..sort((a, b) {
      final byDay = a.date.compareTo(b.date);
      return byDay != 0 ? byDay : a.startsAt.compareTo(b.startsAt);
    });
}

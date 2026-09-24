/// Klubovna's "Výsledky" card: pure helpers over the federation's matches
/// and results (0045) — what's live, how the score reads, which matches show
/// on the timeline. Pure Dart, unit-tested; the screens (Task 2+) only
/// render it.
library;

import 'collation.dart';
import 'models.dart';
import 'upcoming.dart' show matchIsMine;

/// Whether [slot]'s live score/video are worth polling right now — mirrors
/// `refresh_match`'s own gate (0045) so the button and the background fetch
/// agree on what "live" means. [result] null (nothing fetched yet) reads as
/// [MatchStatus.scheduled].
bool isLive(PrioritySlot slot, MatchResult? result, DateTime now) {
  final start = DateTime(
    slot.date.year,
    slot.date.month,
    slot.date.day,
    slot.startsAt.hour,
    slot.startsAt.minute,
  );
  return switch (result?.status ?? MatchStatus.scheduled) {
    MatchStatus.finished || MatchStatus.forfeit => false,
    MatchStatus.preparation || MatchStatus.inProgress => now.isBefore(
      start.add(const Duration(hours: 12)),
    ),
    MatchStatus.scheduled =>
      now.isAfter(start.subtract(const Duration(hours: 1))) &&
          now.isBefore(start.add(const Duration(hours: 6))),
  };
}

/// "2" for a whole point, "2,5" for a half (Czech decimal comma); "–" when
/// there is nothing to show.
String numLabel(num? v) {
  if (v == null) return '–';
  if (v == v.roundToDouble()) return v.toInt().toString();
  return v.toString().replaceAll('.', ',');
}

/// "5 : 3", "2,5 : 5,5", or "–" before the match has any points.
String pointsLabel(num? home, num? away) => home == null && away == null
    ? '–'
    : '${numLabel(home)} : ${numLabel(away)}';

/// "3460 : 3349", or '' before the match has a pin count (the row then omits
/// this column instead of showing a bare dash).
String pinsLabel(int? home, int? away) {
  if (home == null && away == null) return '';
  String s(int? v) => v?.toString() ?? '–';
  return '${s(home)} : ${s(away)}';
}

enum MatchSide { home, away }

/// Which side won on points, or null when it's a draw, or either points
/// value is missing.
MatchSide? winningSide(num? home, num? away) {
  if (home == null || away == null || home == away) return null;
  return home > away ? MatchSide.home : MatchSide.away;
}

/// "6 hráčů · 120 HS" from the site's own codes (`TEAMS_OF_6`/`TEAMS_OF_4`,
/// `T100`/`T120`) — Czech numeral agreement (2–4 "hráči", else "hráčů").
/// Either half is simply omitted when its code is empty or unrecognised.
String formatLabel(String matchType, String discipline) {
  final playersMatch = RegExp(r'^TEAMS_OF_(\d+)$').firstMatch(matchType);
  String? players;
  if (playersMatch != null) {
    final n = int.parse(playersMatch.group(1)!);
    final word = n == 1 ? 'hráč' : (n >= 2 && n <= 4 ? 'hráči' : 'hráčů');
    players = '$n $word';
  }
  final hsMatch = RegExp(r'^T(\d+)$').firstMatch(discipline);
  final hs = hsMatch == null ? null : '${hsMatch.group(1)} HS';
  return [?players, ?hs].join(' · ');
}

/// Whether [r] has a real, on-the-board score worth showing — as opposed to
/// a `match_results` row the sync created ahead of kickoff (status
/// `scheduled`/`preparation`, all points still null). A different question
/// than [isLive], which other code still needs unchanged for refresh timing.
bool hasScoreData(MatchResult? r) =>
    r != null &&
    (r.status == MatchStatus.inProgress ||
        r.status == MatchStatus.finished ||
        r.status == MatchStatus.forfeit);

/// Which side `MatchTitle` (`widgets/match_title.dart`) should weight for
/// [r] — null before there's real score data ([hasScoreData]), otherwise
/// whoever's ahead ([winningSide]), final or not. The one place the day
/// dialog, Výsledky and Můj přehled all compute this, so the three can't
/// drift apart on what counts as "the winner to show".
MatchSide? displayWinner(MatchResult? r) =>
    hasScoreData(r) ? winningSide(r!.homePoints, r.awayPoints) : null;

/// "právě teď" / "před N min" / "před N h" / "před N dny" — how long ago
/// [fetchedAt] was, for the match detail's "Výsledky z webu:" line.
String freshnessLabel(DateTime fetchedAt, DateTime now) {
  final diff = now.difference(fetchedAt);
  if (diff.inMinutes < 1) return 'právě teď';
  if (diff.inMinutes < 60) return 'před ${diff.inMinutes} min';
  if (diff.inHours < 24) return 'před ${diff.inHours} h';
  return diff.inDays == 1 ? 'před 1 dnem' : 'před ${diff.inDays} dny';
}

/// The Czech-sorted [venues] whose name, address or a club matches [query]
/// (accent- and case-insensitive); an empty query keeps everything.
List<Venue> venuesMatching(List<Venue> venues, String query) {
  final q = foldDiacritics(query.trim()).toLowerCase();
  bool hit(String s) => foldDiacritics(s).toLowerCase().contains(q);
  return [
    for (final v in venues)
      if (q.isEmpty || hit(v.name) || hit(v.address ?? '') || v.clubs.any(hit))
        v,
  ]..sort((a, b) => compareCzech(a.name, b.name));
}

/// The Klubovna "Výsledky" list: federation matches (never manual/xlsx rows,
/// never their úklid children) grouped by day, days ascending and each day's
/// matches by start time then title. [team] (an exact team name) wins over
/// [mineOnly]/[followedTeams]/[exceptions] when given; otherwise [mineOnly]
/// applies the same "is this mine" rule as Můj přehled ([matchIsMine]).
List<({Day day, List<PrioritySlot> matches})> resultsTimeline({
  required List<PrioritySlot> slots,
  String? team,
  required bool mineOnly,
  required List<String> followedTeams,
  required Map<String, bool> exceptions,
}) {
  final filtered = [
    for (final s in slots)
      if (s.type.isMatch && s.parentId == null && s.fromFederation)
        if (team != null
            ? (s.homeTeam == team || s.awayTeam == team)
            : (!mineOnly || matchIsMine(s, followedTeams, exceptions)))
          s,
  ];
  final byDay = <Day, List<PrioritySlot>>{};
  for (final s in filtered) {
    (byDay[s.date] ??= []).add(s);
  }
  final days = byDay.keys.toList()..sort();
  return [
    for (final day in days)
      (
        day: day,
        matches: byDay[day]!
          ..sort((a, b) {
            final byStart = a.startsAt.compareTo(b.startsAt);
            return byStart != 0 ? byStart : compareCzech(a.title, b.title);
          }),
      ),
  ];
}

/// Which day of [days] (as [resultsTimeline] returns them, ascending) the
/// list should open on: the first at or after [today], else the last one
/// (the season is over), else -1 (nothing to show).
int todayIndex(List<({Day day, List<PrioritySlot> matches})> days, Day today) {
  if (days.isEmpty) return -1;
  for (var i = 0; i < days.length; i++) {
    if (!days[i].day.isBefore(today)) return i;
  }
  return days.length - 1;
}

/// The match to scroll Výsledky's bottom edge to: the most recently
/// DECIDED (finished/forfeit) match at or before [today], walking every
/// match in chronological order and keeping the last one that qualifies.
/// Null when nothing has been decided yet — the caller then falls back to
/// [todayIndex]'s day, top-aligned, same as before this feature existed.
String? mostRecentDecidedMatchId(
  List<({Day day, List<PrioritySlot> matches})> days,
  Map<String, MatchResult> results,
  Day today,
) {
  String? found;
  for (final day in days) {
    if (day.day.isAfter(today)) break;
    for (final slot in day.matches) {
      final status = results[slot.id]?.status;
      if (status == MatchStatus.finished || status == MatchStatus.forfeit) {
        found = slot.id;
      }
    }
  }
  return found;
}

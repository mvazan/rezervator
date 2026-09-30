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
/// [MatchStatus.scheduled]. The server also answers `not_live` for a match
/// only switched-off teams of ours play, which this cannot see.
bool isLive(PrioritySlot slot, MatchResult? result, DateTime now) {
  // A match with no time yet (a league match, 0055) is not being played.
  if (!slot.timeKnown) return false;
  final start = DateTime(
    slot.date.year,
    slot.date.month,
    slot.date.day,
    slot.startsAt.hour,
    slot.startsAt.minute,
  );
  return switch (result?.status ?? MatchStatus.scheduled) {
    MatchStatus.finished || MatchStatus.forfeit => false,
    MatchStatus.inProgress => now.isBefore(
      start.add(const Duration(hours: 12)),
    ),
    // The site shows preparation days before some matches: like scheduled,
    // it is live only from an hour before the start.
    MatchStatus.preparation =>
      now.isAfter(start.subtract(const Duration(hours: 1))) &&
          now.isBefore(start.add(const Duration(hours: 12))),
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

/// The team-row "Družstvo" value: the points [side] got for the higher pin
/// total (2 / 0, 1 / 1 on a tie) — kuzelky prints its Body ([sidePoints])
/// minus the duel points its players won. Null (printed '–') until Body and
/// every player's [MatchPlayerResult.teamPoints] of that side are known.
num? teamBonusPoints(
  num? sidePoints,
  List<MatchPlayerResult> players,
  String side,
) {
  if (sidePoints == null) return null;
  num duels = 0;
  var any = false;
  for (final p in players) {
    if (p.side != side) continue;
    final points = p.teamPoints;
    if (points == null) return null;
    duels += points;
    any = true;
  }
  return any ? sidePoints - duels : null;
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

/// Whether set points (SB, „dílčí body“) play a role in a match of
/// [discipline] (`T100`, `T120`): from 120 throws on they decide a duel's
/// point; at 100 they only mirror the lanes and are not shown at all.
bool setPointsMatter(String? discipline) {
  final hs = int.tryParse(RegExp(r'^T(\d+)$').firstMatch(discipline ?? '')?.group(1) ?? '');
  return hs != null && hs >= 120;
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

/// The same over a flat list already in display order
/// (Výsledky's „Soutěže“ view lists rounds, not days): the last DECIDED
/// match dated at or before [today].
String? mostRecentDecidedInOrder(
  Iterable<PrioritySlot> ordered,
  Map<String, MatchResult> results,
  Day today,
) {
  String? found;
  for (final slot in ordered) {
    if (slot.date.isAfter(today)) continue;
    final status = results[slot.id]?.status;
    if (status == MatchStatus.finished || status == MatchStatus.forfeit) {
      found = slot.id;
    }
  }
  return found;
}

/// One round of a competition in Výsledky's „Soutěže“ view.
typedef RoundGroup = ({
  int round,
  Day first,
  Day last,
  List<PrioritySlot> matches,
});

/// The matches of the competition [slug]: every [league] row of it (0055 —
/// the matches no ACTIVE team of ours plays: foreign ones, the ones of a
/// team switched off, ours with no time yet), as slot views, plus our
/// federation matches (a slot whose site slug is `<slug>-kolo-…`, no Úklid
/// child) that no league row stands for. [foreignIds] are the league ones.
/// A switched-off team's match can be both a slot and a league row (the
/// server keeps the row, with its details): listed once, as the league row.
({List<PrioritySlot> matches, Set<String> foreignIds}) competitionMatches(
  List<PrioritySlot> slots,
  List<LeagueMatch> league,
  String slug,
) {
  final rows = [
    for (final l in league)
      if (l.competitionSlug == slug) l,
  ];
  final leagueSiteIds = {for (final l in rows) l.siteMatchId};
  final ours = [
    for (final s in slots)
      if (s.type.isMatch &&
          s.parentId == null &&
          s.fromFederation &&
          (s.siteSlug ?? '').startsWith('$slug-kolo-') &&
          !leagueSiteIds.contains(s.siteMatchId))
        s,
  ];
  return (
    matches: [...ours, for (final l in rows) l.asSlot()],
    foreignIds: {for (final l in rows) l.id},
  );
}

/// [matches] grouped by round. The rounds are NOT played in order (a round
/// is postponed, a team plays two in a week), so the groups go by their
/// first match date, then by round number; inside a round by day, time and
/// title.
List<RoundGroup> competitionRounds(List<PrioritySlot> matches) {
  final byRound = <int, List<PrioritySlot>>{};
  for (final m in matches) {
    (byRound[m.round ?? 0] ??= []).add(m);
  }
  final groups = <RoundGroup>[];
  byRound.forEach((round, items) {
    items.sort((a, b) {
      final byTime = compareDayTime(a.date, a.startsAt, b.date, b.startsAt);
      return byTime != 0 ? byTime : compareCzech(a.title, b.title);
    });
    groups.add((
      round: round,
      first: items.first.date,
      last: items.map((m) => m.date).reduce((a, b) => b.isAfter(a) ? b : a),
      matches: items,
    ));
  });
  groups.sort((a, b) {
    final byDate = a.first.compareTo(b.first);
    return byDate != 0 ? byDate : a.round.compareTo(b.round);
  });
  return groups;
}

/// „9. kolo · 26. 9.“, or over several days „9. kolo · 26.9.–27.9.“; without
/// a round number just the date.
String roundLabel(RoundGroup g) {
  final when = g.first == g.last
      ? '${g.first.day}. ${g.first.month}.'
      : rangeLabel(g.first, g.last);
  return g.round == 0 ? when : '${g.round}. kolo · $when';
}

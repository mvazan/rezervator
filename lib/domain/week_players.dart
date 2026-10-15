/// „Hráči týdne“ on the kiosk (0078), the pure half: the lines of the
/// alley's own players in the previous week's matches, as the server's
/// `kiosk_week_players` returns them, sorted into the rankings the card and
/// its full-screen detail show. Pure Dart, unit-tested; kiosk_week.dart only
/// renders it.
///
/// A ranking is ordered by result, best first — the one deliberate
/// exception to the app's rule that lists go alphabetically or
/// chronologically: a ranking is what the module is. The groups of the
/// detail (competitions, clubs) are still alphabetical.
library;

import 'collation.dart';
import 'kiosk_panel.dart' show mondayOf;
import 'models.dart';

/// A player's gender as the ČKA register gives it (0078).
enum WeekGender { male, female }

/// One line of ours in a finished match of the week: one player's whole
/// game (a substitute's shared line never comes — the server leaves it
/// out).
class WeekLine {
  const WeekLine({
    required this.matchId,
    required this.date,
    required this.playerName,
    this.playerSlug,
    required this.total,
    this.errors = 0,
    this.throws,
    this.isAway = false,
    this.competition,
    this.teamName = '',
    this.opponent = '',
    this.clubId,
    this.clubName,
    this.clubColor = -1,
    this.gender,
  });

  /// The match (`priority_slots.id`): a tap on the line opens its Zápis.
  final String matchId;
  final Day date;
  final String playerName;

  /// The results service's slug of the player; null when the site gave
  /// none.
  final String? playerSlug;

  /// Pins knocked down.
  final int total;
  final int errors;

  /// 120 or 100 throws; null when neither the match's discipline nor its
  /// lanes tell.
  final int? throws;

  /// The alley's home or away, as on the board — not the line's side.
  final bool isAway;
  final String? competition;

  /// Our team, by the app's name for it.
  final String teamName;

  /// The other side's team, as the site names it.
  final String opponent;

  /// Our team's club (`teams.club_id`) and its name and palette colour
  /// (-1 = none); all three empty for a team without a club.
  final String? clubId;
  final String? clubName;
  final int clubColor;

  /// Null = the register has not said (yet).
  final WeekGender? gender;

  factory WeekLine.fromJson(Map<String, dynamic> json) {
    final slug = json['player_slug'] as String?;
    return WeekLine(
      matchId: json['match_id'] as String,
      date: Day.parse(json['date'] as String),
      playerName: json['player_name'] as String? ?? '',
      playerSlug: slug == null || slug.isEmpty ? null : slug,
      total: (json['total'] as num).toInt(),
      errors: (json['errors'] as num?)?.toInt() ?? 0,
      throws: (json['throws'] as num?)?.toInt(),
      isAway: json['is_away'] as bool? ?? false,
      competition: json['competition'] as String?,
      teamName: json['team_name'] as String? ?? '',
      opponent: json['opponent'] as String? ?? '',
      clubId: json['club_id'] as String?,
      clubName: json['club_name'] as String?,
      clubColor: (json['club_color'] as num?)?.toInt() ?? -1,
      // Only the two codes the server writes; anything else is unknown.
      gender: switch (json['gender']) {
        'm' => WeekGender.male,
        'f' => WeekGender.female,
        _ => null,
      },
    );
  }

  /// Who the line is: the slug, else the name — one entry per player in a
  /// ranking ([weekRanked]).
  String get key => playerSlug ?? playerName;

  /// The register could still tell this player's gender: the lookup goes
  /// by the slug, a line without one is never asked about.
  bool get needsGender => playerSlug != null && gender == null;
}

/// The card's and the detail's categories, in this order. A line of an
/// unknown gender or number of throws is in none of them — only in the
/// competitions and the clubs.
enum WeekCategory {
  men120(WeekGender.male, 120, 'Muži · 120 HS'),
  women120(WeekGender.female, 120, 'Ženy · 120 HS'),
  men100(WeekGender.male, 100, 'Muži · 100 HS'),
  women100(WeekGender.female, 100, 'Ženy · 100 HS');

  const WeekCategory(this.gender, this.throws, this.label);

  final WeekGender gender;
  final int throws;
  final String label;
}

/// Best first: more pins, then fewer errors, then the name (Czech
/// alphabetical) and the player's key, so the order never depends on the
/// order the lines came in.
int _better(WeekLine a, WeekLine b) {
  final byTotal = b.total.compareTo(a.total);
  if (byTotal != 0) return byTotal;
  final byErrors = a.errors.compareTo(b.errors);
  if (byErrors != 0) return byErrors;
  final byName = compareCzech(a.playerName, b.playerName);
  if (byName != 0) return byName;
  return a.key.compareTo(b.key);
}

/// [lines] as a ranking: one entry per player ([WeekLine.key]) with his
/// best line — two matches in a week do not take two places — best first.
List<WeekLine> weekRanked(List<WeekLine> lines) {
  final best = <String, WeekLine>{};
  for (final line in lines) {
    final held = best[line.key];
    if (held == null || _better(line, held) < 0) best[line.key] = line;
  }
  return best.values.toList()..sort(_better);
}

/// The places of a [ranked] list: 1, 2, 3 … — equal pins and errors share
/// a place, and the next one skips it (1, 2, 2, 4).
List<int> weekPlaces(List<WeekLine> ranked) {
  final places = <int>[];
  for (final (i, line) in ranked.indexed) {
    final prev = i == 0 ? null : ranked[i - 1];
    places.add(
      prev != null && prev.total == line.total && prev.errors == line.errors
          ? places.last
          : i + 1,
    );
  }
  return places;
}

/// The categories that have a line, each ranked ([weekRanked]), in
/// [WeekCategory] order.
Map<WeekCategory, List<WeekLine>> weekCategories(List<WeekLine> lines) {
  final out = <WeekCategory, List<WeekLine>>{};
  for (final category in WeekCategory.values) {
    final ranked = weekRanked([
      for (final l in lines)
        if (l.gender == category.gender && l.throws == category.throws) l,
    ]);
    if (ranked.isNotEmpty) out[category] = ranked;
  }
  return out;
}

/// The group of the lines without a competition or a club: last, after the
/// named ones (the name picker's word for players without a club).
const weekOtherGroup = 'Ostatní';

/// [lines] by competition, Czech alphabetical, each ranked; lines without a
/// competition last, under [weekOtherGroup].
List<({String name, List<WeekLine> lines})> weekByCompetition(
  List<WeekLine> lines,
) {
  final byName = <String, List<WeekLine>>{};
  final other = <WeekLine>[];
  for (final line in lines) {
    final name = line.competition;
    if (name == null || name.isEmpty) {
      other.add(line);
    } else {
      (byName[name] ??= []).add(line);
    }
  }
  final names = byName.keys.toList()..sort(compareCzech);
  return [
    for (final name in names) (name: name, lines: weekRanked(byName[name]!)),
    if (other.isNotEmpty) (name: weekOtherGroup, lines: weekRanked(other)),
  ];
}

/// [lines] by our team's club, Czech alphabetical by its name, each ranked,
/// with the club's palette colour; the teams without a club last, under
/// [weekOtherGroup] (colour -1).
List<({String name, int color, List<WeekLine> lines})> weekByClub(
  List<WeekLine> lines,
) {
  final byClub = <String, List<WeekLine>>{};
  final other = <WeekLine>[];
  for (final line in lines) {
    final id = line.clubId;
    if (id == null) {
      other.add(line);
    } else {
      (byClub[id] ??= []).add(line);
    }
  }
  final groups = [
    for (final club in byClub.values)
      (
        name: club.first.clubName ?? '',
        color: club.first.clubColor,
        lines: weekRanked(club),
      ),
  ]..sort((a, b) => compareCzech(a.name, b.name));
  return [
    ...groups,
    if (other.isNotEmpty)
      (name: weekOtherGroup, color: -1, lines: weekRanked(other)),
  ];
}

/// [lines] played at home ([away] false), away (true) or all (null).
List<WeekLine> weekWhere(List<WeekLine> lines, {bool? away}) => away == null
    ? lines
    : [
        for (final l in lines)
          if (l.isAway == away) l,
      ];

/// The Monday of the week before [now]'s, by the kiosk's wall clock (the
/// device's zone, Prague): what „Hráči týdne“ shows from Monday 00:00 on.
/// A UTC instant is read on that clock too.
Day previousWeekMonday(DateTime now) =>
    mondayOf(Day.fromDateTime(now.toLocal())).addDays(-7);

/// „5.–11. 10.“ — the week from [monday] to its Sunday, the month once
/// when both days share it („28. 9.–4. 10.“ when not), as the duty band's
/// short range.
String weekRangeLabel(Day monday) {
  final sunday = monday.addDays(6);
  final start = monday.month == sunday.month
      ? '${monday.day}.'
      : '${monday.day}. ${monday.month}.';
  return '$start–${sunday.day}. ${sunday.month}.';
}

/// One week's lines as the kiosk read them, with the Monday they are of:
/// the card's and the detail's titles name this week, not the clock's, so
/// lines kept from an earlier read — one still under way at the week's
/// turn, or a failed one — never stand under another week's dates.
typedef WeekLines = ({Day monday, List<WeekLine> lines});

/// How many times one read asks for the week's genders: each ask covers
/// a limited number of players (regnum-lookup's budget).
const weekGenderRounds = 4;

/// How long one ask for the week's genders may take: the register can be
/// slow or down, and a call can run until the Edge Function is killed —
/// minutes in which the second read would wait.
const weekGenderTimeout = Duration(seconds: 20);

/// The week from [monday] as the kiosk reads it: [read] the lines and hand
/// them on at once — the card shows them however long the register takes.
/// Then, while a line with a slug lacks its gender, [lookup] the genders in
/// rounds while it says there are more (at most [rounds]) and [read] again,
/// handing on the refined lines. The genders are best effort: a failed
/// lookup, or a failed second read, leaves the first read ([onError] hears
/// why). A failed first read is the stream's error.
Stream<WeekLines> loadWeekLines(
  Day monday, {
  required Future<List<WeekLine>> Function(Day monday) read,
  required Future<bool> Function(Day monday) lookup,
  int rounds = weekGenderRounds,
  void Function(Object error)? onError,
}) async* {
  final lines = await read(monday);
  yield (monday: monday, lines: lines);
  if (!lines.any((l) => l.needsGender)) return;
  try {
    for (var round = 0; round < rounds; round++) {
      if (!await lookup(monday)) break;
    }
  } catch (e) {
    // A round before the failed one may have found some: read anyway.
    onError?.call(e);
  }
  final List<WeekLine> refined;
  try {
    refined = await read(monday);
  } catch (e) {
    onError?.call(e);
    return;
  }
  yield (monday: monday, lines: refined);
}

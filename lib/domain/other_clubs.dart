/// The other clubs Správa → Oddíly offers a nickname for (0083): the
/// opponents, by the name that starts their teams' names. Pure Dart,
/// unit-tested.
library;

import 'collation.dart';
import 'models.dart';

/// A team's letter at the end of its name: „TJ Sokol Husovice E“.
final _teamLetter = RegExp(r'\s+[A-Z]$');

/// Every club at the alleys our teams play at ([venues], as the
/// federation's site lists them), every opponent of our [matches] by its
/// team's name without the team's letter, and every club already given a
/// nickname ([nicknames]) — without the alley's own [clubs], by their name
/// or their name on the site (those carry their nickname on their own row,
/// 0080), nor [ourTeams]. The site spells a club differently in different
/// competitions now and then („Slavia“, „Slávia“): the opponents' names
/// list each spelling. Each name once, Czech-sorted.
List<String> otherClubNames({
  required Iterable<Venue> venues,
  required Iterable<Club> clubs,
  required Iterable<ClubNickname> nicknames,
  Iterable<PrioritySlot> matches = const [],
  Iterable<String> ourTeams = const [],
}) {
  final ours = {...ourTeams};
  final own = {
    for (final c in clubs) ...[c.name.trim(), ?c.siteName?.trim()],
  };
  final names = {
    for (final v in venues)
      for (final name in v.clubs) name.trim(),
    for (final m in matches)
      if (m.type.isMatch && m.parentId == null)
        if (m.isAway ? m.homeTeam : m.awayTeam case final opponent
            when !ours.contains(opponent))
          opponent.trim().replaceFirst(_teamLetter, ''),
    for (final n in nicknames) n.name.trim(),
  }..removeWhere((name) => name.isEmpty || own.contains(name));
  return names.toList()..sort(compareCzech);
}

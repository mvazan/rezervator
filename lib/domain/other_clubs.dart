/// The other clubs Správa → Oddíly offers a nickname for (0083): the
/// opponents, by the name that starts their teams' names. Pure Dart,
/// unit-tested.
library;

import 'collation.dart';
import 'models.dart';

/// Every club at the alleys our teams play at ([venues], as the
/// federation's site lists them) and every club already given a nickname
/// ([nicknames]) — without the alley's own [clubs], by their name or their
/// name on the site: those carry their nickname on their own row (0080).
/// Each name once, Czech-sorted.
List<String> otherClubNames({
  required Iterable<Venue> venues,
  required Iterable<Club> clubs,
  required Iterable<ClubNickname> nicknames,
}) {
  final own = {
    for (final c in clubs) ...[c.name.trim(), ?c.siteName?.trim()],
  };
  final names = {
    for (final v in venues)
      for (final name in v.clubs) name.trim(),
    for (final n in nicknames) n.name.trim(),
  }..removeWhere((name) => name.isEmpty || own.contains(name));
  return names.toList()..sort(compareCzech);
}

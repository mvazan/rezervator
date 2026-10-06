/// Klubovna → Kontakty's list (0048): the alley's contacts, Czech-sorted,
/// narrowed by the search field. Pure Dart, unit-tested.
library;

import 'collation.dart';
import 'models.dart';

/// The Czech-sorted [contacts] whose name, board nick, club or registration
/// number fit
/// [query] by words ([matchesWordsAcross]: „novak jan“, „novak veverky“) —
/// accent- and case-insensitive, like the other searches; an empty query
/// keeps everyone.
List<Contact> contactsMatching(List<Contact> contacts, String query) {
  return [
    for (final c in contacts)
      if (matchesWordsAcross(
        [c.displayName, c.nick, c.clubName ?? '', c.regnum ?? ''],
        query,
      ))
        c,
  ]..sort((a, b) => compareCzech(a.displayName, b.displayName));
}

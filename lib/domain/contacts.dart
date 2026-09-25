/// Klubovna → Kontakty's list (0048): the alley's contacts, Czech-sorted,
/// narrowed by the search field. Pure Dart, unit-tested.
library;

import 'collation.dart';
import 'models.dart';

/// The Czech-sorted [contacts] whose name, board nick or club matches
/// [query] — accent- and case-insensitive, the same folding as the other
/// searches (`venuesMatching`, `upcomingMatches`); an empty query keeps
/// everyone.
List<Contact> contactsMatching(List<Contact> contacts, String query) {
  final q = foldDiacritics(query.trim()).toLowerCase();
  bool hit(String s) => foldDiacritics(s).toLowerCase().contains(q);
  return [
    for (final c in contacts)
      if (q.isEmpty ||
          hit(c.displayName) ||
          hit(c.nick) ||
          hit(c.clubName ?? ''))
        c,
  ]..sort((a, b) => compareCzech(a.displayName, b.displayName));
}

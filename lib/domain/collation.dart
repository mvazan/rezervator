/// Alphabetical order for Czech names and labels — what every name-sorted
/// list in the app uses instead of plain `compareTo`, which orders by code
/// point and so throws every accented letter behind Z (Šimek after Zeman).
/// Pure Dart, unit-tested.
library;

const _diacritics = {
  'á': 'a', 'ä': 'a', 'č': 'c', 'ď': 'd', 'é': 'e', 'ě': 'e', 'í': 'i',
  'ĺ': 'l', 'ľ': 'l', 'ň': 'n', 'ó': 'o', 'ô': 'o', 'ŕ': 'r', 'ř': 'r',
  'š': 's', 'ť': 't', 'ú': 'u', 'ů': 'u', 'ü': 'u', 'ý': 'y', 'ž': 'z',
  'Á': 'A', 'Ä': 'A', 'Č': 'C', 'Ď': 'D', 'É': 'E', 'Ě': 'E', 'Í': 'I',
  'Ĺ': 'L', 'Ľ': 'L', 'Ň': 'N', 'Ó': 'O', 'Ô': 'O', 'Ŕ': 'R', 'Ř': 'R',
  'Š': 'S', 'Ť': 'T', 'Ú': 'U', 'Ů': 'U', 'Ü': 'U', 'Ý': 'Y', 'Ž': 'Z',
};

/// [value] with Czech/Slovak diacritics stripped (Ř → R, ě → e).
String foldDiacritics(String value) {
  final out = StringBuffer();
  for (final rune in value.runes) {
    final ch = String.fromCharCode(rune);
    out.write(_diacritics[ch] ?? ch);
  }
  return out.toString();
}

final _nonWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

/// The words of [value], lower case and without diacritics; anything that is
/// not a letter or a digit separates them.
List<String> _words(String value) => [
  for (final w in foldDiacritics(value).toLowerCase().split(_nonWord))
    if (w.isNotEmpty) w,
];

/// Whether [text] fits the search [query], word by word: every word of the
/// query must start a word of the text, in any order, ignoring case and
/// diacritics. „sokol iv“ finds „TJ Sokol Brno IV“ though the two are not
/// one stretch of the name, and „novak jan“ finds „Jan Novák“. A blank query
/// (no words) matches everything.
///
/// A single letter is the start of a word like any other („jan k“ finds
/// „Jan Kovář“). With [teamLetter] it is a team letter instead and must be a
/// whole word beside other words: „veverky a“ finds „SKK Veverky Brno A“ but
/// not „Veverky Brno B“, nor „Veverky Adamov“ where A merely starts a word.
/// Alone, a letter is still text being typed — or nothing would show until
/// the second one.
bool matchesWords(String text, String query, {bool teamLetter = false}) =>
    _fits(_words(text), _words(query), teamLetter);

/// [matchesWords] over several fields of one thing — a person's name, nick
/// and club: the words of the query may come from different fields
/// („novak veverky“), each only has to start a word of ANY of them.
bool matchesWordsAcross(Iterable<String> fields, String query) =>
    _fits([for (final f in fields) ..._words(f)], _words(query), false);

bool _fits(List<String> have, List<String> wanted, bool teamLetter) {
  if (wanted.isEmpty) return true;
  final letterIsWhole = teamLetter && wanted.length > 1;
  return wanted.every(
    (w) => have.any(
      (h) => letterIsWhole && w.length == 1 ? h == w : h.startsWith(w),
    ),
  );
}

/// The letters the Czech alphabet treats as their own (č after every c,
/// ř, š, ž likewise, ch after h); every other accent is a tie-break only.
const _ownLetters = {'č': 'c{', 'ř': 'r{', 'š': 's{', 'ž': 'z{'};

/// Primary sort key: lowercase, own letters placed right after their base
/// letter ('{' sorts after 'z'), remaining accents stripped.
String _sortKey(String value) {
  final lower = value.toLowerCase().replaceAll('ch', 'h{');
  final out = StringBuffer();
  for (final rune in lower.runes) {
    final ch = String.fromCharCode(rune);
    out.write(_ownLetters[ch] ?? _diacritics[ch] ?? ch);
  }
  return out.toString();
}

/// Czech alphabetical order, case-insensitive: Cimrman < Čapek < Dvořák,
/// Hudec < Chalupa < Ivan, Svoboda < Šimek; an accent that is not a letter
/// of its own only breaks a tie, so Novak < Novák.
int compareCzech(String a, String b) {
  final byKey = _sortKey(a).compareTo(_sortKey(b));
  if (byKey != 0) return byKey;
  return a.toLowerCase().compareTo(b.toLowerCase());
}

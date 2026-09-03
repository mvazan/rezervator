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

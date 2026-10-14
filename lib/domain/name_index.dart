/// Adaptive letter drill-down for the kiosk name picker: show first letters,
/// then two-letter prefixes, … until the remaining names fit on screen.
/// Pure Dart, unit-tested.
///
/// Everything here works on [PlayerName.boardName] — the player's nick when
/// they set one — because that is what the picker's tiles and the board
/// itself show. Indexing the full name instead would file "Bobo" under J
/// for Jan Novák, where nobody reading a tile that says "Bobo" would think
/// to tap.
///
/// „Ch“ is one letter, as in the Czech alphabet (after H): a step that
/// would add a C followed by an H adds both, so Chalupa is filed under its
/// own „Ch“ tile, not under C. The prefixes stay plain upper-case strings;
/// [nameIndexLabel] and [nameIndexParent] know where their last letter
/// starts.
library;

import 'collation.dart';
import 'models.dart';

String _fold(String value) => value.trim().toUpperCase();

/// The letter of [folded] that starts at [at]: CH as one, else one char.
String _letterAt(String folded, int at) =>
    folded.startsWith('CH', at) ? 'CH' : folded[at];

/// Whether [name] (folded) is filed under [prefix] (folded): it starts
/// with it, and a prefix ending in the letter C does not take a name that
/// goes on with H there — that one's letter is CH.
bool _filedUnder(String name, String prefix) =>
    name.startsWith(prefix) &&
    !(prefix.endsWith('C') && name.startsWith('H', prefix.length));

/// The last letter of [prefix], as its tile shows it: „Ch“, or the char.
String nameIndexLabel(String prefix) =>
    prefix.endsWith('CH') ? 'Ch' : prefix.substring(prefix.length - 1);

/// [prefix] one letter shorter — what „Zpět“ goes to.
String nameIndexParent(String prefix) => prefix.substring(
  0,
  prefix.length - (prefix.endsWith('CH') ? 2 : 1),
);

sealed class NameIndexNode {
  const NameIndexNode();
}

/// Too many candidates — show these next-level prefixes as tiles, plus any
/// players whose whole (folded) name equals the current prefix (they cannot
/// extend by another character; the UI lists them as name tiles).
class PrefixesNode extends NameIndexNode {
  const PrefixesNode(this.prefixes, this.exactMatches);

  final List<String> prefixes;
  final List<PlayerName> exactMatches;
}

/// Few enough candidates — show the names themselves.
class NamesNode extends NameIndexNode {
  const NamesNode(this.players);

  final List<PlayerName> players;
}

NameIndexNode nameIndex({
  required List<PlayerName> players,
  required String prefix,
  required int capacity,
}) {
  final folded = _fold(prefix);
  final candidates = players
      .where((p) => _filedUnder(_fold(p.boardName), folded))
      .toList()
    ..sort((a, b) => compareCzech(a.boardName, b.boardName));
  if (candidates.length <= capacity) {
    return NamesNode(candidates);
  }
  final prefixes = <String>{};
  final exactMatches = <PlayerName>[];
  for (final candidate in candidates) {
    final name = _fold(candidate.boardName);
    if (name.length <= folded.length) {
      exactMatches.add(candidate);
    } else {
      prefixes.add(folded + _letterAt(name, folded.length));
    }
  }
  final sorted = prefixes.toList()..sort(compareCzech);
  return PrefixesNode(sorted, exactMatches);
}

/// Adaptive letter drill-down for the kiosk name picker: show first letters,
/// then two-letter prefixes, … until the remaining names fit on screen.
/// Pure Dart, unit-tested.
///
/// Everything here works on [PlayerName.boardName] — the player's nick when
/// they set one — because that is what the picker's tiles and the board
/// itself show. Indexing the full name instead would file "Bobo" under J
/// for Jan Novák, where nobody reading a tile that says "Bobo" would think
/// to tap.
library;

import 'collation.dart';
import 'models.dart';

String _fold(String value) => value.trim().toUpperCase();

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
      .where((p) => _fold(p.boardName).startsWith(folded))
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
      prefixes.add(name.substring(0, folded.length + 1));
    }
  }
  final sorted = prefixes.toList()..sort(compareCzech);
  return PrefixesNode(sorted, exactMatches);
}

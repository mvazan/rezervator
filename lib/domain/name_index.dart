/// Adaptive letter drill-down for the kiosk name picker: show first letters,
/// then two-letter prefixes, … until the remaining names fit on screen.
/// Pure Dart, unit-tested.
library;

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
      .where((p) => _fold(p.displayName).startsWith(folded))
      .toList()
    ..sort((a, b) => _fold(a.displayName).compareTo(_fold(b.displayName)));
  if (candidates.length <= capacity) {
    return NamesNode(candidates);
  }
  final prefixes = <String>{};
  final exactMatches = <PlayerName>[];
  for (final candidate in candidates) {
    final name = _fold(candidate.displayName);
    if (name.length <= folded.length) {
      exactMatches.add(candidate);
    } else {
      prefixes.add(name.substring(0, folded.length + 1));
    }
  }
  final sorted = prefixes.toList()..sort();
  return PrefixesNode(sorted, exactMatches);
}

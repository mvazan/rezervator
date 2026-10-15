/// The clubs of the kiosk's name picker (0076, `kiosk_picker_mode` clubs
/// or both): one tile per club that has a player, in the club's colour; a
/// tap lists that club's players. Pure Dart, unit-tested.
library;

import 'collation.dart';
import 'models.dart';

/// The tile of the players without a club — and of those whose club the
/// roster no longer has.
const pickerOthersName = 'Ostatní';

/// One club tile: the club's [name] and palette [colorIndex], and its
/// [players] in the roster's order. [id] null = [pickerOthersName].
class PickerClub {
  const PickerClub({
    required this.id,
    required this.name,
    required this.colorIndex,
    required this.players,
  });

  final String? id;
  final String name;

  /// Palette index 0–11, or -1 for "no color" (always for „Ostatní“).
  final int colorIndex;
  final List<PlayerName> players;
}

/// The clubs of [players], Czech-alphabetical with [pickerOthersName] last;
/// a club nobody plays for is left out. Fewer than two tiles leave nothing
/// to choose among — then none: the picker starts with the letters (or
/// the names) of everyone, as without clubs.
List<PickerClub> pickerClubs(List<PlayerName> players, List<Club> clubs) {
  final byId = {for (final club in clubs) club.id: club};
  final members = <String, List<PlayerName>>{};
  final others = <PlayerName>[];
  for (final player in players) {
    final id = player.clubId;
    if (id != null && byId.containsKey(id)) {
      (members[id] ??= []).add(player);
    } else {
      others.add(player);
    }
  }
  final tiles = [
    for (final MapEntry(key: id, value: list) in members.entries)
      PickerClub(
        id: id,
        name: byId[id]!.shown,
        colorIndex: byId[id]!.colorIndex,
        players: list,
      ),
  ]..sort((a, b) => compareCzech(a.name, b.name));
  if (others.isNotEmpty) {
    tiles.add(
      PickerClub(
        id: null,
        name: pickerOthersName,
        colorIndex: -1,
        players: others,
      ),
    );
  }
  return tiles.length < 2 ? const [] : tiles;
}

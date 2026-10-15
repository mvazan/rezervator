import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/picker_clubs.dart';

void main() {
  const veverky = Club(id: 'v', name: 'TJ Veverky', colorIndex: 3);
  const sokol = Club(id: 's', name: 'Sokol Čáslav', colorIndex: 7);
  const empty = Club(id: 'e', name: 'Áčko bez hráčů', colorIndex: 1);

  PlayerName player(String id, String? club) =>
      PlayerName(id: id, displayName: 'Hráč $id', clubId: club);

  test('one tile per club with a player, Czech-alphabetical, the players '
      'in the roster\'s order', () {
    final roster = [
      player('1', 'v'),
      player('2', 's'),
      player('3', 'v'),
    ];
    final tiles = pickerClubs(roster, const [veverky, sokol, empty]);
    expect([for (final t in tiles) t.name], ['Sokol Čáslav', 'TJ Veverky']);
    expect([for (final t in tiles) t.id], ['s', 'v']);
    expect([for (final t in tiles) t.colorIndex], [7, 3]);
    expect([for (final p in tiles[1].players) p.id], ['1', '3']);
  });

  test('Czech order, not code units: Š after S, Ch after H', () {
    final tiles = pickerClubs(
      [
        player('1', 'z'),
        player('2', 'š'),
        player('3', 'ch'),
        player('4', 'h'),
      ],
      const [
        Club(id: 'z', name: 'Zbraslav'),
        Club(id: 'š', name: 'Šumperk'),
        Club(id: 'ch', name: 'Chotěboř'),
        Club(id: 'h', name: 'Hořice'),
      ],
    );
    expect([for (final t in tiles) t.name],
        ['Hořice', 'Chotěboř', 'Šumperk', 'Zbraslav']);
  });

  test('the players without a club, or with one the roster no longer has, '
      'go under „Ostatní“ — last, without a colour', () {
    final tiles = pickerClubs(
      [player('1', 'v'), player('2', null), player('3', 'gone')],
      const [veverky],
    );
    expect([for (final t in tiles) t.name], ['TJ Veverky', pickerOthersName]);
    expect(tiles.last.id, isNull);
    expect(tiles.last.colorIndex, -1);
    expect([for (final p in tiles.last.players) p.id], ['2', '3']);
  });

  test('fewer than two tiles are nothing to choose among: none', () {
    expect(pickerClubs([player('1', 'v'), player('2', 'v')], const [veverky]),
        isEmpty);
    expect(pickerClubs([player('1', null)], const [veverky]), isEmpty);
    expect(pickerClubs(const [], const [veverky, sokol]), isEmpty);
  });
}

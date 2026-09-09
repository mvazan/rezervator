import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/name_index.dart';

void main() {
  PlayerName p(String name) => PlayerName(id: name, displayName: name);

  final players = [
    p('Novák Jan'), p('Novotná Eva'), p('Nguyen Bao'),
    p('Svoboda Petr'), p('Světlík Ota'), p('Šimek Aleš'),
    p('Dvořák Karel'), p('dráb pavel'),
  ];

  test('small list fits capacity → NamesNode sorted', () {
    final node = nameIndex(players: players, prefix: '', capacity: 10);
    expect(node, isA<NamesNode>());
    final names = (node as NamesNode).players.map((x) => x.displayName).toList();
    expect(names.first, 'dráb pavel'); // case-folded sort: DRÁB < DVOŘÁK
    expect(names, hasLength(8));
  });

  test('over capacity → first-letter prefixes, diacritics distinct', () {
    final node = nameIndex(players: players, prefix: '', capacity: 3);
    expect(node, isA<PrefixesNode>());
    final prefixes = (node as PrefixesNode).prefixes;
    expect(prefixes, ['D', 'N', 'S', 'Š']);
    expect(node.exactMatches, isEmpty);
  });

  test('drill down one level narrows candidates', () {
    final node = nameIndex(players: players, prefix: 'N', capacity: 2);
    expect(node, isA<PrefixesNode>());
    expect((node as PrefixesNode).prefixes, ['NG', 'NO']);
    final no = nameIndex(players: players, prefix: 'NO', capacity: 2);
    expect(no, isA<NamesNode>());
    expect((no as NamesNode).players.map((x) => x.displayName),
        unorderedEquals(['Novák Jan', 'Novotná Eva']));
  });

  test('prefix matching is case-insensitive', () {
    final node = nameIndex(players: players, prefix: 'd', capacity: 10);
    expect(node, isA<NamesNode>());
    expect((node as NamesNode).players.map((x) => x.displayName).toList(),
        ['dráb pavel', 'Dvořák Karel']);
  });

  test('the nick is what gets indexed, sorted and matched — the full name '
      'only for players without one', () {
    const bobo = PlayerName(id: 'b', displayName: 'Novák Jan', nick: 'Bobo');
    final roster = [bobo, p('Adamec Petr'), p('Novotná Eva')];

    // Jan is filed under B (what his tile says), not under N.
    final letters = nameIndex(players: roster, prefix: '', capacity: 2);
    expect((letters as PrefixesNode).prefixes, ['A', 'B', 'N']);

    // …and he answers to it, while his full name finds nobody.
    final b = nameIndex(players: roster, prefix: 'B', capacity: 10);
    expect((b as NamesNode).players.single.id, 'b');
    final n = nameIndex(players: roster, prefix: 'NOV', capacity: 10);
    expect((n as NamesNode).players.map((x) => x.displayName),
        ['Novotná Eva'], reason: 'Jan is Bobo here, name and letter alike');

    // Sorting goes by the same string: Bobo sits between Adamec and Novotná.
    final all = nameIndex(players: roster, prefix: '', capacity: 10);
    expect((all as NamesNode).players.map((x) => x.boardName),
        ['Adamec Petr', 'Bobo', 'Novotná Eva']);
  });

  test('name equal to the prefix lands in exactMatches', () {
    final many = [
      p('AB'), p('ABA'), p('ABB'), p('ABC'), p('ABD'), p('ABE'),
    ];
    final node = nameIndex(players: many, prefix: 'AB', capacity: 3);
    expect(node, isA<PrefixesNode>());
    final prefixNode = node as PrefixesNode;
    expect(prefixNode.exactMatches.single.displayName, 'AB');
    expect(prefixNode.prefixes, ['ABA', 'ABB', 'ABC', 'ABD', 'ABE']);
  });
}

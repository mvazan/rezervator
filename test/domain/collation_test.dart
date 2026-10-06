import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/collation.dart';

void main() {
  test('foldDiacritics strips Czech and Slovak accents only', () {
    expect(foldDiacritics('Šťastný Řehoř'), 'Stastny Rehor');
    expect(foldDiacritics('Ľuboš Kňažko'), 'Lubos Knazko');
    expect(foldDiacritics('Nguyen Bao 3'), 'Nguyen Bao 3');
  });

  test('č, ř, š, ž and ch are letters of their own; other accents are not',
      () {
    final names = [
      'Zeman', 'Žák', 'Šimek', 'Svoboda', 'Čapek', 'Cimrman', 'Dvořák',
      'Chalupa', 'Hudec', 'Ivan', 'Řehoř', 'Rada', 'Ěrik', 'Emil',
    ];
    names.sort(compareCzech);
    expect(names, [
      'Cimrman', 'Čapek', 'Dvořák', 'Emil', 'Ěrik', 'Hudec', 'Chalupa',
      'Ivan', 'Rada', 'Řehoř', 'Svoboda', 'Šimek', 'Zeman', 'Žák',
    ]);
  });

  test('case-insensitive; an accent only breaks a tie', () {
    expect(compareCzech('dráb', 'Dvořák'), lessThan(0));
    expect(compareCzech('Novak', 'Novák'), lessThan(0));
    expect(compareCzech('novák', 'NOVÁK'), 0);
    expect(compareCzech('c', 'č'), lessThan(0));
  });

  group('matchesWords', () {
    const team = 'SKK Veverky Brno A';

    test('a blank query matches everything', () {
      expect(matchesWords(team, ''), isTrue);
      expect(matchesWords(team, '   '), isTrue);
      expect(matchesWords(team, ' .. '), isTrue, reason: 'no words, no filter');
    });

    test('every word of the query starts a word of the text, in any order',
        () {
      expect(matchesWords(team, 'veverky'), isTrue);
      expect(matchesWords(team, 'vev brno'), isTrue);
      expect(matchesWords(team, 'brno veverky'), isTrue);
      expect(matchesWords(team, 'veverky praha'), isFalse);
      expect(matchesWords(team, 'verky'), isFalse,
          reason: 'a word is matched from its start, not from its middle');
    });

    test('accents and case do not count', () {
      expect(matchesWords('KK Vyškov', 'VYSKOV'), isTrue);
      expect(matchesWords('KK Vyskov', 'vyškov'), isTrue);
      expect(matchesWords('SK Žabovřesky B', 'zabovresky'), isTrue);
    });

    test('a lone letter beside other words is the team letter: whole word',
        () {
      expect(matchesWords(team, 'veverky a'), isTrue);
      expect(matchesWords('SKK Veverky Brno B', 'veverky a'), isFalse);
      expect(matchesWords('SKK Veverky Brno C', 'veverky b'), isFalse);
      expect(matchesWords('SKK Veverky Adamov', 'veverky a'), isFalse,
          reason: 'A is the letter, not the start of „Adamov“');
      expect(matchesWords(team, 'a veverky'), isTrue, reason: 'any order');
      expect(matchesWords('Veverky', 'veverky a'), isFalse,
          reason: 'a team without the letter is not „Veverky A“');
    });

    test('a lone letter alone is still typed text: the start of a word', () {
      expect(matchesWords('KK Blansko', 'k'), isTrue);
      expect(matchesWords('KK Blansko', 'b'), isTrue);
      expect(matchesWords('KK Blansko', 'z'), isFalse);
    });

    test('numbers and punctuation split words like spaces do', () {
      expect(matchesWords('rozpis: KP1 Sever, 1. kolo', 'kp1 sever'), isTrue);
      expect(matchesWords('rozpis: KP1 Sever, 1. kolo', 'sever 1'), isTrue);
      expect(matchesWords('Sokol Brno-Husovice', 'brno husovice'), isTrue);
    });
  });
}

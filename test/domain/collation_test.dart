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
}

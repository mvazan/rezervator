import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/namedays.dart';

void main() {
  String? line(int month, int day, {int year = 2026}) =>
      nameDayLine(czechNameDay(Day(year, month, day)));

  test('an ordinary day: its name, the variant only one source knows left '
      'out', () {
    expect(czechNameDay(Day(2026, 1, 3)).names, ['Radmila']);
    expect(line(1, 3), 'Svátek: Radmila');
  });

  test('several names, joined the Czech way', () {
    expect(line(12, 24), 'Svátek: Adam a Eva');
    expect(line(1, 6), 'Svátek: Kašpar, Melichar a Baltazar');
    expect(line(9, 28), 'Svátek: Václav a Václava');
  });

  test('a public holiday without a name says the holiday', () {
    expect(czechNameDay(Day(2026, 1, 1)).names, isEmpty);
    expect(line(1, 1), 'Nový rok');
    expect(line(12, 25), '1. svátek vánoční');
    // A holiday with names: the names.
    expect(czechNameDay(Day(2026, 12, 24)).holiday, 'Štědrý den');
    expect(line(7, 5), 'Svátek: Cyril a Metoděj');
  });

  test('29 February has its name in a leap year', () {
    expect(line(2, 29, year: 2028), 'Svátek: Horymír');
  });

  test('every day of a leap year says something; no feast pretends to be a '
      'name', () {
    var day = Day(2028, 1, 1);
    final seen = <String>{};
    while (day.year == 2028) {
      final text = line(day.month, day.day, year: 2028);
      expect(text, isNotNull, reason: '$day');
      seen.addAll(czechNameDay(day).names);
      day = day.addDays(1);
    }
    expect(seen, isNot(contains('Hromnice')));
    expect(seen.length, greaterThan(380));
  });
}

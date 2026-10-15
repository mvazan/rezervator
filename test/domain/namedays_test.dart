import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/namedays.dart';

void main() {
  ({String title, String text})? header(
    int month,
    int day, {
    int year = 2026,
  }) => nameDayHeader(czechNameDay(Day(year, month, day)));

  test('an ordinary day: its name, the variant only one source knows left '
      'out', () {
    expect(czechNameDay(Day(2026, 1, 3)).names, ['Radmila']);
    expect(header(1, 3), (title: 'Dnes má svátek', text: 'Radmila'));
  });

  test('several names, joined the Czech way, under the plural title', () {
    expect(header(12, 24), (title: 'Dnes mají svátek', text: 'Adam a Eva'));
    expect(
      header(1, 6),
      (title: 'Dnes mají svátek', text: 'Kašpar, Melichar a Baltazar'),
    );
    expect(
      header(9, 28),
      (title: 'Dnes mají svátek', text: 'Václav a Václava'),
    );
  });

  test('a public holiday without a name says the holiday', () {
    expect(czechNameDay(Day(2026, 1, 1)).names, isEmpty);
    expect(header(1, 1), (title: 'Státní svátek', text: 'Nový rok'));
    expect(
      header(12, 25),
      (title: 'Státní svátek', text: '1. svátek vánoční'),
    );
    // A holiday with names: the names.
    expect(czechNameDay(Day(2026, 12, 24)).holiday, 'Štědrý den');
    expect(
      header(7, 5),
      (title: 'Dnes mají svátek', text: 'Cyril a Metoděj'),
    );
  });

  test('29 February has its name in a leap year', () {
    expect(
      header(2, 29, year: 2028),
      (title: 'Dnes má svátek', text: 'Horymír'),
    );
  });

  test('every day of a leap year says something; no feast pretends to be a '
      'name', () {
    var day = Day(2028, 1, 1);
    final seen = <String>{};
    while (day.year == 2028) {
      final said = header(day.month, day.day, year: 2028);
      expect(said, isNotNull, reason: '$day');
      seen.addAll(czechNameDay(day).names);
      day = day.addDays(1);
    }
    expect(seen, isNot(contains('Hromnice')));
    expect(seen.length, greaterThan(380));
  });
}

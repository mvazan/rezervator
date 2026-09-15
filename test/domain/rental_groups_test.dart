import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/rental_groups.dart';

void main() {
  final today = Day(2026, 9, 15);
  Rental date({
    required String id,
    required String name,
    required Day day,
    String? group,
    int color = -2,
    HourMinute start = const HourMinute(18, 0),
  }) =>
      Rental(
        id: id,
        renterName: name,
        lanes: const [1],
        date: day,
        weekday: null,
        startsAt: start,
        endsAt: const HourMinute(20, 0),
        validFrom: null,
        validUntil: null,
        note: '',
        color: color,
        groupId: group,
      );
  final series = Rental(
    id: 's',
    renterName: 'Série',
    lanes: const [1],
    date: null,
    weekday: DateTime.thursday,
    startsAt: const HourMinute(18, 0),
    endsAt: const HourMinute(20, 0),
    validFrom: null,
    validUntil: null,
    note: '',
  );
  final exception = Rental(
    id: 'x',
    renterName: 'Série',
    lanes: const [1],
    date: Day(2026, 9, 17),
    weekday: null,
    startsAt: const HourMinute(18, 0),
    endsAt: const HourMinute(20, 0),
    validFrom: null,
    validUntil: null,
    note: '',
    parentId: 's',
  );

  group('rentalGroupsOf', () {
    test('rows of one group_id become one group, dates chronological', () {
      final groups = rentalGroupsOf([
        date(id: 'b', name: 'Firma', day: Day(2026, 10, 3), group: 'g1'),
        date(id: 'a', name: 'Firma', day: Day(2026, 9, 20), group: 'g1'),
      ], today: today);
      expect(groups, hasLength(1));
      expect(groups.single.id, 'g1');
      expect(groups.single.renterName, 'Firma');
      expect(groups.single.dates.map((d) => d.id), ['a', 'b']);
    });

    test('a lone one-time rental is a group of one with a null id', () {
      final groups = rentalGroupsOf(
          [date(id: 'l', name: 'Oslava', day: Day(2026, 9, 20))],
          today: today);
      expect(groups.single.id, isNull);
      expect(groups.single.dates.single.id, 'l');
    });

    test('weekly series and exception rows are not groups', () {
      expect(rentalGroupsOf([series, exception], today: today), isEmpty);
    });

    test('groups sort by their next upcoming date', () {
      final groups = rentalGroupsOf([
        date(id: 'far', name: 'Pozdější', day: Day(2026, 11, 1), group: 'g2'),
        date(id: 'near', name: 'Bližší', day: Day(2026, 9, 20)),
        // g3 has a past date and a later one — its NEXT date decides.
        date(id: 'old', name: 'Smíšená', day: Day(2026, 9, 1), group: 'g3'),
        date(id: 'mid', name: 'Smíšená', day: Day(2026, 10, 1), group: 'g3'),
      ], today: today);
      expect(groups.map((g) => g.renterName), ['Bližší', 'Smíšená', 'Pozdější']);
    });

    test('groups with only past dates go last, most recently ended first',
        () {
      final groups = rentalGroupsOf([
        date(id: 'p1', name: 'Dávno', day: Day(2026, 5, 1)),
        date(id: 'p2', name: 'Nedávno', day: Day(2026, 9, 10)),
        date(id: 'u', name: 'Budoucí', day: Day(2026, 9, 30)),
      ], today: today);
      expect(groups.map((g) => g.renterName), ['Budoucí', 'Nedávno', 'Dávno']);
      expect(groups[1].nextDate(today), isNull);
    });

    test('same next date sorts by renter name, Czech collation', () {
      final groups = rentalGroupsOf([
        date(id: '1', name: 'Šimek', day: Day(2026, 9, 20)),
        date(id: '2', name: 'Chalupa', day: Day(2026, 9, 20)),
        date(id: '3', name: 'Adam', day: Day(2026, 9, 20)),
      ], today: today);
      expect(groups.map((g) => g.renterName), ['Adam', 'Chalupa', 'Šimek']);
    });

    test('today counts as upcoming', () {
      final groups = rentalGroupsOf(
          [date(id: 't', name: 'Dnes', day: today)],
          today: today);
      expect(groups.single.nextDate(today), today);
    });
  });
}

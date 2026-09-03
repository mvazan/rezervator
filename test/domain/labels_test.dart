import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/labels.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/schedule.dart';

void main() {
  final tuesday = Day(2026, 7, 7);

  final match = PrioritySlot(
    id: 'm1',
    date: tuesday,
    startsAt: const HourMinute(17, 0),
    endsAt: const HourMinute(18, 30),
    type: PrioritySlot.fallbackMatchType,
    homeTeam: 'KK Vracov',
    awayTeam: 'KK Slavoj',
  );

  final blockage = PrioritySlot(
    id: 's1',
    date: tuesday,
    startsAt: const HourMinute(9, 5),
    endsAt: const HourMinute(12, 0),
    type: const PrioritySlotType(id: 't-paint', name: 'Malování drah'),
  );

  final rental = Rental(
    id: 'r1',
    renterName: 'Firma XY',
    lanes: const [1, 2],
    date: tuesday,
    weekday: null,
    startsAt: const HourMinute(17, 0),
    endsAt: const HourMinute(18, 30),
    validFrom: null,
    validUntil: null,
    note: '',
  );

  group('slotEventLabel', () {
    test('a match gets the trophy and its team title', () {
      expect(slotEventLabel(match), '🏆 KK Vracov – KK Slavoj');
    });

    test('any other blockage gets the stop sign and the type name', () {
      expect(slotEventLabel(blockage), '⛔ Malování drah');
    });
  });

  group('rentalLabel', () {
    test('a rental gets the lock and the renter name', () {
      expect(rentalLabel(rental), '🔒 Firma XY');
    });
  });

  group('eventBandLabel', () {
    test('a match band appends its od–do window', () {
      expect(
        eventBandLabel(OffBlockPriority(match)),
        '🏆 KK Vracov – KK Slavoj · 17:00–18:30',
      );
      expect(
        eventBandLabel(OffBlockPriority(match)),
        endsWith(' · 17:00–18:30'),
      );
    });

    test('a blockage band uses HourMinute.display (no zero-padded hour)', () {
      expect(
        eventBandLabel(OffBlockPriority(blockage)),
        '⛔ Malování drah · 9:05–12:00',
      );
    });

    test('a rental band appends its od–do window', () {
      expect(
        eventBandLabel(OffBlockRental(rental)),
        '🔒 Firma XY · 17:00–18:30',
      );
    });
  });
  group('rental exceptions', () {
    final series = Rental(
      id: 'n1',
      renterName: 'Firma XY',
      lanes: const [1, 2],
      date: null,
      weekday: 2,
      startsAt: const HourMinute(17, 0),
      endsAt: const HourMinute(18, 30),
      validFrom: null,
      validUntil: null,
      note: '',
    );
    Rental child({
      List<int> lanes = const [1, 2],
      HourMinute startsAt = const HourMinute(17, 0),
      HourMinute endsAt = const HourMinute(18, 30),
      bool skipped = false,
    }) =>
        Rental(
          id: 'c1',
          renterName: 'Firma XY',
          lanes: lanes,
          date: tuesday,
          weekday: null,
          startsAt: startsAt,
          endsAt: endsAt,
          validFrom: null,
          validUntil: null,
          note: '',
          parentId: 'n1',
          skipped: skipped,
        );

    test('an overridden occurrence gets the výjimka suffix', () {
      final r = series.overriddenBy(child(lanes: const [1]));
      expect(rentalLabel(r), '🔒 Firma XY (výjimka)');
      expect(eventBandLabel(OffBlockRental(r)),
          '🔒 Firma XY (výjimka) · 17:00–18:30');
      expect(rentalLabel(series), '🔒 Firma XY');
    });

    test('rentalExceptionSummary names only what changed', () {
      expect(rentalExceptionSummary(series, child(skipped: true)), 'vynecháno');
      expect(rentalExceptionSummary(series, child(lanes: const [1])),
          'dráhy 1');
      expect(
          rentalExceptionSummary(
              series, child(endsAt: const HourMinute(18, 0))),
          '17:00–18:00');
      expect(
          rentalExceptionSummary(series,
              child(lanes: const [1], endsAt: const HourMinute(18, 0))),
          'dráhy 1 · 17:00–18:00');
      expect(rentalExceptionSummary(series, child()), 'beze změny');
    });

    test('rentalExceptionCountLabel follows Czech plurals', () {
      expect(rentalExceptionCountLabel(1), '1 výjimka');
      expect(rentalExceptionCountLabel(2), '2 výjimky');
      expect(rentalExceptionCountLabel(4), '4 výjimky');
      expect(rentalExceptionCountLabel(5), '5 výjimek');
      expect(rentalExceptionCountLabel(11), '11 výjimek');
    });
  });
}

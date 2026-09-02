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
}

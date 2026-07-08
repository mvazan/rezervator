import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';

void main() {
  group('HourMinute', () {
    test('parses HH:MM:SS and compares', () {
      final a = HourMinute.parse('16:00:00');
      final b = HourMinute.parse('17:30');
      expect(a.hour, 16);
      expect(b.minute, 30);
      expect(a.compareTo(b), lessThan(0));
      expect(a.toSql(), '16:00:00');
    });
  });

  group('Day', () {
    test('parses, adds days across DST, knows weekday', () {
      final d = Day.parse('2026-03-28'); // Saturday before EU DST switch
      expect(d.weekday, 6);
      expect(d.addDays(2).toSql(), '2026-03-30');
    });
  });

  group('ScheduleSettings', () {
    test('fromJson reads int[] weekdays', () {
      final s = ScheduleSettings.fromJson({
        'lane_count': 6,
        'training_weekdays': [1, 3],
        'booking_horizon_days': 7,
        'max_active_reservations': 2,
      });
      expect(s.laneCount, 6);
      expect(s.trainingWeekdays, {1, 3});
      expect(s.bookingHorizonDays, 7);
      expect(s.maxActiveReservations, 2);
    });

    test('defaults', () {
      expect(ScheduleSettings.defaults.laneCount, 4);
      expect(ScheduleSettings.defaults.trainingWeekdays, {1, 2, 4});
    });
  });

  group('Profile', () {
    test('parses role and status', () {
      final p = Profile.fromJson({
        'id': 'u1',
        'display_name': 'Ján',
        'club': 'KK Praha',
        'email': 'jan@example.com',
        'role': 'admin',
        'status': 'approved',
        'fcm_token': null,
      });
      expect(p.role, Role.admin);
      expect(p.isAdmin, isTrue);
      expect(p.isApproved, isTrue);
    });
  });

  group('Rental.occursOn', () {
    Rental weekly({Day? from, Day? until}) => Rental(
          id: 'r1',
          renterName: 'Firma X',
          lanes: const [1, 2],
          date: null,
          weekday: 3,
          startsAt: const HourMinute(18, 0),
          endsAt: const HourMinute(20, 0),
          validFrom: from,
          validUntil: until,
          note: '',
        );

    test('one-time matches only its date', () {
      final r = Rental(
        id: 'r2',
        renterName: 'Oslava',
        lanes: const [3],
        date: Day(2026, 7, 15),
        weekday: null,
        startsAt: const HourMinute(18, 0),
        endsAt: const HourMinute(20, 0),
        validFrom: null,
        validUntil: null,
        note: '',
      );
      expect(r.occursOn(Day(2026, 7, 15)), isTrue);
      expect(r.occursOn(Day(2026, 7, 22)), isFalse);
    });

    test('weekly matches weekday inside validity window', () {
      final r = weekly(from: Day(2026, 7, 1), until: Day(2026, 7, 31));
      expect(r.occursOn(Day(2026, 7, 15)), isTrue); // Wednesday
      expect(r.occursOn(Day(2026, 7, 16)), isFalse); // Thursday
      expect(r.occursOn(Day(2026, 8, 5)), isFalse); // Wed after window
      expect(weekly().occursOn(Day(2026, 8, 5)), isTrue); // open-ended
    });

    test('weekly matches exactly on validity boundaries', () {
      final r = weekly(from: Day(2026, 7, 1), until: Day(2026, 7, 15));
      expect(r.occursOn(Day(2026, 7, 1)), isTrue);  // == validFrom (Wednesday)
      expect(r.occursOn(Day(2026, 7, 15)), isTrue); // == validUntil (Wednesday)
      expect(r.occursOn(Day(2026, 6, 24)), isFalse); // Wednesday before window
      expect(r.occursOn(Day(2026, 7, 22)), isFalse); // Wednesday after window
    });
  });

  group('Reservation', () {
    test('isLive false when cancelled', () {
      final json = {
        'id': 'x',
        'player_id': 'u1',
        'date': '2026-07-08',
        'block_id': 'b1',
        'lane': 2,
        'created_via': 'kiosk',
        'created_at': '2026-07-07T10:00:00Z',
        'cancelled_at': null,
        'cancelled_via': null,
        'cancel_note': '',
      };
      expect(Reservation.fromJson(json).isLive, isTrue);
      expect(
        Reservation.fromJson({
          ...json,
          'cancelled_at': '2026-07-07T11:00:00Z',
          'cancelled_via': 'one_click',
        }).isLive,
        isFalse,
      );
    });
  });

  group('defaultTimeBlocks', () {
    test('six hourly blocks 16–22', () {
      final blocks = defaultTimeBlocks();
      expect(blocks, hasLength(6));
      expect(blocks.first.startsAt, const HourMinute(16, 0));
      expect(blocks.last.endsAt, const HourMinute(22, 0));
      expect(blocks.first.label, '16:00–17:00');
    });
  });

  group('AttendanceRow', () {
    test('parses rpc row', () {
      final row = AttendanceRow.fromJson(
          {'player_id': 'p1', 'display_name': 'Ján', 'club': 'KK', 'attended': 3});
      expect(row.attended, 3);
      expect(row.club, 'KK');
    });
  });
}

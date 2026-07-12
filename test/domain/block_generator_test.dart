import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/block_generator.dart';
import 'package:rezervator/domain/models.dart';

void main() {
  group('generateBlockTimes', () {
    test('evenly spaced series without pauses', () {
      final times = generateBlockTimes(
        start: const HourMinute(15, 30),
        durationMinutes: 60,
        pauseMinutes: 0,
        count: 3,
      );
      expect(times, [
        (const HourMinute(15, 30), const HourMinute(16, 30)),
        (const HourMinute(16, 30), const HourMinute(17, 30)),
        (const HourMinute(17, 30), const HourMinute(18, 30)),
      ]);
    });

    test('pauses shift each subsequent block', () {
      final times = generateBlockTimes(
        start: const HourMinute(18, 0),
        durationMinutes: 45,
        pauseMinutes: 15,
        count: 2,
      );
      expect(times, [
        (const HourMinute(18, 0), const HourMinute(18, 45)),
        (const HourMinute(19, 0), const HourMinute(19, 45)),
      ]);
    });

    test('series crossing midnight is rejected', () {
      expect(
        generateBlockTimes(
          start: const HourMinute(22, 0),
          durationMinutes: 60,
          pauseMinutes: 0,
          count: 3,
        ),
        isNull,
      );
    });

    test('series reaching midnight is rejected (23:59 is the latest end)', () {
      expect(
        generateBlockTimes(
          start: const HourMinute(22, 0),
          durationMinutes: 60,
          pauseMinutes: 0,
          count: 2,
        ),
        isNull,
      );
      // The same series one minute earlier fits.
      expect(
        generateBlockTimes(
          start: const HourMinute(21, 59),
          durationMinutes: 60,
          pauseMinutes: 0,
          count: 2,
        ),
        isNotNull,
      );
    });

    test('invalid inputs are rejected', () {
      expect(
        generateBlockTimes(
            start: const HourMinute(10, 0),
            durationMinutes: 0,
            pauseMinutes: 0,
            count: 1),
        isNull,
      );
      expect(
        generateBlockTimes(
            start: const HourMinute(10, 0),
            durationMinutes: 60,
            pauseMinutes: -5,
            count: 1),
        isNull,
      );
      expect(
        generateBlockTimes(
            start: const HourMinute(10, 0),
            durationMinutes: 60,
            pauseMinutes: 0,
            count: 0),
        isNull,
      );
    });
  });

  group('generatorConflicts', () {
    const active = TimeBlock(
      id: 'a',
      startsAt: HourMinute(16, 0),
      endsAt: HourMinute(17, 0),
      position: 0,
      active: true,
    );
    const inactive = TimeBlock(
      id: 'i',
      startsAt: HourMinute(18, 0),
      endsAt: HourMinute(19, 0),
      position: 1,
      active: false,
    );

    test('overlap with an active block is reported by label', () {
      final conflicts = generatorConflicts(
        [(const HourMinute(16, 30), const HourMinute(17, 30))],
        [active, inactive],
      );
      expect(conflicts, [active.label]);
    });

    test('inactive blocks and touching ranges do not conflict', () {
      final conflicts = generatorConflicts(
        [
          (const HourMinute(17, 0), const HourMinute(18, 0)), // touches active
          (const HourMinute(18, 0), const HourMinute(19, 0)), // over inactive
        ],
        [active, inactive],
      );
      expect(conflicts, isEmpty);
    });
  });
}

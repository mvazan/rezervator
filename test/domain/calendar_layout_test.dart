import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/calendar_layout.dart';
import 'package:rezervator/domain/models.dart';

TimeBlock block(String id, HourMinute start, HourMinute end, {int pos = 0}) =>
    TimeBlock(
        id: id, startsAt: start, endsAt: end, position: pos, active: true);

void main() {
  group('calendarWindowFor', () {
    test('spans blocks, aligned outward to whole hours', () {
      final w = calendarWindowFor(blocks: [
        block('a', const HourMinute(16, 30), const HourMinute(17, 30)),
        block('b', const HourMinute(18, 0), const HourMinute(19, 15)),
      ])!;
      expect(w.startMinute, 16 * 60);
      expect(w.endMinute, 20 * 60);
    });

    test('off-block events extend the window', () {
      final w = calendarWindowFor(
        blocks: [block('a', const HourMinute(16, 0), const HourMinute(18, 0))],
        eventWindows: const [
          (HourMinute(12, 0), HourMinute(14, 0)),
          (HourMinute(20, 0), HourMinute(21, 30)),
        ],
      )!;
      expect(w.startMinute, 12 * 60);
      expect(w.endMinute, 22 * 60);
    });

    test('no content -> null; end never exceeds midnight', () {
      expect(calendarWindowFor(blocks: const []), isNull);
      final w = calendarWindowFor(blocks: [
        block('a', const HourMinute(22, 0), const HourMinute(23, 59)),
      ])!;
      expect(w.endMinute, 24 * 60);
    });
  });

  group('geometry', () {
    const w = CalendarWindow(16 * 60, 22 * 60);

    test('topFor/heightFor map minutes linearly', () {
      expect(w.topFor(const HourMinute(16, 0), 2), 0);
      expect(w.topFor(const HourMinute(17, 30), 2), 180);
      expect(w.heightFor(const HourMinute(17, 0), const HourMinute(18, 0), 2),
          120);
    });

    test('minuteAt inverts topFor and clamps to the window', () {
      expect(w.minuteAt(180, 2), 17 * 60 + 30);
      expect(w.minuteAt(-50, 2), 16 * 60);
      expect(w.minuteAt(1e6, 2), 22 * 60);
    });
  });

  group('freeGapAt', () {
    const w = CalendarWindow(16 * 60, 22 * 60);
    final occupied = mergeIntervals(const [
      (17 * 60, 18 * 60),
      (19 * 60, 20 * 60),
    ]);

    test('returns the maximal free interval containing the minute', () {
      expect(freeGapAt(16 * 60 + 20, occupied, w), (16 * 60, 17 * 60));
      expect(freeGapAt(18 * 60 + 30, occupied, w), (18 * 60, 19 * 60));
      expect(freeGapAt(21 * 60, occupied, w), (20 * 60, 22 * 60));
    });

    test('inside occupied time or outside the window -> null', () {
      expect(freeGapAt(17 * 60 + 30, occupied, w), isNull);
      expect(freeGapAt(15 * 60, occupied, w), isNull);
      expect(freeGapAt(22 * 60, occupied, w), isNull);
    });

    test('no occupied time -> the whole window', () {
      expect(freeGapAt(18 * 60, const [], w), (16 * 60, 22 * 60));
    });
  });

  group('mergeIntervals', () {
    test('merges overlaps and touching intervals, drops empties', () {
      expect(
        mergeIntervals(const [(10, 20), (15, 25), (25, 30), (40, 40), (35, 38)]),
        const [(10, 30), (35, 38)],
      );
    });
  });
}

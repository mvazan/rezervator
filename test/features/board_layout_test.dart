import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/kiosk/board_layout.dart';

void main() {
  group('laneRowHeight', () {
    test('60-min block maps to the reference lane-row height (40)', () {
      expect(laneRowHeight(60), 40.0);
    });

    test('30-min block is floored to the minimum lane-row height (22)', () {
      // 40 * 30 / 60 == 20, which is below the 22 floor.
      expect(laneRowHeight(30), 22.0);
    });

    test('90-min block scales proportionally to 60', () {
      expect(laneRowHeight(90), 60.0);
    });

    test('120-min block scales proportionally to 80', () {
      expect(laneRowHeight(120), 80.0);
    });
  });

  group('blockGroupHeight', () {
    TimeBlock block(HourMinute start, HourMinute end) => TimeBlock(
          id: 'b1',
          startsAt: start,
          endsAt: end,
          position: 0,
          active: true,
        );

    test('60-min block with 4 lanes is 160', () {
      final b = block(const HourMinute(18, 0), const HourMinute(19, 0));
      expect(blockGroupHeight(b, 4), 160.0);
    });

    test('30-min block with 4 lanes is 88 (floored per-lane height)', () {
      final b = block(const HourMinute(18, 0), const HourMinute(18, 30));
      expect(blockGroupHeight(b, 4), 88.0);
    });
  });
}

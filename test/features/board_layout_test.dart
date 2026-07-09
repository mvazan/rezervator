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

  group('axisUnit', () {
    test('4 lanes at default 22px lane-unit is 88', () {
      expect(axisUnit(4), 88.0);
    });

    test('scales with laneUnit30', () {
      expect(axisUnit(4, laneUnit30: 10.0), 40.0);
    });
  });

  group('axisRange', () {
    TimeBlock block(HourMinute start, HourMinute end) => TimeBlock(
          id: 'b',
          startsAt: start,
          endsAt: end,
          position: 0,
          active: true,
        );

    test('default hourly blocks 15:30-21:30 give start 15:30 and 12 slots',
        () {
      final blocks = [
        block(const HourMinute(16, 0), const HourMinute(17, 0)),
        block(const HourMinute(15, 30), const HourMinute(16, 30)),
        block(const HourMinute(20, 30), const HourMinute(21, 30)),
      ];
      final range = axisRange(blocks);
      expect(range.start, const HourMinute(15, 30));
      expect(range.slots, 12);
    });

    test('mixed default+shifted set spans earliest start to latest end', () {
      final blocks = [
        block(const HourMinute(16, 0), const HourMinute(17, 0)),
        block(const HourMinute(21, 0), const HourMinute(22, 0)),
        block(const HourMinute(15, 45), const HourMinute(16, 45)),
      ];
      final range = axisRange(blocks);
      // earliest start 15:45 floors to 15:30; latest end 22:00 stays 22:00.
      expect(range.start, const HourMinute(15, 30));
      expect(range.slots, 13);
    });

    test('empty blocks give (00:00, 0)', () {
      final range = axisRange(<TimeBlock>[]);
      expect(range.start, const HourMinute(0, 0));
      expect(range.slots, 0);
    });
  });

  group('slotOffset', () {
    TimeBlock block(HourMinute start, HourMinute end) => TimeBlock(
          id: 'b',
          startsAt: start,
          endsAt: end,
          position: 0,
          active: true,
        );

    test('16:30-17:30 against axisStart 15:30 gives startSlot 2, spanSlots 2',
        () {
      final b = block(const HourMinute(16, 30), const HourMinute(17, 30));
      final offset = slotOffset(b, const HourMinute(15, 30));
      expect(offset.startSlot, 2);
      expect(offset.spanSlots, 2);
    });

    test('30-min block has spanSlots 1', () {
      final b = block(const HourMinute(18, 0), const HourMinute(18, 30));
      final offset = slotOffset(b, const HourMinute(18, 0));
      expect(offset.startSlot, 0);
      expect(offset.spanSlots, 1);
    });
  });
}

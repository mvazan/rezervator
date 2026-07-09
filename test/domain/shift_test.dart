import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/blocks.dart';
import 'package:rezervator/domain/models.dart';

void main() {
  group('shiftBlocks', () {
    const blockA = TimeBlock(
        id: 'a',
        startsAt: HourMinute(15, 30),
        endsAt: HourMinute(16, 30),
        position: 930,
        active: true);
    const blockB = TimeBlock(
        id: 'b',
        startsAt: HourMinute(23, 0),
        endsAt: HourMinute(23, 45),
        position: 1380,
        active: true);

    test('+30 shifts 15:30-16:30 to 16:00-17:00', () {
      final result = shiftBlocks([blockA], 30);
      expect(result, [(const HourMinute(16, 0), const HourMinute(17, 0))]);
    });

    test('-30 shifts 15:30-16:30 to 15:00-16:00', () {
      final result = shiftBlocks([blockA], -30);
      expect(result, [(const HourMinute(15, 0), const HourMinute(16, 0))]);
    });

    test('block shifted past 24:00 is dropped', () {
      final result = shiftBlocks([blockB], 30);
      expect(result, isEmpty);
    });

    test('empty input yields empty output', () {
      final result = shiftBlocks([], 30);
      expect(result, isEmpty);
    });

    test('output is sorted by start time', () {
      const early = TimeBlock(
          id: 'e',
          startsAt: HourMinute(9, 0),
          endsAt: HourMinute(10, 0),
          position: 540,
          active: true);
      const late = TimeBlock(
          id: 'l',
          startsAt: HourMinute(12, 0),
          endsAt: HourMinute(13, 0),
          position: 720,
          active: true);
      final result = shiftBlocks([late, early], 30);
      expect(result, [
        (const HourMinute(9, 30), const HourMinute(10, 30)),
        (const HourMinute(12, 30), const HourMinute(13, 30)),
      ]);
    });
  });
}

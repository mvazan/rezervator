import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/blocks.dart';
import 'package:rezervator/domain/models.dart';

void main() {
  group('matchSpecialBlocks', () {
    const existingA = TimeBlock(
        id: 'a',
        startsAt: HourMinute(10, 0),
        endsAt: HourMinute(11, 0),
        position: 600,
        active: false);
    const existingB = TimeBlock(
        id: 'b',
        startsAt: HourMinute(14, 0),
        endsAt: HourMinute(15, 30),
        position: 840,
        active: false);

    test('empty requested list yields no reuse and no create', () {
      final result = matchSpecialBlocks(
        existingInactive: [existingA, existingB],
        requested: [],
      );
      expect(result.reuseIds, isEmpty);
      expect(result.toCreate, isEmpty);
    });

    test('exact start+end match reuses the existing inactive block', () {
      final result = matchSpecialBlocks(
        existingInactive: [existingA, existingB],
        requested: [(const HourMinute(10, 0), const HourMinute(11, 0))],
      );
      expect(result.reuseIds, ['a']);
      expect(result.toCreate, isEmpty);
    });

    test('no matching existing block creates the requested range', () {
      final result = matchSpecialBlocks(
        existingInactive: [existingA, existingB],
        requested: [(const HourMinute(9, 0), const HourMinute(9, 30))],
      );
      expect(result.reuseIds, isEmpty);
      expect(result.toCreate, [(const HourMinute(9, 0), const HourMinute(9, 30))]);
    });

    test('mix of reuse and create across multiple requested ranges', () {
      final result = matchSpecialBlocks(
        existingInactive: [existingA, existingB],
        requested: [
          (const HourMinute(10, 0), const HourMinute(11, 0)), // reuse a
          (const HourMinute(16, 0), const HourMinute(17, 0)), // create
          (const HourMinute(14, 0), const HourMinute(15, 30)), // reuse b
        ],
      );
      expect(result.reuseIds, ['a', 'b']);
      expect(result.toCreate, [(const HourMinute(16, 0), const HourMinute(17, 0))]);
    });

    test('a partial time overlap (not exact) does not count as a match', () {
      final result = matchSpecialBlocks(
        existingInactive: [existingA],
        requested: [(const HourMinute(10, 0), const HourMinute(11, 30))],
      );
      expect(result.reuseIds, isEmpty);
      expect(result.toCreate, [(const HourMinute(10, 0), const HourMinute(11, 30))]);
    });

    test('active blocks passed as existingInactive are still matched by exact time (caller filters activeness)',
        () {
      // matchSpecialBlocks itself is a pure time-matcher; the caller is
      // responsible for passing only inactive blocks. Verifies it doesn't
      // re-filter on `active` internally (no hidden dependency).
      const activeButSameTime = TimeBlock(
          id: 'active1',
          startsAt: HourMinute(10, 0),
          endsAt: HourMinute(11, 0),
          position: 600,
          active: true);
      final result = matchSpecialBlocks(
        existingInactive: [activeButSameTime],
        requested: [(const HourMinute(10, 0), const HourMinute(11, 0))],
      );
      expect(result.reuseIds, ['active1']);
    });
  });
}

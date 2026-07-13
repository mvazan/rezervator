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

  group('buildBoardSegments', () {
    var nextId = 0;
    TimeBlock block(HourMinute start, HourMinute end) => TimeBlock(
          id: 'b${nextId++}',
          startsAt: start,
          endsAt: end,
          position: nextId,
          active: true,
        );

    test('adjacent blocks emit no gap segments (zero-length gap)', () {
      final segments = buildBoardSegments(
        railBlocks: [
          block(const HourMinute(16, 0), const HourMinute(17, 0)),
          block(const HourMinute(17, 0), const HourMinute(18, 0)),
        ],
        eventWindows: const [],
        laneCount: 4,
      );
      expect(segments, hasLength(2));
      expect(segments, everyElement(isA<BlockSegment>()));
    });

    test('a non-zero empty gap collapses to one fixed sliver', () {
      final segments = buildBoardSegments(
        railBlocks: [
          block(const HourMinute(15, 30), const HourMinute(16, 30)),
          block(const HourMinute(18, 0), const HourMinute(19, 0)),
        ],
        eventWindows: const [],
        laneCount: 4,
      );
      expect(segments, hasLength(3));
      final gap = segments[1];
      expect(gap, isA<EmptyGapSegment>());
      expect(gap.height, emptyGapHeight);
      expect(gap.start, const HourMinute(16, 30));
      expect(gap.end, const HourMinute(18, 0));
    });

    test('an event in a gap makes it occupied and duration-proportional', () {
      final segments = buildBoardSegments(
        railBlocks: [
          block(const HourMinute(15, 30), const HourMinute(16, 30)),
          block(const HourMinute(19, 0), const HourMinute(20, 0)),
        ],
        // Rental 17:00–18:00 inside the 16:30–19:00 gap.
        eventWindows: const [(HourMinute(17, 0), HourMinute(18, 0))],
        laneCount: 4,
      );
      // block, empty(16:30–17), occupied(17–18), empty(18–19), block.
      expect(segments, hasLength(5));
      expect(segments[1], isA<EmptyGapSegment>());
      final occupied = segments[2];
      expect(occupied, isA<OccupiedGapSegment>());
      // Same px/min scale as blocks: 60 min × 4 lanes × 40/60 = 160.
      expect(occupied.height, 160.0);
      expect(segments[3], isA<EmptyGapSegment>());
    });

    test('a very short event floors at minOccupiedGapHeight', () {
      final segments = buildBoardSegments(
        railBlocks: [
          block(const HourMinute(15, 0), const HourMinute(16, 0)),
          block(const HourMinute(18, 0), const HourMinute(19, 0)),
        ],
        eventWindows: const [(HourMinute(16, 30), HourMinute(16, 40))],
        laneCount: 2,
      );
      final occupied = segments.whereType<OccupiedGapSegment>().single;
      expect(occupied.height, minOccupiedGapHeight);
    });

    test('event fully inside a block adds no gap segment', () {
      final segments = buildBoardSegments(
        railBlocks: [block(const HourMinute(16, 0), const HourMinute(17, 0))],
        eventWindows: const [(HourMinute(16, 0), HourMinute(17, 0))],
        laneCount: 4,
      );
      expect(segments, hasLength(1));
      expect(segments.single, isA<BlockSegment>());
    });

    test('event spilling out of a block occupies only the spill', () {
      final segments = buildBoardSegments(
        railBlocks: [
          block(const HourMinute(15, 0), const HourMinute(16, 0)),
          block(const HourMinute(16, 0), const HourMinute(17, 0)),
        ],
        // Match 16:30–18:30 spills 17:00–18:30 past the last block.
        eventWindows: const [(HourMinute(16, 30), HourMinute(18, 30))],
        laneCount: 4,
      );
      expect(segments, hasLength(3));
      final trailing = segments.last;
      expect(trailing, isA<OccupiedGapSegment>());
      expect(trailing.start, const HourMinute(17, 0));
      expect(trailing.end, const HourMinute(18, 30));
    });

    test('leading occupied gap exists, leading empty gap never', () {
      final segments = buildBoardSegments(
        railBlocks: [block(const HourMinute(15, 0), const HourMinute(16, 0))],
        eventWindows: const [(HourMinute(12, 0), HourMinute(14, 0))],
        laneCount: 4,
      );
      // occupied(12–14), block(15–16) — the 14–15 empty run between them IS
      // emitted (it lies between timeline content), but nothing before 12.
      expect(segments.first, isA<OccupiedGapSegment>());
      expect(segments.first.start, const HourMinute(12, 0));
      expect(segments[1], isA<EmptyGapSegment>());
      expect(segments.last, isA<BlockSegment>());
    });

    test('windows from two days merge into one occupied run', () {
      final segments = buildBoardSegments(
        railBlocks: [
          block(const HourMinute(15, 0), const HourMinute(16, 0)),
          block(const HourMinute(20, 0), const HourMinute(21, 0)),
        ],
        eventWindows: const [
          (HourMinute(16, 0), HourMinute(17, 30)), // Monday's rental
          (HourMinute(17, 0), HourMinute(18, 0)), // Friday's match
        ],
        laneCount: 4,
      );
      final occupied = segments.whereType<OccupiedGapSegment>().toList();
      expect(occupied, hasLength(1));
      expect(occupied.single.start, const HourMinute(16, 0));
      expect(occupied.single.end, const HourMinute(18, 0));
    });

    test('overlapping blocks produce no phantom gaps', () {
      final segments = buildBoardSegments(
        railBlocks: [
          block(const HourMinute(15, 0), const HourMinute(17, 0)),
          block(const HourMinute(16, 0), const HourMinute(16, 30)),
          block(const HourMinute(17, 0), const HourMinute(18, 0)),
        ],
        eventWindows: const [],
        laneCount: 4,
      );
      expect(segments.whereType<BlockSegment>(), hasLength(3));
      expect(segments.whereType<EmptyGapSegment>(), isEmpty);
      expect(segments.whereType<OccupiedGapSegment>(), isEmpty);
    });

    test('segmentIndexForTime: inside block, inside gap, before, after', () {
      final segments = buildBoardSegments(
        railBlocks: [
          block(const HourMinute(15, 30), const HourMinute(16, 30)),
          block(const HourMinute(18, 0), const HourMinute(19, 0)),
        ],
        eventWindows: const [],
        laneCount: 4,
      );
      // [block 15:30–16:30, empty 16:30–18:00, block 18:00–19:00]
      expect(segmentIndexForTime(segments, const HourMinute(10, 0)), 0);
      expect(segmentIndexForTime(segments, const HourMinute(16, 0)), 0);
      expect(segmentIndexForTime(segments, const HourMinute(17, 0)), 1);
      expect(segmentIndexForTime(segments, const HourMinute(18, 30)), 2);
      expect(segmentIndexForTime(segments, const HourMinute(23, 0)), 2);
      expect(segmentIndexForTime(const [], const HourMinute(12, 0)), 0);
    });
  });
}

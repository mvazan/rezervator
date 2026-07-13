import '../../domain/models.dart';

/// Height (px) of one lane-row inside a block whose duration is [minutes],
/// scaled so a [refMinutes]-long block is exactly [refLaneRowHeight] tall.
/// Guards a floor so very short blocks stay tappable.
double laneRowHeight(
  int minutes, {
  int refMinutes = 60,
  double refLaneRowHeight = 40.0,
  double minLaneRowHeight = 22.0,
}) {
  final h = refLaneRowHeight * minutes / refMinutes;
  return h < minLaneRowHeight ? minLaneRowHeight : h;
}

/// Total height of a block's row-group = laneCount lane-rows.
double blockGroupHeight(
  TimeBlock block,
  int laneCount, {
  int refMinutes = 60,
  double refLaneRowHeight = 40.0,
  double minLaneRowHeight = 22.0,
}) =>
    laneCount *
    laneRowHeight(block.durationMinutes,
        refMinutes: refMinutes,
        refLaneRowHeight: refLaneRowHeight,
        minLaneRowHeight: minLaneRowHeight);

/// Fixed height of an [EmptyGapSegment] — a thin "time passes here" seam.
/// Deliberately NOT proportional: an empty 3h gap must not waste board space.
const double emptyGapHeight = 12.0;

/// Minimum height of an [OccupiedGapSegment], so its event band stays legible
/// even for very short events.
const double minOccupiedGapHeight = 36.0;

/// One vertical span of the shared board timeline. The rail and EVERY day
/// column consume the same ordered segment list, so cross-column alignment
/// holds by construction — per-day data only selects what renders INSIDE a
/// segment, never its height or position.
sealed class BoardSegment {
  const BoardSegment(
      {required this.start, required this.end, required this.height});

  final HourMinute start;
  final HourMinute end;
  final double height;
}

/// A global time block — rendered exactly as before (lane rows / banners).
class BlockSegment extends BoardSegment {
  const BlockSegment(
      {required this.block,
      required super.start,
      required super.end,
      required super.height});

  final TimeBlock block;
}

/// A gap between/around blocks where at least one visible day has a match or
/// rental. Height is duration-proportional (same px/min scale as blocks) so
/// events sit at their true time, floored at [minOccupiedGapHeight].
class OccupiedGapSegment extends BoardSegment {
  const OccupiedGapSegment(
      {required super.start, required super.end, required super.height});
}

/// A gap where no visible day has anything: a fixed thin sliver.
class EmptyGapSegment extends BoardSegment {
  const EmptyGapSegment(
      {required super.start, required super.end, required super.height});
}

/// Builds the shared timeline: one [BlockSegment] per rail block (merged,
/// start-sorted) plus gap segments derived from [eventWindows] — the real
/// `[start, end)` windows of ALL visible days' matches and rentals. Gap time
/// covered by some event on ANY day becomes [OccupiedGapSegment]; the rest
/// collapses to [EmptyGapSegment] slivers (zero-length gaps emit nothing).
/// Leading/trailing gaps exist only when occupied.
List<BoardSegment> buildBoardSegments({
  required List<TimeBlock> railBlocks,
  required List<(HourMinute, HourMinute)> eventWindows,
  required int laneCount,
  int refMinutes = 60,
  double refLaneRowHeight = 40.0,
  double minLaneRowHeight = 22.0,
}) {
  double proportional(int minutes) =>
      laneCount *
      refLaneRowHeight *
      minutes /
      refMinutes; // no per-lane floor: gaps have no lane rows

  // Merge (possibly overlapping) block intervals into a union, remembering
  // nothing — the union only shapes where gaps are. Blocks themselves render
  // one segment each, in start order.
  final blocks = [...railBlocks]
    ..sort((a, b) => a.startsAt.compareTo(b.startsAt));
  final blockUnion = _mergeIntervals([
    for (final b in blocks) (b.startsAt.minutesFromMidnight, b.endsAt.minutesFromMidnight),
  ]);

  // Event windows minus the block union = candidate occupied intervals.
  final occupied = _mergeIntervals([
    for (final (s, e) in eventWindows)
      ..._subtract((s.minutesFromMidnight, e.minutesFromMidnight), blockUnion),
  ]);

  HourMinute at(int minutes) =>
      HourMinute((minutes ~/ 60).clamp(0, 23), minutes % 60);

  if (blocks.isEmpty && occupied.isEmpty) return const [];

  final segments = <BoardSegment>[];

  /// Splits the gap [from, to) into maximal occupied/empty runs. The
  /// timeline starts and ends on content, so an empty run here is always
  /// BETWEEN content — never a leading/trailing sliver.
  void emitGap(int from, int to) {
    if (to <= from) return;
    var cursor = from;
    for (final (s, e) in occupied) {
      final os = s < from ? from : s;
      final oe = e > to ? to : e;
      if (oe <= cursor || os >= to) continue;
      if (os > cursor) {
        segments.add(EmptyGapSegment(
            start: at(cursor), end: at(os), height: emptyGapHeight));
      }
      final h = proportional(oe - os);
      segments.add(OccupiedGapSegment(
          start: at(os),
          end: at(oe),
          height: h < minOccupiedGapHeight ? minOccupiedGapHeight : h));
      cursor = oe;
    }
    if (cursor < to) {
      segments.add(EmptyGapSegment(
          start: at(cursor), end: at(to), height: emptyGapHeight));
    }
  }

  // Timeline bounds = first/last CONTENT (block or occupied interval); walk
  // block by block, filling every in-between span via emitGap.
  final firstOccupied = occupied.isEmpty ? null : occupied.first.$1;
  final lastOccupied = occupied.isEmpty ? null : occupied.last.$2;
  var cursor = blocks.isEmpty
      ? firstOccupied!
      : (firstOccupied == null
          ? blocks.first.startsAt.minutesFromMidnight
          : (firstOccupied < blocks.first.startsAt.minutesFromMidnight
              ? firstOccupied
              : blocks.first.startsAt.minutesFromMidnight));

  for (final b in blocks) {
    final s = b.startsAt.minutesFromMidnight;
    if (s > cursor) emitGap(cursor, s);
    segments.add(BlockSegment(
      block: b,
      start: b.startsAt,
      end: b.endsAt,
      height: blockGroupHeight(b, laneCount,
          refMinutes: refMinutes,
          refLaneRowHeight: refLaneRowHeight,
          minLaneRowHeight: minLaneRowHeight),
    ));
    final e = b.endsAt.minutesFromMidnight;
    if (e > cursor) cursor = e;
  }

  if (lastOccupied != null && lastOccupied > cursor) {
    emitGap(cursor, lastOccupied);
  }

  return segments;
}

/// Index of the segment containing [now], or the next one after it —
/// clamped to the last segment when the day is over. Mirrors the old
/// current-or-next block lookup, but over segments. Empty list → 0.
int segmentIndexForTime(List<BoardSegment> segments, HourMinute now) {
  final minutes = now.minutesFromMidnight;
  for (var i = 0; i < segments.length; i++) {
    if (minutes < segments[i].end.minutesFromMidnight) return i;
  }
  return segments.isEmpty ? 0 : segments.length - 1;
}

/// Merges half-open int intervals into a sorted non-overlapping union.
List<(int, int)> _mergeIntervals(List<(int, int)> intervals) {
  final valid = [
    for (final (s, e) in intervals)
      if (e > s) (s, e),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  final merged = <(int, int)>[];
  for (final (s, e) in valid) {
    if (merged.isNotEmpty && s <= merged.last.$2) {
      if (e > merged.last.$2) {
        merged[merged.length - 1] = (merged.last.$1, e);
      }
    } else {
      merged.add((s, e));
    }
  }
  return merged;
}

/// [interval] minus the union [holes] (sorted, non-overlapping).
List<(int, int)> _subtract((int, int) interval, List<(int, int)> holes) {
  var (s, e) = interval;
  final out = <(int, int)>[];
  for (final (hs, he) in holes) {
    if (he <= s || hs >= e) continue;
    if (hs > s) out.add((s, hs));
    if (he > s) s = he;
    if (s >= e) return out;
  }
  if (e > s) out.add((s, e));
  return out;
}

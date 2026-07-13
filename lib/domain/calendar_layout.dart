/// Pure-Dart geometry of the calendar-style schedule views (kiosk board +
/// the app's week view): a time window derived from the visible content, and
/// the px/minute mapping every column AND the hour ruler share. y = time is
/// the whole trick — cross-column alignment holds by construction because
/// there is exactly one function from time to pixels (the PR #12–14 lesson,
/// now structural).
library;

import 'models.dart';

/// The vertical time span a calendar view renders, in minutes from midnight,
/// aligned outward to whole hours (the ruler labels whole hours).
class CalendarWindow {
  const CalendarWindow(this.startMinute, this.endMinute)
      : assert(endMinute > startMinute);

  /// Inclusive start, multiple of 60.
  final int startMinute;

  /// Exclusive end, multiple of 60 (capped at 24:00).
  final int endMinute;

  int get minutes => endMinute - startMinute;

  double topFor(HourMinute time, double pxPerMinute) =>
      (time.minutesFromMidnight - startMinute) * pxPerMinute;

  double heightFor(HourMinute start, HourMinute end, double pxPerMinute) =>
      (end.minutesFromMidnight - start.minutesFromMidnight) * pxPerMinute;

  /// Inverse of [topFor]: the minute-from-midnight under a vertical offset,
  /// clamped into the window. Used to turn a tap on empty calendar space
  /// into a time.
  int minuteAt(double dy, double pxPerMinute) =>
      (startMinute + dy / pxPerMinute).round().clamp(startMinute, endMinute);
}

/// Window spanning all [blocks] plus [eventWindows] (off-block priority
/// slots/rentals — they must extend the window or they'd render clipped),
/// floored/ceiled to whole hours. Null when there is no content at all.
CalendarWindow? calendarWindowFor({
  required Iterable<TimeBlock> blocks,
  Iterable<(HourMinute, HourMinute)> eventWindows = const [],
}) {
  int? min, max;
  void cover(int s, int e) {
    if (e <= s) return;
    min = min == null || s < min! ? s : min;
    max = max == null || e > max! ? e : max;
  }

  for (final b in blocks) {
    cover(b.startsAt.minutesFromMidnight, b.endsAt.minutesFromMidnight);
  }
  for (final (s, e) in eventWindows) {
    cover(s.minutesFromMidnight, e.minutesFromMidnight);
  }
  if (min == null) return null;
  return CalendarWindow(min! ~/ 60 * 60, ((max! + 59) ~/ 60 * 60).clamp(0, 24 * 60));
}

/// Minutes-from-midnight → [HourMinute], clamped to 23:59 ([HourMinute] has
/// no 24:00; a window/gap end of 1440 becomes the app-wide "latest end").
/// Clamping the MINUTE COUNT (not the hour alone) is the point: a naive
/// `hour.clamp(0, 23)` would turn 1440 into 23:00 — an hour short.
HourMinute hourMinuteAt(int minutes) {
  final m = minutes.clamp(0, 24 * 60 - 1);
  return HourMinute(m ~/ 60, m % 60);
}

/// Merges half-open `(startMinute, endMinute)` intervals into a sorted
/// non-overlapping union (zero/negative-length inputs are dropped).
List<(int, int)> mergeIntervals(Iterable<(int, int)> intervals) {
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

/// [interval] minus the union [holes] (sorted, non-overlapping — i.e. the
/// output of [mergeIntervals]): the pieces of an event window that fall
/// outside a day's blocks and therefore render as calendar bands of their
/// own (the in-block part renders via slot states).
List<(int, int)> subtractInterval((int, int) interval, List<(int, int)> holes) {
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

/// The maximal free interval of [window] containing [minute], where "free"
/// means not covered by [occupied] (pass the union of block AND event
/// windows — an admin tapping an off-block rental band must not be offered
/// a block over it). Null when [minute] lies inside occupied time or
/// outside the window. This is what prefills the add-block dialog when an
/// admin taps empty calendar space.
(int, int)? freeGapAt(
  int minute,
  List<(int, int)> occupied,
  CalendarWindow window,
) {
  if (minute < window.startMinute || minute >= window.endMinute) return null;
  var start = window.startMinute;
  for (final (s, e) in occupied) {
    if (minute >= s && minute < e) return null;
    if (e <= minute) {
      start = e > start ? e : start;
    } else if (s >= minute) {
      return (start, s < window.endMinute ? s : window.endMinute);
    }
  }
  return (start, window.endMinute);
}

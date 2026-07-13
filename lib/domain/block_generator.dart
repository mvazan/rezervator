/// Pure helpers for the admin "Vygenerovat bloky" flow: build an evenly
/// spaced series of block times and check it against the existing grid.
library;

import 'models.dart';

/// [count] blocks starting at [start], each [durationMinutes] long, with
/// [pauseMinutes] between consecutive blocks. Returns null when the inputs
/// are out of range or the series would reach midnight (HourMinute cannot
/// represent times past 23:59, so the last block must end by 23:59).
List<(HourMinute, HourMinute)>? generateBlockTimes({
  required HourMinute start,
  required int durationMinutes,
  required int pauseMinutes,
  required int count,
}) {
  if (count < 1 || durationMinutes < 1 || pauseMinutes < 0) return null;
  final total = count * durationMinutes + (count - 1) * pauseMinutes;
  if (start.minutesFromMidnight + total >= 24 * 60) return null;

  HourMinute at(int minutes) => HourMinute(minutes ~/ 60, minutes % 60);
  return [
    for (var i = 0; i < count; i++)
      (
        at(start.minutesFromMidnight + i * (durationMinutes + pauseMinutes)),
        at(start.minutesFromMidnight +
            i * (durationMinutes + pauseMinutes) +
            durationMinutes),
      ),
  ];
}

/// Labels of ACTIVE existing blocks that overlap any candidate time range.
/// Non-empty result means the generator output must not be saved.
List<String> generatorConflicts(
  List<(HourMinute, HourMinute)> candidates,
  List<TimeBlock> existing,
) {
  bool overlaps((HourMinute, HourMinute) a, TimeBlock b) =>
      a.$1.compareTo(b.endsAt) < 0 && b.startsAt.compareTo(a.$2) < 0;
  return [
    for (final block in existing)
      if (block.active && candidates.any((c) => overlaps(c, block)))
        block.label,
  ];
}

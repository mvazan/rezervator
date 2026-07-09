/// Pure helper for the day-override custom-times editor: for each requested
/// [starts_at, ends_at) range, reuse an existing inactive "special" block if
/// one has the exact same start+end, otherwise mark it to be created. Keeps
/// find-or-create logic (and its unit tests) out of the RPC/UI layer.
library;

import 'models.dart';

({List<String> reuseIds, List<(HourMinute, HourMinute)> toCreate})
    matchSpecialBlocks({
  required List<TimeBlock> existingInactive,
  required List<(HourMinute, HourMinute)> requested,
}) {
  final reuseIds = <String>[];
  final toCreate = <(HourMinute, HourMinute)>[];
  for (final range in requested) {
    final match = existingInactive.where(
      (b) => b.startsAt == range.$1 && b.endsAt == range.$2,
    );
    if (match.isNotEmpty) {
      reuseIds.add(match.first.id);
    } else {
      toCreate.add(range);
    }
  }
  return (reuseIds: reuseIds, toCreate: toCreate);
}

/// Shift every block's [start,end] by [offsetMinutes] (e.g. -30 / +30).
/// Blocks that would run before 00:00 or past 24:00 are dropped. Returns
/// (start,end) HourMinute pairs sorted by start — feed into the custom-times
/// editor rows.
List<(HourMinute, HourMinute)> shiftBlocks(
    List<TimeBlock> blocks, int offsetMinutes) {
  final out = <(HourMinute, HourMinute)>[];
  for (final b in blocks) {
    final s = b.startsAt.minutesFromMidnight + offsetMinutes;
    final e = b.endsAt.minutesFromMidnight + offsetMinutes;
    if (s < 0 || e > 24 * 60) continue;
    out.add((HourMinute(s ~/ 60, s % 60), HourMinute(e ~/ 60, e % 60)));
  }
  out.sort((a, b) => a.$1.minutesFromMidnight.compareTo(b.$1.minutesFromMidnight));
  return out;
}

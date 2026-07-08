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

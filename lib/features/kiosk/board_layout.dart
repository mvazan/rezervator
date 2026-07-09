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

/// Height (px) of one 30-min axis unit for [laneCount] lanes. A block
/// spanning N half-hours is N*unit tall; lanes split that height.
/// [laneUnit30] is the per-lane height of a 30-min unit.
double axisUnit(int laneCount, {double laneUnit30 = 22.0}) =>
    laneCount * laneUnit30;

/// Rounds [minutes] down to the nearest multiple of 30.
int _floorTo30(int minutes) => minutes - minutes % 30;

/// Rounds [minutes] up to the nearest multiple of 30.
int _ceilTo30(int minutes) {
  final rem = minutes % 30;
  return rem == 0 ? minutes : minutes + (30 - rem);
}

/// The axis start (earliest block start across all blocks, floored to
/// :00/:30) and the number of 30-min slots to the latest block end (ceiled
/// to :00/:30). Empty [blocks] → (00:00, 0).
///
/// If the ceiled end reaches 24:00, that can't be represented as a
/// [HourMinute] (which asserts hour < 24), so we return axisStart + slots
/// instead of constructing a 24:00 HourMinute directly.
({HourMinute start, int slots}) axisRange(List<TimeBlock> blocks) {
  if (blocks.isEmpty) return (start: const HourMinute(0, 0), slots: 0);

  var minStart = blocks.first.startsAt.minutesFromMidnight;
  var maxEnd = blocks.first.endsAt.minutesFromMidnight;
  for (final b in blocks.skip(1)) {
    final s = b.startsAt.minutesFromMidnight;
    final e = b.endsAt.minutesFromMidnight;
    if (s < minStart) minStart = s;
    if (e > maxEnd) maxEnd = e;
  }

  final floorStart = _floorTo30(minStart);
  final ceilEnd = _ceilTo30(maxEnd);
  final slots = (ceilEnd - floorStart) ~/ 30;
  final startHour = floorStart ~/ 60;
  final startMinute = floorStart % 60;
  return (start: HourMinute(startHour, startMinute), slots: slots);
}

/// Where a block sits on the axis: (startSlot index from [axisStart],
/// spanSlots).
({int startSlot, int spanSlots}) slotOffset(
    TimeBlock block, HourMinute axisStart) {
  final s = (block.startsAt.minutesFromMidnight -
          axisStart.minutesFromMidnight) ~/
      30;
  final span =
      (block.endsAt.minutesFromMidnight - block.startsAt.minutesFromMidnight) ~/
          30;
  return (startSlot: s, spanSlots: span);
}

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

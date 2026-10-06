/// What a „uvolnilo se místo“ notification finds when it is opened: the spot
/// it was about may be free still, or taken again in the meantime, or the
/// block may have started. Pure — the screen only shows the answer.
library;

import 'models.dart';
import 'schedule.dart';

enum FreedSpotOutcome {
  /// Free and the caller can book it: the cell is highlighted.
  free,

  /// Free, but the caller is at their reservation limit.
  limit,

  /// Somebody booked it again (or a rental / a match took it).
  taken,

  /// The caller booked it themselves.
  mine,

  /// The block has started (or the day is over).
  past,

  /// The day is closed now.
  closed,

  /// The block is no longer in the day's schedule.
  gone,
}

class FreedSpotResult {
  const FreedSpotResult(this.outcome, {this.othersFree = 0});

  final FreedSpotOutcome outcome;

  /// How many other cells of that day the caller could book — the answer to
  /// „and is there anything left?“ when the spot itself is gone.
  final int othersFree;

  /// Text for a snackbar; null when the spot is free (the highlight says it).
  String? get message => switch (outcome) {
    FreedSpotOutcome.free => null,
    FreedSpotOutcome.limit =>
      'Místo je volné, ale už máš nejvyšší počet rezervací.',
    FreedSpotOutcome.mine => 'Tohle místo už máš zarezervované.',
    FreedSpotOutcome.past => 'Tenhle trénink už začal.',
    FreedSpotOutcome.closed => 'V tento den je zavřeno.',
    FreedSpotOutcome.gone => 'Tenhle termín už v rozvrhu není.',
    FreedSpotOutcome.taken => othersFree == 0
        ? 'Místo už je zase obsazené a v tento den nic volného nezbylo.'
        : 'Místo už je zase obsazené. V tento den ${_free(othersFree)}.',
  };
}

String _free(int n) => switch (n) {
  1 => 'zbývá ještě 1 volné místo',
  >= 2 && <= 4 => 'zbývají ještě $n volná místa',
  _ => 'zbývá ještě $n volných míst',
};

/// The state of the spot ([blockId], [lane]) in [day]. The booking inputs are
/// the ones the calendar's own cells use ([canBook]), so „free“ here is
/// exactly „the cell offers a +“.
FreedSpotResult freedSpotResult(
  DaySchedule day, {
  required String blockId,
  required int lane,
  required String? myPlayerId,
  required int myActiveCount,
  required ScheduleSettings settings,
  bool isAdmin = false,
  bool forGroup = false,
  bool onDuty = false,
}) {
  if (day is! OpenDay) return const FreedSpotResult(FreedSpotOutcome.closed);
  if (!day.blocks.any((b) => b.id == blockId) ||
      lane < 1 ||
      lane > day.laneCount) {
    return const FreedSpotResult(FreedSpotOutcome.gone);
  }
  int others() => bookableSlotCount(
    day,
    myActiveCount: myActiveCount,
    settings: settings,
    isAdmin: isAdmin,
    forGroup: forGroup,
    onDuty: onDuty,
  );
  final state = day.slot(blockId, lane);
  if (state is FreeSlot) {
    if (state.inPast && !isAdmin) {
      return const FreedSpotResult(FreedSpotOutcome.past);
    }
    final bookable = canBook(
      state: state,
      myActiveCount: myActiveCount,
      settings: settings,
      isAdmin: isAdmin,
      forGroup: forGroup,
      onDuty: onDuty,
    );
    return FreedSpotResult(
      bookable ? FreedSpotOutcome.free : FreedSpotOutcome.limit,
    );
  }
  if (state.inPast) return const FreedSpotResult(FreedSpotOutcome.past);
  if (state is ReservedSlot &&
      myPlayerId != null &&
      state.reservation.playerId == myPlayerId) {
    return const FreedSpotResult(FreedSpotOutcome.mine);
  }
  return FreedSpotResult(FreedSpotOutcome.taken, othersFree: others());
}

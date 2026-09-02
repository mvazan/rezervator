/// The two callback bundles the schedule views take — threaded once from
/// the screen down to the tiles, so adding a gesture is one field here
/// instead of a parameter on every widget in between.
library;

import '../../domain/models.dart';

/// What a slot tile can do: book a free slot, cancel a reservation.
class SlotCallbacks {
  const SlotCallbacks({required this.onBook, required this.onCancel});

  final void Function(Day date, TimeBlock block, int lane) onBook;

  /// [ownFuture]: the tapper's own not-yet-started reservation (plain
  /// confirm) vs an admin cancelling someone else's (notify choice).
  final void Function(
    Day date,
    TimeBlock block,
    Reservation reservation, {
    required bool ownFuture,
  }) onCancel;
}

/// The calendar boards' admin gestures — every hook optional (null = not
/// offered). [none] is the read-only board (non-admins, the kiosk).
class CalendarAdminHooks {
  const CalendarAdminHooks({
    this.onEditBlock,
    this.onAddBlockInGap,
    this.onAddForDay,
    this.onEditPrioritySlot,
    this.onMoveBlock,
    this.onMovePrioritySlot,
  });

  static const none = CalendarAdminHooks();

  /// Click the card's time header: edit the block FOR THAT DAY.
  final void Function(Day date, TimeBlock block)? onEditBlock;

  /// Tap empty column space: add a block prefilled with the free gap.
  final void Function(Day date, HourMinute start, HourMinute end)?
      onAddBlockInGap;

  /// Tap the day header: add a slot to a packed column.
  final void Function(Day date)? onAddForDay;

  /// Click a blocking band: edit the slot (an úklid child opens its match).
  final void Function(Day date, PrioritySlot slot)? onEditPrioritySlot;

  /// HOLD a card and drop it on empty space: move it within the day.
  final void Function(Day date, TimeBlock block, HourMinute newStart)?
      onMoveBlock;

  /// HOLD a band and drop it: move the slot (its úklid child follows).
  final void Function(Day date, PrioritySlot slot, HourMinute newStart)?
      onMovePrioritySlot;
}

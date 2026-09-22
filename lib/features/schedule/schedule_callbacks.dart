/// The two callback bundles the schedule views take — threaded once from
/// the screen down to the tiles, so adding a gesture is one field here
/// instead of a parameter on every widget in between.
library;

import '../../domain/models.dart';

/// What a slot tile can do: book a free slot, cancel a reservation, edit
/// a rental (admins).
class SlotCallbacks {
  const SlotCallbacks({
    required this.onBook,
    required this.onCancel,
    this.onRental,
    this.onInfo,
    this.groupMateIds = const {},
  });

  final void Function(Day date, TimeBlock block, int lane) onBook;

  /// [ownFuture]: the tapper's own not-yet-started reservation (plain
  /// confirm) vs an admin cancelling someone else's (notify choice).
  final void Function(
    Day date,
    TimeBlock block,
    Reservation reservation, {
    required bool ownFuture,
  }) onCancel;

  /// Admin only: tap a rented cell to edit that day's rental — a weekly one
  /// opens its "jen tento den" exception dialog, a one-time one the plain
  /// dialog. Null = the cell stays inert.
  final void Function(Day date, Rental rental)? onRental;

  /// A regular player taps someone else's reservation, which [onCancel]
  /// never fires for (they cannot cancel it) — the board's nick can be too
  /// short to say who that even is. Null on the pure read-only board (no
  /// signed-in player, e.g. the kiosk), which never calls this either.
  final void Function(Day date, TimeBlock block, Reservation reservation)?
      onInfo;

  /// Group mates (0044) whose reservations the signed-in player may book
  /// and cancel as their own. Empty outside a group, for admins it does not
  /// matter (they may anything), the kiosk never sets it.
  final Set<String> groupMateIds;
}

/// The calendar boards' admin gestures — every hook optional (null = not
/// offered). [none] is the read-only board (non-admins, the kiosk).
class CalendarAdminHooks {
  const CalendarAdminHooks({
    this.onEditBlock,
    this.onAddBlockInGap,
    this.onAddForDay,
    this.onEditPrioritySlot,
    this.onEditRental,
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

  /// Click a rental band: edit that day's occurrence (a weekly rental's
  /// "jen tento den" exception; a one-time rental opens the plain dialog).
  final void Function(Day date, Rental rental)? onEditRental;

  /// HOLD a card and drop it on empty space: move it within the day.
  final void Function(Day date, TimeBlock block, HourMinute newStart)?
      onMoveBlock;

  /// HOLD a band and drop it: move the slot (its úklid child follows).
  final void Function(Day date, PrioritySlot slot, HourMinute newStart)?
      onMovePrioritySlot;
}

/// Weekly schedule computation — the heart of the virtual-schedule design.
/// Pure Dart, fully unit-tested; all time is injected by the caller.
library;

import 'models.dart';

sealed class SlotState {
  const SlotState({required this.inPast, required this.beyondHorizon});

  /// Block start (date + starts_at) is at or before the injected now.
  final bool inPast;

  /// Date lies beyond the admin-configured booking horizon.
  final bool beyondHorizon;
}

class FreeSlot extends SlotState {
  const FreeSlot({required super.inPast, required super.beyondHorizon});
}

class ReservedSlot extends SlotState {
  const ReservedSlot(this.reservation,
      {required super.inPast, required super.beyondHorizon});

  final Reservation reservation;
}

class RentedSlot extends SlotState {
  const RentedSlot(this.rental,
      {required super.inPast, required super.beyondHorizon});

  final Rental rental;
}

class PrioritySlotState extends SlotState {
  const PrioritySlotState(this.slot,
      {required super.inPast, required super.beyondHorizon, this.isPrep = false});

  final PrioritySlot slot;

  /// True when this cell is covered only by the slot's prep-time extension
  /// ([PrioritySlot.blockingStart]..[PrioritySlot.startsAt]) and does NOT
  /// overlap the real `[startsAt, endsAt)` window — UI shows
  /// "🛠 Příprava drah" instead of the banner.
  final bool isPrep;
}

sealed class DaySchedule {
  const DaySchedule(
      {required this.date, required this.priority, this.rentals = const []});

  final Day date;

  /// Priority slots (matches & co.) are shown even on closed days —
  /// spectators want to see who plays.
  final List<PrioritySlot> priority;

  /// The day's rentals (weekly occurrences resolved), so renderers can place
  /// ones lying outside every block at their true time.
  final List<Rental> rentals;
}

class ClosedDay extends DaySchedule {
  const ClosedDay(
      {required super.date,
      required super.priority,
      super.rentals,
      this.reason = ''});

  final String reason;
}

class OpenDay extends DaySchedule {
  OpenDay({
    required super.date,
    required super.priority,
    super.rentals,
    required this.blocks,
    required this.laneCount,
    required Map<String, SlotState> slots,
  }) : _slots = slots;

  final List<TimeBlock> blocks;
  final int laneCount;
  final Map<String, SlotState> _slots;

  SlotState slot(String blockId, int lane) {
    final state = _slots['$blockId|$lane'];
    if (state == null) throw StateError('unknown slot $blockId|$lane');
    return state;
  }
}

class WeekSchedule {
  const WeekSchedule(this.days);

  /// Exactly 7 entries, Monday..Sunday.
  final List<DaySchedule> days;
}

/// Half-open interval overlap: `[aStart, aEnd)` × `[bStart, bEnd)`.
bool timesOverlap(
        HourMinute aStart, HourMinute aEnd, HourMinute bStart, HourMinute bEnd) =>
    aStart.minutesFromMidnight < bEnd.minutesFromMidnight &&
    aEnd.minutesFromMidnight > bStart.minutesFromMidnight;

/// A match/rental lying entirely outside every rendered block — the grids
/// place these into gap rows/segments at their real times.
sealed class OffBlockEvent {
  const OffBlockEvent(this.start, this.end);

  final HourMinute start;
  final HourMinute end;
}

class OffBlockPriority extends OffBlockEvent {
  OffBlockPriority(this.slot) : super(slot.startsAt, slot.endsAt);

  final PrioritySlot slot;
}

class OffBlockRental extends OffBlockEvent {
  OffBlockRental(this.rental) : super(rental.startsAt, rental.endsAt);

  final Rental rental;
}

/// Time-sorted events on a day that overlap NO block in [blocks]; events
/// overlapping any block keep rendering via slot states instead. Matches use
/// their real window (not prep-extended — prep only matters where it blocks
/// reservations, and off-block time has none).
///
/// [blocks] must be EXACTLY the day's rendered block set ([OpenDay.blocks]) —
/// no extra active-filtering here, because an override day may legitimately
/// render inactive "special" blocks, and an event inside one must keep
/// resolving via slot states rather than double-render as a banner too.
List<OffBlockEvent> offBlockEvents({
  required List<PrioritySlot> priority,
  required List<Rental> rentals,
  required List<TimeBlock> blocks,
}) {
  bool outside(HourMinute start, HourMinute end) =>
      !blocks.any((b) => timesOverlap(start, end, b.startsAt, b.endsAt));
  return <OffBlockEvent>[
    for (final m in priority)
      if (outside(m.startsAt, m.endsAt)) OffBlockPriority(m),
    for (final r in rentals)
      if (outside(r.startsAt, r.endsAt)) OffBlockRental(r),
  ]..sort((a, b) => a.start.compareTo(b.start));
}

T? _firstWhereOrNull<T>(Iterable<T> items, bool Function(T) test) {
  for (final item in items) {
    if (test(item)) return item;
  }
  return null;
}

/// Time-ordered display: earlier start wins; [TimeBlock.position] only
/// breaks ties between blocks that start at the same time.
int _byStartThenPosition(TimeBlock a, TimeBlock b) {
  final byStart = a.startsAt.minutesFromMidnight
      .compareTo(b.startsAt.minutesFromMidnight);
  return byStart != 0 ? byStart : a.position.compareTo(b.position);
}

/// Per-lane resolution: the first priority slot covering [lane] whose
/// prep-extended window overlaps [block], plus the prep-only flag — or
/// `(null, false)`. In practice LANE-SCOPED slots (and, transiently,
/// unresolved-type ones — see [PrioritySlotType.unresolved]) reach a
/// rendered block: resolved whole-alley slots cancel every block their
/// blocking window touches (see [buildWeekSchedule]).
(PrioritySlot?, bool) priorityStateFor(
    TimeBlock block, int lane, List<PrioritySlot> slots) {
  final hit = _firstWhereOrNull(
      slots,
      (PrioritySlot m) =>
          m.coversLane(lane) &&
          timesOverlap(block.startsAt, block.endsAt, m.blockingStart, m.endsAt));
  if (hit == null) return (null, false);
  final isPrep = !timesOverlap(
      block.startsAt, block.endsAt, hit.startsAt, hit.endsAt);
  return (hit, isPrep);
}

WeekSchedule buildWeekSchedule({
  required Day monday,
  required Day today,
  required HourMinute now,
  required ScheduleSettings settings,
  required List<TimeBlock> blocks,
  required List<DayOverride> overrides,
  required List<PrioritySlot> priority,
  required List<Rental> rentals,
  required List<Reservation> reservations,
}) {
  final overrideByDate = {for (final o in overrides) o.date: o};
  final blockById = {for (final b in blocks) b.id: b};
  final activeBlocks = blocks.where((b) => b.active).toList()
    ..sort(_byStartThenPosition);

  final days = <DaySchedule>[];
  for (var i = 0; i < 7; i++) {
    final date = monday.addDays(i);
    final dayPriority = priority.where((m) => m.date == date).toList()
      ..sort((a, b) => a.startsAt.compareTo(b.startsAt));
    final dayRentals = rentals.where((r) => r.occursOn(date)).toList();

    final override = overrideByDate[date];
    if (override != null && override.closed) {
      days.add(ClosedDay(
          date: date,
          priority: dayPriority,
          rentals: dayRentals,
          reason: override.reason));
      continue;
    }

    List<TimeBlock> dayBlocks;
    var reason = '';
    if (override != null) {
      reason = override.reason;
      if (override.blockIds == null) {
        dayBlocks = activeBlocks;
      } else {
        dayBlocks = [
          for (final id in override.blockIds!)
            if (blockById[id] != null) blockById[id]!,
        ]..sort(_byStartThenPosition);
      }
    } else if (!settings.trainingWeekdays.contains(date.weekday)) {
      days.add(ClosedDay(date: date, priority: dayPriority, rentals: dayRentals));
      continue;
    } else {
      dayBlocks = activeBlocks;
    }

    if (dayBlocks.isEmpty) {
      days.add(ClosedDay(
          date: date, priority: dayPriority, rentals: dayRentals, reason: reason));
      continue;
    }

    // A day-scoped SPECIAL block (position < 0, selected via a day
    // override) beats the weekly template the way a priority slot beats
    // blocks: template blocks it overlaps are hidden for the day — and
    // reappear the moment the special shrinks or goes away. Render-time
    // only, so the day's override list keeps every id and the fork is
    // fully reversible.
    final specials = [
      for (final b in dayBlocks)
        if (b.position < 0) b,
    ];
    if (specials.isNotEmpty) {
      dayBlocks = [
        for (final b in dayBlocks)
          if (b.position < 0 ||
              !specials.any((s) =>
                  timesOverlap(b.startsAt, b.endsAt, s.startsAt, s.endsAt)))
            b,
      ];
    }

    // A WHOLE-ALLEY priority slot CANCELS every training block its blocking
    // window (prep included) touches: the block disappears from that day and
    // the slot renders at its true time instead, leaving the freed space
    // visibly empty for the admin to restructure (extend/shift a neighboring
    // block or add a shorter one). Lane-scoped slots keep the block and
    // resolve per lane below. Checked AFTER the emptiness fallback above so a
    // day whose every block is cancelled stays an OpenDay (it hosts a match,
    // it is not "zavřeno").
    // `unresolved` types (the type row hasn't streamed in yet) render like a
    // whole-alley match but must NOT cancel: a lane-scoped slot whose type
    // arrives a beat later would otherwise transiently wipe blocks (and
    // their reservations) off every board.
    final wholeAlley = dayPriority
        .where((m) => m.type.lanes == null && !m.type.unresolved)
        .toList();
    dayBlocks = [
      for (final b in dayBlocks)
        if (!wholeAlley.any((m) =>
            timesOverlap(b.startsAt, b.endsAt, m.blockingStart, m.endsAt)))
          b,
    ];

    final beyondHorizon =
        date.differenceInDays(today) > settings.bookingHorizonDays;
    final dayReservations =
        reservations.where((r) => r.date == date && r.isLive).toList();

    final slots = <String, SlotState>{};
    for (final block in dayBlocks) {
      final inPast = date.isBefore(today) ||
          (date == today &&
              block.startsAt.minutesFromMidnight <= now.minutesFromMidnight);
      for (var lane = 1; lane <= settings.laneCount; lane++) {
        final (laneSlot, isPrep) = priorityStateFor(block, lane, dayPriority);
        final SlotState state;
        if (laneSlot != null) {
          state = PrioritySlotState(laneSlot,
              inPast: inPast, beyondHorizon: beyondHorizon, isPrep: isPrep);
        } else {
          final laneRental = _firstWhereOrNull(
              dayRentals,
              (Rental r) =>
                  r.lanes.contains(lane) &&
                  timesOverlap(block.startsAt, block.endsAt, r.startsAt, r.endsAt));
          if (laneRental != null) {
            state = RentedSlot(laneRental,
                inPast: inPast, beyondHorizon: beyondHorizon);
          } else {
            final reservation = _firstWhereOrNull(dayReservations,
                (Reservation r) => r.blockId == block.id && r.lane == lane);
            state = reservation != null
                ? ReservedSlot(reservation,
                    inPast: inPast, beyondHorizon: beyondHorizon)
                : FreeSlot(inPast: inPast, beyondHorizon: beyondHorizon);
          }
        }
        slots['${block.id}|$lane'] = state;
      }
    }

    days.add(OpenDay(
      date: date,
      priority: dayPriority,
      rentals: dayRentals,
      blocks: dayBlocks,
      laneCount: settings.laneCount,
      slots: slots,
    ));
  }
  return WeekSchedule(days);
}

/// Live reservations counting toward the per-player limit (today or later).
int activeReservationCount(
        Iterable<Reservation> reservations, String playerId, Day today) =>
    reservations
        .where((r) =>
            r.playerId == playerId && r.isLive && !r.date.isBefore(today))
        .length;

/// Client-side mirror of create_reservation's rules — honest UI only,
/// the RPC remains the authority.
bool canBook({
  required SlotState state,
  required int myActiveCount,
  required ScheduleSettings settings,
  bool isAdmin = false,
}) {
  if (state is! FreeSlot) return false;
  if (isAdmin) return true;
  return !state.inPast &&
      !state.beyondHorizon &&
      myActiveCount < settings.maxActiveReservations;
}

/// Own reservation whose block has not started yet may be cancelled in-app.
/// (Admin cancel-anything is a Phase 2 admin affordance.)
bool canCancel({
  required SlotState state,
  required String myPlayerId,
}) =>
    state is ReservedSlot &&
    !state.inPast &&
    state.reservation.playerId == myPlayerId;

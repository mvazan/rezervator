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

class MatchSlot extends SlotState {
  const MatchSlot(this.match,
      {required super.inPast, required super.beyondHorizon});

  final Match match;
}

sealed class DaySchedule {
  const DaySchedule({required this.date, required this.matches});

  final Day date;

  /// Matches are shown even on closed days — spectators want to see who plays.
  final List<Match> matches;
}

class ClosedDay extends DaySchedule {
  const ClosedDay({required super.date, required super.matches, this.reason = ''});

  final String reason;
}

class OpenDay extends DaySchedule {
  OpenDay({
    required super.date,
    required super.matches,
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

bool _overlaps(
        HourMinute aStart, HourMinute aEnd, HourMinute bStart, HourMinute bEnd) =>
    aStart.minutesFromMidnight < bEnd.minutesFromMidnight &&
    aEnd.minutesFromMidnight > bStart.minutesFromMidnight;

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

WeekSchedule buildWeekSchedule({
  required Day monday,
  required Day today,
  required HourMinute now,
  required ScheduleSettings settings,
  required List<TimeBlock> blocks,
  required List<DayOverride> overrides,
  required List<Match> matches,
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
    final dayMatches = matches.where((m) => m.date == date).toList()
      ..sort((a, b) => a.startsAt.compareTo(b.startsAt));

    final override = overrideByDate[date];
    if (override != null && override.closed) {
      days.add(
          ClosedDay(date: date, matches: dayMatches, reason: override.reason));
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
      days.add(ClosedDay(date: date, matches: dayMatches));
      continue;
    } else {
      dayBlocks = activeBlocks;
    }

    if (dayBlocks.isEmpty) {
      days.add(ClosedDay(date: date, matches: dayMatches, reason: reason));
      continue;
    }

    final beyondHorizon =
        date.differenceInDays(today) > settings.bookingHorizonDays;
    final dayRentals = rentals.where((r) => r.occursOn(date)).toList();
    final dayReservations =
        reservations.where((r) => r.date == date && r.isLive).toList();

    final slots = <String, SlotState>{};
    for (final block in dayBlocks) {
      final inPast = date.isBefore(today) ||
          (date == today &&
              block.startsAt.minutesFromMidnight <= now.minutesFromMidnight);
      final blockMatch = _firstWhereOrNull(
          dayMatches,
          (Match m) =>
              _overlaps(block.startsAt, block.endsAt, m.startsAt, m.endsAt));
      for (var lane = 1; lane <= settings.laneCount; lane++) {
        final SlotState state;
        if (blockMatch != null) {
          state = MatchSlot(blockMatch,
              inPast: inPast, beyondHorizon: beyondHorizon);
        } else {
          final laneRental = _firstWhereOrNull(
              dayRentals,
              (Rental r) =>
                  r.lanes.contains(lane) &&
                  _overlaps(block.startsAt, block.endsAt, r.startsAt, r.endsAt));
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
      matches: dayMatches,
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

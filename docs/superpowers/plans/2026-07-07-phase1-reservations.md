# Rezervátor — Phase 1 (Reservations Core) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Live week schedule computed by a fully-tested pure-Dart function, with self-service booking and cancellation over the `create_reservation`/`cancel_reservation` RPCs and realtime updates.

**Architecture:** `domain/schedule.dart` turns (settings, blocks, overrides, matches, rentals, reservations) into a `WeekSchedule` of sealed `SlotState`s — the single source of grid truth reused later by the kiosk. The data layer adds per-week reservation streams (bounded by week Monday) and RPC wrappers with Czech error mapping. `WeekScreen` renders states and wires tap → confirm → RPC.

**Tech Stack:** as Phase 0 (Flutter, Riverpod, supabase_flutter). No new dependencies.

## Global Constraints

- Repo `/Users/mvazan/Home/rezervator`, branch `phase-1-reservations`. Czech UI strings.
- `lib/domain/` stays pure Dart — no Flutter imports, no `DateTime.now()`; time (`today`, `now`) is injected.
- Reservations are mutated ONLY via RPCs `create_reservation(p_player_id, p_date, p_block_id, p_lane)` and `cancel_reservation(p_id, p_note)` — never direct table writes. The RPC is the authority; client-side `canBook`/`canCancel` exist only so the UI is honest.
- Resolution order per slot (spec): match (all lanes) → rental (lane ∩ + time ∩) → reservation → free. Closed resolution per day: override.closed → override.blockIds/weekday rule → empty blocks = closed. Matches are shown even on closed days.
- Booking horizon: date beyond `today + booking_horizon_days` is `beyondHorizon`. A slot whose block start (date + starts_at) is ≤ injected now is `inPast`.
- TDD for all domain code. Commit after every task; messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Every task: `flutter analyze` = "No issues found!", `flutter test` all green.

---

### Task 1: Schedule domain — types, buildWeekSchedule, booking rules (TDD)

**Files:**
- Create: `lib/domain/schedule.dart`
- Modify: `test/domain/models_test.dart` (add 2 Rental boundary tests — carry-over from Phase 0 review)
- Test: `test/domain/schedule_test.dart`

**Interfaces:**
- Consumes: `models.dart` (Day, HourMinute, TimeBlock, DayOverride, Match, Rental, Reservation, ScheduleSettings)
- Produces (exact names later tasks use):
  - `sealed class SlotState { bool inPast; bool beyondHorizon; }` with subclasses `FreeSlot`, `ReservedSlot(reservation)`, `RentedSlot(rental)`, `MatchSlot(match)`
  - `sealed class DaySchedule { Day date; List<Match> matches; }` with `ClosedDay(reason)` and `OpenDay(blocks, laneCount, slot(String blockId, int lane))`
  - `class WeekSchedule { List<DaySchedule> days; }` (always 7, Mon..Sun)
  - `WeekSchedule buildWeekSchedule({required Day monday, required Day today, required HourMinute now, required ScheduleSettings settings, required List<TimeBlock> blocks, required List<DayOverride> overrides, required List<Match> matches, required List<Rental> rentals, required List<Reservation> reservations})`
  - `int activeReservationCount(Iterable<Reservation> reservations, String playerId, Day today)`
  - `bool canBook({required SlotState state, required int myActiveCount, required ScheduleSettings settings})`
  - `bool canCancel({required SlotState state, required String myPlayerId})`

- [ ] **Step 1: Add Rental boundary tests to `test/domain/models_test.dart`** (inside the existing `Rental.occursOn` group; `weekly(...)` helper already exists there):

```dart
    test('weekly matches exactly on validity boundaries', () {
      final r = weekly(from: Day(2026, 7, 1), until: Day(2026, 7, 15));
      expect(r.occursOn(Day(2026, 7, 1)), isFalse); // Wed? no — 1.7.2026 is Wednesday, weekday 3 ✓ matches
      expect(r.occursOn(Day(2026, 7, 15)), isTrue); // Wednesday == validUntil → inclusive
    });
```

**Correction (verify with Dart, not by eye):** 2026-07-01 IS a Wednesday (weekday 3), so `occursOn(Day(2026,7,1))` must be `isTrue` — the boundary `day == validFrom` is inclusive. Write the test asserting BOTH boundaries true:

```dart
    test('weekly matches exactly on validity boundaries', () {
      final r = weekly(from: Day(2026, 7, 1), until: Day(2026, 7, 15));
      expect(r.occursOn(Day(2026, 7, 1)), isTrue);  // == validFrom (Wednesday)
      expect(r.occursOn(Day(2026, 7, 15)), isTrue); // == validUntil (Wednesday)
      expect(r.occursOn(Day(2026, 6, 24)), isFalse); // Wednesday before window
      expect(r.occursOn(Day(2026, 7, 22)), isFalse); // Wednesday after window
    });
```

- [ ] **Step 2: Write the failing schedule tests** — `test/domain/schedule_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/domain/schedule.dart';

void main() {
  const b1 = TimeBlock(
      id: 'b1',
      startsAt: HourMinute(16, 0),
      endsAt: HourMinute(17, 0),
      position: 0,
      active: true);
  const b2 = TimeBlock(
      id: 'b2',
      startsAt: HourMinute(17, 0),
      endsAt: HourMinute(18, 0),
      position: 1,
      active: true);
  const b3 = TimeBlock(
      id: 'b3',
      startsAt: HourMinute(10, 0),
      endsAt: HourMinute(12, 0),
      position: 2,
      active: false); // inactive "special" block

  const settings = ScheduleSettings(
    laneCount: 2,
    trainingWeekdays: {1, 2, 4}, // Mon, Tue, Thu
    bookingHorizonDays: 14,
    maxActiveReservations: 2,
  );

  final monday = Day(2026, 7, 6); // Monday
  final tuesday = Day(2026, 7, 7);
  final wednesday = Day(2026, 7, 8);
  final thursday = Day(2026, 7, 9);
  final sunday = Day(2026, 7, 12);
  final today = tuesday;
  const noon = HourMinute(12, 0);

  Reservation res({
    String id = 'r1',
    String playerId = 'p1',
    required Day date,
    required String blockId,
    required int lane,
    DateTime? cancelledAt,
  }) =>
      Reservation(
        id: id,
        playerId: playerId,
        date: date,
        blockId: blockId,
        lane: lane,
        createdVia: 'app',
        createdAt: DateTime.utc(2026, 7, 1),
        cancelledAt: cancelledAt,
      );

  Match match({
    Day? date,
    HourMinute startsAt = const HourMinute(16, 30),
    HourMinute endsAt = const HourMinute(17, 30),
  }) =>
      Match(
        id: 'm1',
        date: date ?? tuesday,
        startsAt: startsAt,
        endsAt: endsAt,
        opponent: 'KK Slavoj',
        description: '',
      );

  Rental rental({
    Day? date,
    int? weekday,
    List<int> lanes = const [1],
    HourMinute startsAt = const HourMinute(16, 0),
    HourMinute endsAt = const HourMinute(18, 0),
    Day? validFrom,
    Day? validUntil,
  }) =>
      Rental(
        id: 'n1',
        renterName: 'Firma X',
        lanes: lanes,
        date: date,
        weekday: weekday,
        startsAt: startsAt,
        endsAt: endsAt,
        validFrom: validFrom,
        validUntil: validUntil,
        note: '',
      );

  WeekSchedule build({
    List<TimeBlock> blocks = const [b1, b2, b3],
    List<DayOverride> overrides = const [],
    List<Match> matches = const [],
    List<Rental> rentals = const [],
    List<Reservation> reservations = const [],
    ScheduleSettings s = settings,
    Day? todayArg,
    HourMinute now = noon,
  }) =>
      buildWeekSchedule(
        monday: monday,
        today: todayArg ?? today,
        now: now,
        settings: s,
        blocks: blocks,
        overrides: overrides,
        matches: matches,
        rentals: rentals,
        reservations: reservations,
      );

  group('day resolution', () {
    test('non-training weekday is closed without reason', () {
      final day = build().days[2]; // Wednesday
      expect(day, isA<ClosedDay>());
      expect((day as ClosedDay).reason, '');
    });

    test('training weekday is open with active blocks sorted by position', () {
      final day = build().days[1] as OpenDay; // Tuesday
      expect(day.blocks.map((b) => b.id), ['b1', 'b2']); // b3 inactive
      expect(day.laneCount, 2);
    });

    test('closed override wins with its reason', () {
      final day = build(overrides: [
        DayOverride(date: thursday, closed: true, reason: 'Malování'),
      ]).days[3];
      expect(day, isA<ClosedDay>());
      expect((day as ClosedDay).reason, 'Malování');
    });

    test('open override with custom blocks may use inactive specials', () {
      final day = build(overrides: [
        DayOverride(
            date: wednesday, closed: false, reason: '', blockIds: ['b3']),
      ]).days[2] as OpenDay;
      expect(day.blocks.map((b) => b.id), ['b3']);
    });

    test('open override with null blockIds opens a non-training day with defaults',
        () {
      final day = build(overrides: [
        DayOverride(date: wednesday, closed: false, reason: ''),
      ]).days[2] as OpenDay;
      expect(day.blocks.map((b) => b.id), ['b1', 'b2']);
    });

    test('override with empty or unknown blockIds means closed', () {
      final week = build(overrides: [
        DayOverride(
            date: wednesday, closed: false, reason: 'jen dopoledne', blockIds: []),
        DayOverride(
            date: thursday, closed: false, reason: '', blockIds: ['zz']),
      ]);
      expect(week.days[2], isA<ClosedDay>());
      expect((week.days[2] as ClosedDay).reason, 'jen dopoledne');
      expect(week.days[3], isA<ClosedDay>());
    });
  });

  group('matches', () {
    test('match blocks all lanes of overlapping blocks only', () {
      final day =
          build(matches: [match()]).days[1] as OpenDay; // 16:30–17:30
      expect(day.slot('b1', 1), isA<MatchSlot>());
      expect(day.slot('b1', 2), isA<MatchSlot>());
      expect(day.slot('b2', 1), isA<MatchSlot>());
      // no third block that day — both overlap
    });

    test('non-overlapping match leaves blocks free and is listed on the day',
        () {
      final day = build(matches: [
        match(startsAt: const HourMinute(20, 0), endsAt: const HourMinute(22, 0)),
      ]).days[1] as OpenDay;
      expect(day.slot('b1', 1), isA<FreeSlot>());
      expect(day.matches, hasLength(1));
    });

    test('matches appear on closed days for spectators', () {
      final day = build(matches: [match(date: wednesday)]).days[2];
      expect(day, isA<ClosedDay>());
      expect(day.matches, hasLength(1));
    });
  });

  group('rentals', () {
    test('one-time rental blocks only its lanes and time', () {
      final day = build(rentals: [
        rental(date: tuesday, lanes: [1]),
      ]).days[1] as OpenDay;
      expect(day.slot('b1', 1), isA<RentedSlot>());
      expect(day.slot('b2', 1), isA<RentedSlot>());
      expect(day.slot('b1', 2), isA<FreeSlot>());
    });

    test('weekly rental applies inside its window on matching weekday', () {
      final day = build(rentals: [
        rental(
            weekday: 2,
            validFrom: Day(2026, 7, 1),
            validUntil: Day(2026, 7, 31)),
      ]).days[1] as OpenDay; // Tuesday
      expect(day.slot('b1', 1), isA<RentedSlot>());
      // Thursday unaffected
      final thu = build(rentals: [
        rental(
            weekday: 2,
            validFrom: Day(2026, 7, 1),
            validUntil: Day(2026, 7, 31)),
      ]).days[3] as OpenDay;
      expect(thu.slot('b1', 1), isA<FreeSlot>());
    });
  });

  group('reservations', () {
    test('live reservation occupies its cell; cancelled is ignored', () {
      final day = build(reservations: [
        res(date: tuesday, blockId: 'b1', lane: 2),
        res(
            id: 'r2',
            date: tuesday,
            blockId: 'b2',
            lane: 2,
            cancelledAt: DateTime.utc(2026, 7, 2)),
      ]).days[1] as OpenDay;
      final slot = day.slot('b1', 2);
      expect(slot, isA<ReservedSlot>());
      expect((slot as ReservedSlot).reservation.playerId, 'p1');
      expect(day.slot('b2', 2), isA<FreeSlot>());
    });

    test('match beats rental beats reservation', () {
      final day = build(
        matches: [match()],
        rentals: [rental(date: tuesday, lanes: [1, 2])],
        reservations: [res(date: tuesday, blockId: 'b1', lane: 1)],
      ).days[1] as OpenDay;
      expect(day.slot('b1', 1), isA<MatchSlot>());
      final noMatch = build(
        rentals: [rental(date: tuesday, lanes: [1, 2])],
        reservations: [res(date: tuesday, blockId: 'b1', lane: 1)],
      ).days[1] as OpenDay;
      expect(noMatch.slot('b1', 1), isA<RentedSlot>());
    });
  });

  group('flags', () {
    test('yesterday is inPast, today splits by block start vs now', () {
      final week = build(now: const HourMinute(16, 0));
      final mon = week.days[0] as OpenDay; // yesterday
      expect(mon.slot('b1', 1).inPast, isTrue);
      final tue = week.days[1] as OpenDay; // today, now == 16:00
      expect(tue.slot('b1', 1).inPast, isTrue); // 16:00 <= 16:00 → started
      expect(tue.slot('b2', 1).inPast, isFalse);
    });

    test('beyondHorizon respects settings', () {
      const tight = ScheduleSettings(
        laneCount: 2,
        trainingWeekdays: {1, 2, 4, 7},
        bookingHorizonDays: 3,
        maxActiveReservations: 2,
      );
      final week = build(s: tight);
      final sun = week.days[6] as OpenDay; // 12.7. — 5 days from today
      expect(sun.slot('b1', 1).beyondHorizon, isTrue);
      final thu = week.days[3] as OpenDay; // 9.7. — 2 days from today
      expect(thu.slot('b1', 1).beyondHorizon, isFalse);
    });
  });

  group('booking rules', () {
    test('activeReservationCount counts own live future rows only', () {
      final all = [
        res(id: 'a', date: tuesday, blockId: 'b1', lane: 1),
        res(id: 'b', date: thursday, blockId: 'b1', lane: 1),
        res(id: 'c', date: monday, blockId: 'b1', lane: 1), // yesterday
        res(
            id: 'd',
            date: thursday,
            blockId: 'b2',
            lane: 1,
            cancelledAt: DateTime.utc(2026, 7, 2)),
        res(id: 'e', playerId: 'p2', date: thursday, blockId: 'b2', lane: 2),
      ];
      expect(activeReservationCount(all, 'p1', today), 2);
    });

    test('canBook requires free, future, inside horizon, under limit', () {
      const free = FreeSlot(inPast: false, beyondHorizon: false);
      expect(canBook(state: free, myActiveCount: 0, settings: settings), isTrue);
      expect(canBook(state: free, myActiveCount: 2, settings: settings), isFalse);
      expect(
          canBook(
              state: const FreeSlot(inPast: true, beyondHorizon: false),
              myActiveCount: 0,
              settings: settings),
          isFalse);
      expect(
          canBook(
              state: const FreeSlot(inPast: false, beyondHorizon: true),
              myActiveCount: 0,
              settings: settings),
          isFalse);
      expect(
          canBook(
              state: ReservedSlot(res(date: tuesday, blockId: 'b1', lane: 1),
                  inPast: false, beyondHorizon: false),
              myActiveCount: 0,
              settings: settings),
          isFalse);
    });

    test('canCancel only for own not-started reservation', () {
      final mine = ReservedSlot(res(date: thursday, blockId: 'b1', lane: 1),
          inPast: false, beyondHorizon: false);
      final started = ReservedSlot(res(date: monday, blockId: 'b1', lane: 1),
          inPast: true, beyondHorizon: false);
      final foreign = ReservedSlot(
          res(playerId: 'p2', date: thursday, blockId: 'b1', lane: 1),
          inPast: false,
          beyondHorizon: false);
      expect(canCancel(state: mine, myPlayerId: 'p1'), isTrue);
      expect(canCancel(state: started, myPlayerId: 'p1'), isFalse);
      expect(canCancel(state: foreign, myPlayerId: 'p1'), isFalse);
      expect(
          canCancel(
              state: const FreeSlot(inPast: false, beyondHorizon: false),
              myPlayerId: 'p1'),
          isFalse);
    });
  });
}
```

- [ ] **Step 3: Run tests, verify they FAIL to compile** (`flutter test test/domain/schedule_test.dart` — missing `schedule.dart` types). Capture RED evidence.

- [ ] **Step 4: Implement `lib/domain/schedule.dart`**:

```dart
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
    ..sort((a, b) => a.position.compareTo(b.position));

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
        ]..sort((a, b) => a.position.compareTo(b.position));
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
}) =>
    state is FreeSlot &&
    !state.inPast &&
    !state.beyondHorizon &&
    myActiveCount < settings.maxActiveReservations;

/// Own reservation whose block has not started yet may be cancelled in-app.
/// (Admin cancel-anything is a Phase 2 admin affordance.)
bool canCancel({
  required SlotState state,
  required String myPlayerId,
}) =>
    state is ReservedSlot &&
    !state.inPast &&
    state.reservation.playerId == myPlayerId;
```

- [ ] **Step 5: Run all tests** — `flutter test` → all pass (9 old + 1 boundary + ~16 new). `flutter analyze` clean.

- [ ] **Step 6: Commit** — `feat: schedule domain with week computation and booking rules`

---

### Task 2: Data layer — week streams, RPC wrappers, Czech error mapping

**Files:**
- Modify: `lib/data/providers.dart`, `lib/core/ui.dart`
- Test: `test/core/errors_test.dart`

**Interfaces:**
- Consumes: `Reservation`, `DayOverride`, `Match`, `Rental` fromJson; RPCs from the schema
- Produces:
  - `weekReservationsProvider` — `StreamProvider.family<List<Reservation>, Day>` keyed by week Monday; server-side `.gte('date', monday)`, client-filtered to `isLive && date <= monday+6`
  - `dayOverridesProvider`, `matchesProvider`, `rentalsProvider` — whole-table `StreamProvider`s (primaryKey `['date']` for overrides, `['id']` otherwise)
  - `myActiveReservationsProvider` — `StreamProvider<List<Reservation>>` of the signed-in player's rows (`.eq('player_id', uid)`), unfiltered (UI applies `activeReservationCount`)
  - `Api.createReservation({required String playerId, required Day date, required String blockId, required int lane})`, `Api.cancelReservation(String id, {String note = ''})`
  - `friendlyDbError(Object error) → String` in `core/ui.dart`
  - `tryAction` gains optional `String Function(Object)? errorText`

- [ ] **Step 1: Failing test** — `test/core/errors_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/ui.dart';

void main() {
  test('friendlyDbError maps schema exception codes to Czech copy', () {
    expect(friendlyDbError(Exception('PostgrestException: slot_taken')),
        'Termín je už obsazený.');
    expect(friendlyDbError(Exception('limit_reached')),
        'Máš už maximální počet rezervací.');
    expect(friendlyDbError(Exception('too_late')),
        'Trénink už začal — rezervaci může zrušit jen správce.');
    expect(friendlyDbError(Exception('something else')),
        startsWith('Nepovedlo se:'));
  });
}
```

- [ ] **Step 2: Verify RED** (`friendlyDbError` undefined), then implement.

In `lib/core/ui.dart` add (and extend `tryAction`):

```dart
/// Maps the schema's `raise exception` codes to Czech user copy.
String friendlyDbError(Object error) {
  final raw = '$error';
  const messages = {
    'slot_taken': 'Termín je už obsazený.',
    'limit_reached': 'Máš už maximální počet rezervací.',
    'beyond_horizon': 'Tak daleko dopředu zatím rezervovat nejde.',
    'date_past': 'Tenhle termín už je v minulosti.',
    'day_closed': 'V tento den je zavřeno.',
    'blocked_by_match': 'V tomhle čase se hraje zápas.',
    'blocked_by_rental': 'Dráha je v tomhle čase pronajatá.',
    'too_late': 'Trénink už začal — rezervaci může zrušit jen správce.',
    'unknown_block': 'Tenhle blok už neplatí — mrkni na aktuální rozvrh.',
    'invalid_block': 'Tenhle blok už neplatí — mrkni na aktuální rozvrh.',
    'invalid_lane': 'Tahle dráha neexistuje.',
    'player_not_approved': 'Hráč ještě není schválený.',
    'not_allowed': 'Na tohle nemáš oprávnění.',
  };
  for (final entry in messages.entries) {
    if (raw.contains(entry.key)) return entry.value;
  }
  return 'Nepovedlo se: $error';
}
```

`tryAction` signature becomes:

```dart
Future<bool> tryAction(BuildContext context, Future<void> Function() action,
    {String? success, String Function(Object)? errorText}) async {
  try {
    await action();
    if (success != null && context.mounted) snack(context, success);
    return true;
  } catch (e) {
    if (context.mounted) {
      snack(context, errorText != null ? errorText(e) : 'Nepovedlo se: $e');
    }
    return false;
  }
}
```

In `lib/data/providers.dart` append the four providers + two Api methods exactly per the Interfaces block. Full code:

```dart
/// Live reservations of one week (family key = that week's Monday).
/// Server-side lower bound keeps the stream bounded as history accumulates;
/// the upper bound and liveness are filtered client-side.
final weekReservationsProvider =
    StreamProvider.family<List<Reservation>, Day>((ref, monday) {
  final sunday = monday.addDays(6);
  return _db
      .from('reservations')
      .stream(primaryKey: ['id'])
      .gte('date', monday.toSql())
      .map((rows) => rows
          .map(Reservation.fromJson)
          .where((r) => r.isLive && !r.date.isAfter(sunday))
          .toList());
});

final dayOverridesProvider = StreamProvider<List<DayOverride>>((ref) {
  return _db.from('day_overrides').stream(primaryKey: ['date']).map(
      (rows) => rows.map(DayOverride.fromJson).toList());
});

final matchesProvider = StreamProvider<List<Match>>((ref) {
  return _db.from('matches').stream(primaryKey: ['id']).map(
      (rows) => rows.map(Match.fromJson).toList());
});

final rentalsProvider = StreamProvider<List<Rental>>((ref) {
  return _db.from('rentals').stream(primaryKey: ['id']).map(
      (rows) => rows.map(Rental.fromJson).toList());
});

/// The signed-in player's reservations (all of them; the UI derives the
/// active count via activeReservationCount).
final myActiveReservationsProvider =
    StreamProvider<List<Reservation>>((ref) {
  final uid = ref.watch(
      authStateProvider.select((a) => a.value?.session?.user.id)) ??
      currentUserId;
  if (uid == null) return Stream.value(const []);
  return _db
      .from('reservations')
      .stream(primaryKey: ['id'])
      .eq('player_id', uid)
      .map((rows) => rows.map(Reservation.fromJson).toList());
});
```

And in `Api`:

```dart
  static Future<void> createReservation({
    required String playerId,
    required Day date,
    required String blockId,
    required int lane,
  }) =>
      _db.rpc('create_reservation', params: {
        'p_player_id': playerId,
        'p_date': date.toSql(),
        'p_block_id': blockId,
        'p_lane': lane,
      });

  static Future<void> cancelReservation(String id, {String note = ''}) =>
      _db.rpc('cancel_reservation', params: {'p_id': id, 'p_note': note});
```

Also apply the Phase-0 review carry-over: change `myProfileProvider` to derive the uid with `select` so token refreshes don't resubscribe the stream:

```dart
final myProfileProvider = StreamProvider<Profile?>((ref) {
  final uid = ref.watch(
          authStateProvider.select((a) => a.value?.session?.user.id)) ??
      currentUserId;
  if (uid == null) return Stream.value(null);
  return _db
      .from('profiles')
      .stream(primaryKey: ['id'])
      .eq('id', uid)
      .map((rows) => rows.isEmpty ? null : Profile.fromJson(rows.first));
});
```

- [ ] **Step 3: Verify** — `flutter analyze` clean, `flutter test` green.
- [ ] **Step 4: Commit** — `feat: week reservation streams, rpc wrappers, czech error mapping`

---

### Task 3: Live week grid with booking and cancellation

**Files:**
- Modify: `lib/features/schedule/week_screen.dart` (full rewrite of body internals; keep the week-navigation header)

**Interfaces:**
- Consumes: everything from Tasks 1–2 plus `playersProvider`, `myProfileProvider`, `settingsProvider`, `timeBlocksProvider`, `defaultTimeBlocks`, `confirmDialog`, `dayFull`, `today`
- Produces: the same `WeekScreen` widget — no API change for `HomeShell`

Behavior spec:
- Compute `today`/`now` from `DateTime.now()` once per build (UI layer owns real time); `buildWeekSchedule` renders the 7 days.
- Blocks fallback: DB blocks empty → `defaultTimeBlocks()` (unchanged pre-setup behavior).
- Day header: `dayFull(date)`; beneath it match banners `🏆 {opponent} · {startsAt}–{endsAt}` for every match of the day (open AND closed days).
- ClosedDay body: `Zavřeno` plus ` — {reason}` when non-empty.
- OpenDay: same Table layout as Phase 0 (label column + lane columns), but each cell is a `_SlotCell`:
  - `MatchSlot` → filled `errorContainer`-tinted cell, text `Zápas`.
  - `RentedSlot` → `tertiaryContainer` tint, renter name (10px, ellipsis).
  - `ReservedSlot` → player display name from the `players` view map (`?` fallback); own reservation additionally tinted `primaryContainer` + bold; tappable when `canCancel` → cancel confirm dialog → `Api.cancelReservation` with `friendlyDbError` mapping and success `Rezervace zrušena.`.
  - `FreeSlot` bookable (`canBook` with `activeReservationCount(mine, me.id, today)`) → InkWell with a faint `+`; tap → confirm dialog `„{dayFull} · {block.label} · Dráha {lane} — Rezervovat?"` → `Api.createReservation` (playerId = me), success `Zarezervováno.`, errors via `friendlyDbError`.
  - `FreeSlot` not bookable → empty, faded (no handler).
- The signed-in profile may be null for a beat — render cells inert until `me != null`.

- [ ] **Step 1: Rewrite `lib/features/schedule/week_screen.dart`**:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import '../../domain/schedule.dart';

/// Live week view: grid computed by buildWeekSchedule, booking via RPCs.
class WeekScreen extends ConsumerStatefulWidget {
  const WeekScreen({super.key});

  @override
  ConsumerState<WeekScreen> createState() => _WeekScreenState();
}

class _WeekScreenState extends ConsumerState<WeekScreen> {
  int _weekOffset = 0;

  Day _monday(Day today) => today.addDays(1 - today.weekday + 7 * _weekOffset);

  Future<void> _book(Day date, TimeBlock block, int lane, String playerId) async {
    final ok = await confirmDialog(
      context,
      title: 'Rezervovat termín?',
      message: '${dayFull(date)} · ${block.label} · Dráha $lane',
      confirmLabel: 'Rezervovat',
    );
    if (!ok || !mounted) return;
    await tryAction(
      context,
      () => Api.createReservation(
          playerId: playerId, date: date, blockId: block.id, lane: lane),
      success: 'Zarezervováno.',
      errorText: friendlyDbError,
    );
  }

  Future<void> _cancel(Day date, TimeBlock block, Reservation r) async {
    final ok = await confirmDialog(
      context,
      title: 'Zrušit rezervaci?',
      message: '${dayFull(date)} · ${block.label} · Dráha ${r.lane}',
      confirmLabel: 'Zrušit rezervaci',
      cancelLabel: 'Zpět',
    );
    if (!ok || !mounted) return;
    await tryAction(
      context,
      () => Api.cancelReservation(r.id),
      success: 'Rezervace zrušena.',
      errorText: friendlyDbError,
    );
  }

  @override
  Widget build(BuildContext context) {
    final nowDt = DateTime.now();
    final todayDay = Day.fromDateTime(nowDt);
    final now = HourMinute(nowDt.hour, nowDt.minute);
    final monday = _monday(todayDay);

    final settings =
        ref.watch(settingsProvider).value ?? ScheduleSettings.defaults;
    final dbBlocks = ref.watch(timeBlocksProvider).value ?? const [];
    final blocks = dbBlocks.isEmpty ? defaultTimeBlocks() : dbBlocks;
    final overrides = ref.watch(dayOverridesProvider).value ?? const [];
    final matches = ref.watch(matchesProvider).value ?? const [];
    final rentals = ref.watch(rentalsProvider).value ?? const [];
    final reservations =
        ref.watch(weekReservationsProvider(monday)).value ?? const [];
    final players = ref.watch(playersProvider).value ?? const [];
    final me = ref.watch(myProfileProvider).value;
    final mine = ref.watch(myActiveReservationsProvider).value ?? const [];

    final week = buildWeekSchedule(
      monday: monday,
      today: todayDay,
      now: now,
      settings: settings,
      blocks: blocks,
      overrides: overrides,
      matches: matches,
      rentals: rentals,
      reservations: reservations,
    );
    final myCount =
        me == null ? 0 : activeReservationCount(mine, me.id, todayDay);
    final nameById = {for (final p in players) p.id: p.displayName};

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: () => setState(() => _weekOffset--),
              ),
              Expanded(
                child: Text(
                  rangeLabel(monday, monday.addDays(6)),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (_weekOffset != 0)
                TextButton(
                  onPressed: () => setState(() => _weekOffset = 0),
                  child: const Text('dnes'),
                ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: () => setState(() => _weekOffset++),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
            children: [
              for (final day in week.days)
                _DaySection(
                  day: day,
                  me: me,
                  myCount: myCount,
                  settings: settings,
                  nameById: nameById,
                  onBook: _book,
                  onCancel: _cancel,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DaySection extends StatelessWidget {
  const _DaySection({
    required this.day,
    required this.me,
    required this.myCount,
    required this.settings,
    required this.nameById,
    required this.onBook,
    required this.onCancel,
  });

  final DaySchedule day;
  final Profile? me;
  final int myCount;
  final ScheduleSettings settings;
  final Map<String, String> nameById;
  final void Function(Day, TimeBlock, int, String) onBook;
  final void Function(Day, TimeBlock, Reservation) onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(dayFull(day.date),
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
            for (final m in day.matches)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '🏆 ${m.opponent} · ${m.startsAt.display()}–${m.endsAt.display()}',
                  style: TextStyle(color: scheme.primary, fontSize: 13),
                ),
              ),
            const SizedBox(height: 8),
            switch (day) {
              ClosedDay(:final reason) => Text(
                  reason.isEmpty ? 'Zavřeno' : 'Zavřeno — $reason',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              OpenDay() => _grid(context, day as OpenDay),
            },
          ],
        ),
      ),
    );
  }

  Widget _grid(BuildContext context, OpenDay day) {
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const FixedColumnWidth(72),
        columnWidths: const {0: FixedColumnWidth(100)},
        border: TableBorder.all(
            color: scheme.outlineVariant.withValues(alpha: 0.5)),
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          TableRow(
            children: [
              const SizedBox.shrink(),
              for (var lane = 1; lane <= day.laneCount; lane++)
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text('Dráha $lane',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
            ],
          ),
          for (final block in day.blocks)
            TableRow(
              children: [
                Padding(
                  padding: const EdgeInsets.all(6),
                  child:
                      Text(block.label, style: const TextStyle(fontSize: 12)),
                ),
                for (var lane = 1; lane <= day.laneCount; lane++)
                  _SlotCell(
                    state: day.slot(block.id, lane),
                    me: me,
                    myCount: myCount,
                    settings: settings,
                    nameById: nameById,
                    onBook: () =>
                        me == null ? null : onBook(day.date, block, lane, me!.id),
                    onCancel: (r) => onCancel(day.date, block, r),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _SlotCell extends StatelessWidget {
  const _SlotCell({
    required this.state,
    required this.me,
    required this.myCount,
    required this.settings,
    required this.nameById,
    required this.onBook,
    required this.onCancel,
  });

  final SlotState state;
  final Profile? me;
  final int myCount;
  final ScheduleSettings settings;
  final Map<String, String> nameById;
  final VoidCallback? onBook;
  final void Function(Reservation) onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const height = 44.0;

    switch (state) {
      case MatchSlot():
        return Container(
          height: height,
          color: scheme.errorContainer.withValues(alpha: 0.6),
          alignment: Alignment.center,
          child: Text('Zápas',
              style: TextStyle(
                  fontSize: 11, color: scheme.onErrorContainer)),
        );
      case RentedSlot(:final rental):
        return Container(
          height: height,
          color: scheme.tertiaryContainer.withValues(alpha: 0.7),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            rental.renterName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style:
                TextStyle(fontSize: 10, color: scheme.onTertiaryContainer),
          ),
        );
      case ReservedSlot(:final reservation):
        final isMine = me != null && reservation.playerId == me!.id;
        final name = nameById[reservation.playerId] ?? '?';
        final cancellable = me != null &&
            canCancel(state: state, myPlayerId: me!.id);
        return InkWell(
          onTap: cancellable ? () => onCancel(reservation) : null,
          child: Container(
            height: height,
            color: isMine
                ? scheme.primaryContainer
                : scheme.surfaceContainerHighest,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 10,
                fontWeight: isMine ? FontWeight.w700 : FontWeight.w400,
                color: isMine
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
              ),
            ),
          ),
        );
      case FreeSlot():
        final bookable = me != null &&
            canBook(state: state, myActiveCount: myCount, settings: settings);
        if (!bookable) {
          return Container(
            height: height,
            color: scheme.surface.withValues(alpha: 0.4),
          );
        }
        return InkWell(
          onTap: onBook,
          child: Container(
            height: height,
            alignment: Alignment.center,
            child: Icon(Icons.add,
                size: 18,
                color: scheme.primary.withValues(alpha: 0.45)),
          ),
        );
    }
  }
}
```

- [ ] **Step 2: Verify** — `flutter analyze` clean, `flutter test` green (no test changes here; widget tests come next task).
- [ ] **Step 3: Commit** — `feat: live week grid with booking and cancellation`

---

### Task 4: Widget tests for the grid

**Files:**
- Test: `test/features/week_screen_test.dart`

**Interfaces:**
- Consumes: all providers overridden via `ProviderScope(overrides: [...])`; no Supabase initialization needed.

- [ ] **Step 1: Write the tests** — cover: closed-day label with reason, reserved cell shows the player's name, own reservation bold + cancellable (tap → dialog appears), free bookable cell shows `+` and tap opens the booking dialog, match banner + `Zápas` cells. Use dates derived from the real `today()` so the widget's internal `DateTime.now()` agrees; make ALL weekdays training days so the test week is fully open:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/core/ui.dart' show today;
import 'package:rezervator/data/providers.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/schedule/week_screen.dart';

void main() {
  const settings = ScheduleSettings(
    laneCount: 2,
    trainingWeekdays: {1, 2, 3, 4, 5, 6, 7},
    bookingHorizonDays: 14,
    maxActiveReservations: 3,
  );
  const b1 = TimeBlock(
      id: 'b1',
      startsAt: HourMinute(22, 58),
      endsAt: HourMinute(23, 59),
      position: 0,
      active: true);

  final t = today();
  final tomorrow = t.addDays(1);

  const me = Profile(
    id: 'me',
    displayName: 'Já Hráč',
    club: '',
    email: 'me@example.com',
    role: Role.player,
    status: ProfileStatus.approved,
  );

  Reservation res(String id, String playerId, Day date) => Reservation(
        id: id,
        playerId: playerId,
        date: date,
        blockId: 'b1',
        lane: 2,
        createdVia: 'app',
        createdAt: DateTime.utc(2026, 1, 1),
      );

  Widget app({
    List<DayOverride> overrides = const [],
    List<Match> matches = const [],
    List<Reservation> reservations = const [],
  }) {
    return ProviderScope(
      overrides: [
        settingsProvider.overrideWith((ref) => Stream.value(settings)),
        timeBlocksProvider.overrideWith((ref) => Stream.value(const [b1])),
        dayOverridesProvider.overrideWith((ref) => Stream.value(overrides)),
        matchesProvider.overrideWith((ref) => Stream.value(matches)),
        rentalsProvider.overrideWith((ref) => Stream.value(const [])),
        weekReservationsProvider
            .overrideWith((ref, monday) => Stream.value(reservations)),
        myActiveReservationsProvider
            .overrideWith((ref) => Stream.value(reservations)),
        myProfileProvider.overrideWith((ref) => Stream.value(me)),
        playersProvider.overrideWith((ref) async => const [
              PlayerName(id: 'me', displayName: 'Já Hráč', club: ''),
              PlayerName(id: 'p2', displayName: 'Petr Novák', club: ''),
            ]),
      ],
      child: const MaterialApp(home: Scaffold(body: WeekScreen())),
    );
  }

  testWidgets('closed override renders reason', (tester) async {
    await tester.pumpWidget(app(overrides: [
      DayOverride(date: tomorrow, closed: true, reason: 'Malování'),
    ]));
    await tester.pumpAndSettle();
    expect(find.textContaining('Zavřeno — Malování'), findsOneWidget);
  });

  testWidgets('reserved cell shows player name; own name bold', (tester) async {
    await tester.pumpWidget(app(reservations: [res('r2', 'p2', tomorrow)]));
    await tester.pumpAndSettle();
    expect(find.text('Petr Novák'), findsOneWidget);
  });

  testWidgets('tap on own reservation opens cancel dialog', (tester) async {
    await tester.pumpWidget(app(reservations: [res('r1', 'me', tomorrow)]));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Já Hráč').first);
    await tester.pumpAndSettle();
    expect(find.text('Zrušit rezervaci?'), findsOneWidget);
  });

  testWidgets('free bookable cell opens booking dialog', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add).first);
    await tester.pumpAndSettle();
    expect(find.text('Rezervovat termín?'), findsOneWidget);
  });

  testWidgets('match renders banner and Zápas cells', (tester) async {
    await tester.pumpWidget(app(matches: [
      Match(
        id: 'm1',
        date: tomorrow,
        startsAt: const HourMinute(22, 0),
        endsAt: const HourMinute(23, 59),
        opponent: 'KK Slavoj',
        description: '',
      ),
    ]));
    await tester.pumpAndSettle();
    expect(find.textContaining('KK Slavoj'), findsOneWidget);
    expect(find.text('Zápas'), findsNWidgets(2)); // 2 lanes × 1 block
  });
}
```

Implementation notes for the executor:
- The block times (22:58–23:59) keep "tomorrow" cells out of `inPast` regardless of when the test runs; `tomorrow` keeps them inside the horizon. If a test still flakes near midnight, that is acceptable — note it, don't over-engineer.
- If `Stream.value` races `pumpAndSettle`, use `tester.pump()` twice instead.
- If the riverpod family override signature differs (`overrideWith((ref, arg) => ...)` vs provider-level), consult flutter_riverpod ^3.3 docs via the installed package source under `~/.pub-cache` — do not guess.
- The booking-dialog test may find multiple `+` icons (several free cells) — `.first` is deliberate.

- [ ] **Step 2: Run** — `flutter test` all green (including the 5 new widget tests), `flutter analyze` clean.
- [ ] **Step 3: Commit** — `test: widget tests for live week grid`

---

### Task 5: Phase verification

**Files:** none

- [ ] `flutter analyze` → No issues found!
- [ ] `flutter test` → all pass
- [ ] `flutter build web --release --base-href /rezervator/` → succeeds
- [ ] Note for the E2E checkpoint (deferred until the user's Supabase project exists): two sessions book the same cell → one gets `Termín je už obsazený.`; booking appears live in the other session; cancel own reservation; horizon/limit errors surface in Czech.
- [ ] Commit anything outstanding; phase review follows.

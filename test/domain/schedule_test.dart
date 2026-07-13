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

  PrioritySlot match({
    Day? date,
    HourMinute startsAt = const HourMinute(16, 30),
    HourMinute endsAt = const HourMinute(17, 30),
    int prepMinutes = 0,
  }) =>
      PrioritySlot(
        type: PrioritySlot.fallbackMatchType,
        id: 'm1',
        date: date ?? tuesday,
        startsAt: startsAt,
        endsAt: endsAt,
        homeTeam: '',
        awayTeam: 'KK Slavoj',
        prepMinutes: prepMinutes,
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
    List<PrioritySlot> matches = const [],
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
        priority: matches,
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

    test(
        'blocks are sorted by start time, not insertion/position order',
        () {
      // b4 starts earlier than b1 but has a higher position — time must win.
      const b4 = TimeBlock(
          id: 'b4',
          startsAt: HourMinute(9, 0),
          endsAt: HourMinute(10, 0),
          position: 5,
          active: true);
      final day =
          build(blocks: const [b1, b2, b4]).days[1] as OpenDay; // Tuesday
      expect(day.blocks.map((b) => b.id), ['b4', 'b1', 'b2']);
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

  group('whole-alley priority cancels blocks', () {
    test('a match cancels every block its window touches — that day only', () {
      final week = build(matches: [match()]); // 16:30–17:30 overlaps b1+b2
      final tue = week.days[1] as OpenDay;
      expect(tue.blocks, isEmpty); // both training blocks cancelled
      expect(tue.priority, hasLength(1));
      // Other days keep their blocks untouched.
      final mon = week.days[0] as OpenDay;
      expect(mon.blocks.map((b) => b.id), ['b1', 'b2']);
    });

    test('a partial overlap cancels only the touched block', () {
      // Match 17:30–18:30 touches b2 (17–18) but not b1 (16–17).
      final day = build(matches: [
        match(
            startsAt: const HourMinute(17, 30),
            endsAt: const HourMinute(18, 30)),
      ]).days[1] as OpenDay;
      expect(day.blocks.map((b) => b.id), ['b1']);
      expect(day.slot('b1', 1), isA<FreeSlot>());
    });

    test('non-overlapping match leaves blocks alone and is listed on the day',
        () {
      final day = build(matches: [
        match(startsAt: const HourMinute(20, 0), endsAt: const HourMinute(22, 0)),
      ]).days[1] as OpenDay;
      expect(day.blocks.map((b) => b.id), ['b1', 'b2']);
      expect(day.slot('b1', 1), isA<FreeSlot>());
      expect(day.priority, hasLength(1));
    });

    test('matches appear on closed days for spectators', () {
      final day = build(matches: [match(date: wednesday)]).days[2];
      expect(day, isA<ClosedDay>());
      expect(day.priority, hasLength(1));
    });

    test('the prep window cancels too; a block ending exactly at '
        'blockingStart survives', () {
      // Match 17:00–18:00 with 60 min prep → blocking window [16:00, 18:00):
      // b1 (16–17) and b2 (17–18) are both cancelled; b0 (15–16) ends exactly
      // at blockingStart (half-open, no overlap) and survives.
      final day = build(
        blocks: const [
          TimeBlock(
              id: 'b0',
              startsAt: HourMinute(15, 0),
              endsAt: HourMinute(16, 0),
              position: -1,
              active: true),
          b1,
          b2,
          b3,
        ],
        matches: [
          match(startsAt: const HourMinute(17, 0), endsAt: const HourMinute(18, 0),
              prepMinutes: 60),
        ],
      ).days[1] as OpenDay;
      expect(day.blocks.map((b) => b.id), ['b0']);
      expect(day.slot('b0', 1), isA<FreeSlot>());
    });

    test('a day whose every block is cancelled stays an OpenDay', () {
      // The match is not a closure — the day hosts it, it is not "zavřeno".
      final day = build(matches: [
        match(startsAt: const HourMinute(15, 0), endsAt: const HourMinute(19, 0)),
      ]).days[1];
      expect(day, isA<OpenDay>());
      expect((day as OpenDay).blocks, isEmpty);
    });

    test('midnight clamp: match 00:15 with 30min prep cancels from 00:00', () {
      const bMidnight = TimeBlock(
          id: 'bm',
          startsAt: HourMinute(0, 0),
          endsAt: HourMinute(0, 15),
          position: -1,
          active: true);
      final day = build(
        blocks: const [bMidnight, b1, b2, b3],
        matches: [
          match(startsAt: const HourMinute(0, 15), endsAt: const HourMinute(1, 0),
              prepMinutes: 30),
        ],
      ).days[1] as OpenDay;
      // Without clamping, blockingStart would be -00:15 (wrap); clamped to
      // 00:00 it still cancels the 00:00-00:15 block.
      expect(day.blocks.map((b) => b.id), ['b1', 'b2']);
    });

    test('two whole-alley slots on one day: EVERY slot cancels (not just '
        'the first)', () {
      // m1 touches only b1, m2 only b2 — both must go.
      final day = build(matches: [
        match(
            startsAt: const HourMinute(16, 30),
            endsAt: const HourMinute(17, 0)),
        PrioritySlot(
          type: PrioritySlot.fallbackMatchType,
          id: 'm2',
          date: tuesday,
          startsAt: const HourMinute(17, 30),
          endsAt: const HourMinute(18, 0),
          homeTeam: '',
          awayTeam: 'KK Vracov',
          prepMinutes: 0,
          description: '',
        ),
      ]).days[1] as OpenDay;
      expect(day.blocks, isEmpty);
    });

    test('cancellation applies to override-selected blocks too, and such a '
        'day stays open', () {
      // Wednesday (non-training) opened via override with the inactive
      // special b3 (10:00–12:00); a match overlapping it cancels it.
      final day = build(
        overrides: [
          DayOverride(
              date: wednesday,
              closed: false,
              reason: '',
              blockIds: const ['b3']),
        ],
        matches: [
          match(
              date: wednesday,
              startsAt: const HourMinute(10, 0),
              endsAt: const HourMinute(11, 0)),
        ],
      ).days[2];
      expect(day, isA<OpenDay>());
      expect((day as OpenDay).blocks, isEmpty);
      expect(day.priority, hasLength(1));
    });

    test('an UNRESOLVED type (types stream not joined yet) never cancels', () {
      final day = build(matches: [
        PrioritySlot(
          type: PrioritySlot.unresolvedType,
          id: 'm1',
          date: tuesday,
          startsAt: const HourMinute(16, 30),
          endsAt: const HourMinute(17, 30),
          homeTeam: '',
          awayTeam: 'KK Slavoj',
          prepMinutes: 0,
          description: '',
        ),
      ]).days[1] as OpenDay;
      // Blocks survive; the slot still blocks lanes via slot states.
      expect(day.blocks.map((b) => b.id), ['b1', 'b2']);
      expect(day.slot('b1', 1), isA<PrioritySlotState>());
    });

    test('a cancelled-block match renders off-block at its real window', () {
      final day = build(matches: [match()]).days[1] as OpenDay;
      final events = offBlockEvents(
          priority: day.priority, rentals: day.rentals, blocks: day.blocks);
      expect(events.single, isA<OffBlockPriority>());
      expect(events.single.start, const HourMinute(16, 30));
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

    test('priority beats rental beats reservation (lane-scoped — a '
        'whole-alley match cancels the block outright instead)', () {
      const laneType = PrioritySlotType(
        id: 't-lane',
        name: 'Údržba',
        colorIndex: 3,
        lanes: [1],
      );
      final day = build(
        matches: [
          PrioritySlot(
            id: 's1',
            date: tuesday,
            startsAt: const HourMinute(16, 30),
            endsAt: const HourMinute(17, 30),
            type: laneType,
          ),
        ],
        rentals: [rental(date: tuesday, lanes: [1, 2])],
        reservations: [res(date: tuesday, blockId: 'b1', lane: 1)],
      ).days[1] as OpenDay;
      expect(day.slot('b1', 1), isA<PrioritySlotState>());
      final noPriority = build(
        rentals: [rental(date: tuesday, lanes: [1, 2])],
        reservations: [res(date: tuesday, blockId: 'b1', lane: 1)],
      ).days[1] as OpenDay;
      expect(noPriority.slot('b1', 1), isA<RentedSlot>());
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

    test('admin may book past/beyond-horizon free slots and ignores limit', () {
      const past = FreeSlot(inPast: true, beyondHorizon: false);
      const far = FreeSlot(inPast: false, beyondHorizon: true);
      expect(canBook(state: past, myActiveCount: 99, settings: settings, isAdmin: true), isTrue);
      expect(canBook(state: far, myActiveCount: 99, settings: settings, isAdmin: true), isTrue);
      expect(
          canBook(
              state: ReservedSlot(res(date: thursday, blockId: 'b1', lane: 1),
                  inPast: false, beyondHorizon: false),
              myActiveCount: 0,
              settings: settings,
              isAdmin: true),
          isFalse);
    });
  });

  group('lane-scoped priority types', () {
    const laneOneType = PrioritySlotType(
      id: 't-lane1',
      name: 'Údržba',
      colorIndex: 3,
      lanes: [1],
    );
    PrioritySlot laneSlot({int prepMinutes = 0}) => PrioritySlot(
          id: 's1',
          date: tuesday,
          startsAt: const HourMinute(16, 30),
          endsAt: const HourMinute(17, 30),
          type: laneOneType,
          prepMinutes: prepMinutes,
        );

    test('blocks only its lanes; the others stay free/bookable', () {
      final day = build(matches: [laneSlot()]).days[1] as OpenDay;
      expect(day.slot('b1', 1), isA<PrioritySlotState>());
      expect(day.slot('b1', 2), isA<FreeSlot>());
      expect(day.slot('b2', 1), isA<PrioritySlotState>());
      expect(day.slot('b2', 2), isA<FreeSlot>());
    });

    test('never cancels the block — it resolves per lane instead', () {
      final day = build(matches: [laneSlot()]).days[1] as OpenDay;
      expect(day.blocks.map((b) => b.id), ['b1', 'b2']);
      final (laneHit, isPrep) = priorityStateFor(b1, 1, [laneSlot()]);
      expect(laneHit, isNotNull);
      expect(isPrep, isFalse);
    });

    test('beats a rental on the same lane; rental rules other lanes', () {
      final day = build(
        matches: [laneSlot()],
        rentals: [rental(date: tuesday, lanes: const [1, 2])],
      ).days[1] as OpenDay;
      expect(day.slot('b1', 1), isA<PrioritySlotState>());
      expect(day.slot('b1', 2), isA<RentedSlot>());
    });

    test('prep window applies per lane too', () {
      final day = build(matches: [
        PrioritySlot(
          id: 's2',
          date: tuesday,
          startsAt: const HourMinute(17, 0),
          endsAt: const HourMinute(18, 0),
          type: laneOneType,
          prepMinutes: 60,
        ),
      ]).days[1] as OpenDay;
      final b1Lane1 = day.slot('b1', 1);
      expect(b1Lane1, isA<PrioritySlotState>());
      expect((b1Lane1 as PrioritySlotState).isPrep, isTrue);
      expect(day.slot('b1', 2), isA<FreeSlot>());
    });
  });

  group('day rentals + off-block events', () {
    test('days expose their rentals — open and closed alike', () {
      final weekly = rental(weekday: 3); // Wednesday is a non-training day
      final oneTime = rental(date: tuesday, lanes: const [2]);
      final week = build(rentals: [weekly, oneTime]);

      final wed = week.days[2];
      expect(wed, isA<ClosedDay>());
      expect(wed.rentals, [weekly]);

      final tue = week.days[1];
      expect(tue, isA<OpenDay>());
      expect(tue.rentals, [oneTime]);
    });

    test('offBlockEvents keeps only events overlapping no block of the '
        'RENDERED set — inactive override-specials in the list count too', () {
      final insideMatch = match(); // 16:30–17:30 → overlaps b1/b2
      final morningMatch = match(
          startsAt: const HourMinute(10, 0), endsAt: const HourMinute(11, 0));
      final lateRental = rental(
          date: tuesday,
          startsAt: const HourMinute(20, 0),
          endsAt: const HourMinute(22, 0));
      final spillRental = rental(
          date: tuesday,
          startsAt: const HourMinute(17, 30),
          endsAt: const HourMinute(19, 0)); // overlaps b2 → not off-block

      final events = offBlockEvents(
        priority: [insideMatch, morningMatch],
        rentals: [lateRental, spillRental],
        blocks: const [b1, b2],
      );

      expect(events, hasLength(2));
      expect(events[0], isA<OffBlockPriority>());
      expect(events[0].start, const HourMinute(10, 0));
      expect(events[1], isA<OffBlockRental>());
      expect(events[1].start, const HourMinute(20, 0));

      // An override day may RENDER an inactive special block (b3,
      // 10:00–12:00): an event inside it must resolve via slot states, not
      // double-render as a banner too.
      final withSpecial = offBlockEvents(
        priority: [morningMatch],
        rentals: const [],
        blocks: const [b1, b2, b3],
      );
      expect(withSpecial, isEmpty);
    });

    test('a rental overlapping a cancelled block resurfaces as an off-block '
        'band instead of vanishing', () {
      // Match 16:30–17:30 cancels b1+b2; the 17:30–18:00 rental previously
      // rendered as RentedSlot rows inside b2 — its only remaining surface
      // is the off-block path.
      final day = build(
        matches: [match()],
        rentals: [
          rental(
              date: tuesday,
              startsAt: const HourMinute(17, 30),
              endsAt: const HourMinute(18, 0)),
        ],
      ).days[1] as OpenDay;
      final events = offBlockEvents(
          priority: day.priority, rentals: day.rentals, blocks: day.blocks);
      expect(events.whereType<OffBlockRental>().single.start,
          const HourMinute(17, 30));
    });

    test('offBlockEvents uses the real match window, not prep-extended', () {
      // Match 18:00–19:00 with 60 min prep: prep window reaches back into
      // b2 (17:00–18:00), but the REAL window starts at 18:00 — off-block.
      final prepMatch = match(
          startsAt: const HourMinute(18, 0),
          endsAt: const HourMinute(19, 0),
          prepMinutes: 60);
      final events = offBlockEvents(
          priority: [prepMatch], rentals: const [], blocks: const [b1, b2]);
      expect(events.single, isA<OffBlockPriority>());
    });
  });
}

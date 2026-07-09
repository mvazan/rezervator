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

  Match match({
    Day? date,
    HourMinute startsAt = const HourMinute(16, 30),
    HourMinute endsAt = const HourMinute(17, 30),
    int prepMinutes = 0,
  }) =>
      Match(
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

    test('prep window blocks a block ending exactly at blockingStart is free',
        () {
      // Match starts 17:00, prep 60 -> blockingStart 16:00. b1 ends 17:00,
      // which is inside [16:00, endsAt) of the match's real window? No —
      // real window is [17:00, ends), b1 (16:00-17:00) only touches prep.
      final day = build(matches: [
        match(startsAt: const HourMinute(17, 0), endsAt: const HourMinute(18, 0),
            prepMinutes: 60),
      ]).days[1] as OpenDay;
      final b1Slot = day.slot('b1', 1);
      expect(b1Slot, isA<MatchSlot>());
      expect((b1Slot as MatchSlot).isPrep, isTrue);

      // A block ending exactly at blockingStart (16:00) does not overlap.
      final day2 = build(
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
      expect(day2.slot('b0', 1), isA<FreeSlot>());
    });

    test('isPrep is true only for cells that overlap prep but not the real match window',
        () {
      // Match starts 17:00, prep 60 -> blockingStart 16:00. b1 (16:00-17:00)
      // is prep-only; b2 (17:00-18:00) overlaps the real match window.
      final day = build(matches: [
        match(startsAt: const HourMinute(17, 0), endsAt: const HourMinute(18, 0),
            prepMinutes: 60),
      ]).days[1] as OpenDay;
      final prepSlot = day.slot('b1', 1) as MatchSlot;
      final realSlot = day.slot('b2', 1) as MatchSlot;
      expect(prepSlot.isPrep, isTrue);
      expect(realSlot.isPrep, isFalse);
    });

    test('isPrep is false when the block overlaps both prep and the real window',
        () {
      // Match starts 16:30 (mid-b1), prep 45 -> blockingStart 15:45. b1
      // (16:00-17:00) overlaps the real window [16:30, ends) too.
      final day = build(matches: [
        match(startsAt: const HourMinute(16, 30), endsAt: const HourMinute(17, 30),
            prepMinutes: 45),
      ]).days[1] as OpenDay;
      final slot = day.slot('b1', 1) as MatchSlot;
      expect(slot.isPrep, isFalse);
    });

    test('midnight clamp: match 00:15 with 30min prep blocks from 00:00', () {
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
      // 00:00 it still blocks the 00:00-00:15 block, and as prep-only.
      final slot = day.slot('bm', 1) as MatchSlot;
      expect(slot.isPrep, isTrue);
    });
  });

  group('matchStateForBlock', () {
    test('prep-only overlap returns the match with isPrep true', () {
      // Match starts 17:00, prep 60 -> blockingStart 16:00. b1 (16:00-17:00)
      // overlaps only the prep window, not the real [17:00, 18:00) window.
      final m = match(
          startsAt: const HourMinute(17, 0),
          endsAt: const HourMinute(18, 0),
          prepMinutes: 60);
      final (found, isPrep) = matchStateForBlock(b1, [m]);
      expect(found, same(m));
      expect(isPrep, isTrue);
    });

    test('real-window overlap returns the match with isPrep false', () {
      final m = match(
          startsAt: const HourMinute(16, 30), endsAt: const HourMinute(17, 30));
      final (found, isPrep) = matchStateForBlock(b1, [m]);
      expect(found, same(m));
      expect(isPrep, isFalse);
    });

    test('no overlap returns null', () {
      final m = match(
          startsAt: const HourMinute(20, 0), endsAt: const HourMinute(22, 0));
      final (found, isPrep) = matchStateForBlock(b1, [m]);
      expect(found, isNull);
      expect(isPrep, isFalse);
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
}

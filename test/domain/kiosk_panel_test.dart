import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/kiosk_panel.dart';
import 'package:rezervator/domain/models.dart';

void main() {
  const matchType = PrioritySlotType(
    id: 'tm',
    name: 'Zápas',
    isMatch: true,
    builtin: true,
  );

  /// A federation match of three hours from [start] (14:00 unless said).
  PrioritySlot match(
    String id,
    Day date, {
    String? key,
    String? parent,
    String? video,
    bool imported = true,
    HourMinute start = const HourMinute(14, 0),
  }) => PrioritySlot(
    id: id,
    date: date,
    startsAt: start,
    endsAt: HourMinute(start.hour + 3, start.minute),
    type: matchType,
    homeTeam: 'A',
    awayTeam: 'B',
    parentId: parent,
    importKey: imported ? key ?? 'cka:$id' : null,
    videoUrl: video,
  );

  MatchResult result(
    String id,
    MatchStatus status, {
    DateTime? fetched,
    DateTime? decided,
  }) => MatchResult(
    matchId: id,
    status: status,
    fetchedAt: fetched ?? DateTime(2026, 10, 1),
    decidedAt: decided,
  );

  Message notice(
    String id, {
    DateTime? expiresAt,
    MessageKind? kind,
    bool showOnKiosk = true,
  }) =>
      Message(
        id: id,
        kind: kind ?? MessageKind.notice,
        audience: MessageAudience.all,
        authorId: 'a',
        authorRole: MessageAuthorRole.admin,
        onDate: null,
        blockId: null,
        title: 't',
        body: 'b',
        expiresAt: expiresAt,
        notify: true,
        showOnKiosk: showOnKiosk,
        createdAt: DateTime(2026, 9, 1),
        updatedAt: DateTime(2026, 9, 1),
      );

  // Thursday 8 October 2026: its week is Mon 5 – Sun 11 October.
  final today = Day(2026, 10, 8);
  List<String> ids(KioskMatchWindow w) => [for (final s in w.matches) s.id];

  test('kioskNotices keeps active ones, drops expired, hidden and messages',
      () {
    final now = DateTime(2026, 10, 8, 12);
    final got = kioskNotices([
      notice('a-open'),
      notice('b-later', expiresAt: DateTime(2026, 10, 9)),
      notice('gone', expiresAt: DateTime(2026, 10, 7)),
      notice('msg', kind: MessageKind.message),
      notice('hidden', showOnKiosk: false),
    ], now);
    expect([for (final m in got) m.id], ['a-open', 'b-later']);
  });

  test('the competition year runs from 1 July to 30 June', () {
    expect(kioskSeason(Day(2026, 10, 8)), (
      start: Day(2026, 7, 1),
      end: Day(2027, 6, 30),
    ));
    expect(kioskSeason(Day(2027, 3, 1)), (
      start: Day(2026, 7, 1),
      end: Day(2027, 6, 30),
    ));
    // The turn of the year: 30 June is still the old one, 1 July the new.
    expect(kioskSeason(Day(2027, 6, 30)).start, Day(2026, 7, 1));
    expect(kioskSeason(Day(2027, 7, 1)).start, Day(2027, 7, 1));
  });

  test('the window is the current week plus the weeks asked for', () {
    final slots = [
      match('far-back', Day(2026, 9, 14)), // 3 weeks back
      match('back2', Day(2026, 9, 24)), // 2 weeks back (week of 21.9.)
      match('back1', Day(2026, 10, 1)),
      match('mon', Day(2026, 10, 5)), // this week, already past
      match('sun', Day(2026, 10, 11)), // this week, still ahead
      match('ahead1', Day(2026, 10, 15)),
      match('ahead2', Day(2026, 10, 22)),
    ];
    final w = kioskMatchWindow(
      slots: slots,
      today: today,
      weeksBack: 2,
      weeksAhead: 1,
      showUpcoming: true,
    );
    expect(ids(w), ['back2', 'back1', 'mon', 'sun', 'ahead1']);
    expect(w.moreBefore, isTrue);
    expect(w.moreAfter, isTrue);

    final onlyThisWeek = kioskMatchWindow(
      slots: slots,
      today: today,
      weeksBack: 0,
      weeksAhead: 0,
      showUpcoming: true,
    );
    expect(ids(onlyThisWeek), ['mon', 'sun']);
  });

  test('„Zobrazit další“ widens the window by whole weeks', () {
    final slots = [
      match('far-back', Day(2026, 9, 14)),
      match('ahead2', Day(2026, 10, 22)),
    ];
    final w = kioskMatchWindow(
      slots: slots,
      today: today,
      weeksBack: 0,
      weeksAhead: 0,
      showUpcoming: true,
      extraBack: 4,
      extraAhead: 2,
    );
    expect(ids(w), ['far-back', 'ahead2']);
    expect(w.moreBefore, isFalse);
    expect(w.moreAfter, isFalse);
  });

  test('without upcoming matches nothing after today is listed', () {
    final w = kioskMatchWindow(
      slots: [match('mon', Day(2026, 10, 5)), match('sun', Day(2026, 10, 11))],
      today: today,
      weeksBack: 1,
      weeksAhead: 2,
      showUpcoming: false,
    );
    expect(ids(w), ['mon']);
    expect(w.moreAfter, isFalse);
  });

  test('the season is a wall: no match of another season, ever', () {
    final w = kioskMatchWindow(
      slots: [
        match('last-season', Day(2026, 6, 20)),
        match('now', Day(2026, 10, 8)),
        match('next-season', Day(2027, 7, 10)),
      ],
      today: today,
      weeksBack: 1,
      weeksAhead: 1,
      showUpcoming: true,
      extraBack: 100,
      extraAhead: 100,
    );
    expect(ids(w), ['now']);
    expect(w.moreBefore, isFalse);
    expect(w.moreAfter, isFalse);
  });

  test('manual matches and úklid children are not listed', () {
    final w = kioskMatchWindow(
      slots: [
        match('hand', Day(2026, 10, 9), key: 'xlsx:1'),
        match('child', Day(2026, 10, 9), parent: 'x'),
        match('ok', Day(2026, 10, 9)),
      ],
      today: today,
      weeksBack: 0,
      weeksAhead: 0,
      showUpcoming: true,
    );
    expect(ids(w), ['ok']);
  });

  test('the first coming match opens just below the list; played and playing above',
      () {
    final slots = [
      match('old', Day(2026, 10, 1)),
      match('playing', Day(2026, 10, 8)),
      match('next', Day(2026, 10, 9)),
      match('later', Day(2026, 10, 15)),
    ];
    final results = {
      'old': result('old', MatchStatus.finished),
      'playing': result('playing', MatchStatus.inProgress),
    };
    expect(kioskFirstUpcomingIndex(slots, results, today), 2);
    // Nothing coming any more: past the end.
    expect(kioskFirstUpcomingIndex(slots.sublist(0, 2), results, today), 2);
    expect(kioskFirstUpcomingIndex(const [], const {}, today), 0);
  });

  test('a live match needs data, not just the status', () {
    final slots = [
      match('playing', today),
      match('playing-no-data', today),
      match('scheduled', today),
      match('done', today),
    ];
    final results = {
      'playing': result('playing', MatchStatus.inProgress),
      'playing-no-data': result('playing-no-data', MatchStatus.inProgress),
      'scheduled': result('scheduled', MatchStatus.scheduled),
      'done': result('done', MatchStatus.finished),
    };
    final live = kioskLiveMatches(
      slots: slots,
      results: results,
      withData: {'playing', 'scheduled', 'done'},
      now: DateTime(2026, 10, 8, 15),
    );
    expect([for (final s in live) s.id], ['playing']);
  });

  test('a match the site left „in progress“ is not live the next day', () {
    final slots = [
      match('yesterday', today.addDays(-1)),
      match('today', today),
    ];
    final results = {
      'yesterday': result('yesterday', MatchStatus.inProgress),
      'today': result('today', MatchStatus.inProgress),
    };
    List<String> liveAt(DateTime now) => [
      for (final s in kioskLiveMatches(
        slots: slots,
        results: results,
        withData: {'yesterday', 'today'},
        now: now,
      ))
        s.id,
    ];
    // Today 15:00: yesterday's 14:00 start is 25 h ago.
    expect(liveAt(DateTime(2026, 10, 8, 15)), ['today']);
    // Yesterday evening it was within its twelve hours.
    expect(liveAt(DateTime(2026, 10, 7, 20)), contains('yesterday'));
  });

  group('kioskStreamMatches', () {
    const video = 'https://www.youtube.com/watch?v=wOq9EODb8w8';
    // One match with a video, 14:00–17:00 today, unless [slots] say else.
    List<String> streamsAt(
      DateTime now, {
      Map<String, MatchResult> results = const {},
      List<PrioritySlot>? slots,
    }) => [
      for (final s in kioskStreamMatches(
        slots: slots ?? [match('m', today, video: video)],
        results: results,
        now: now,
      ))
        s.id,
    ];

    test('a match with a video streams from an hour before the start', () {
      expect(streamsAt(DateTime(2026, 10, 8, 13, 30)), ['m']);
      expect(streamsAt(DateTime(2026, 10, 8, 12, 30)), isEmpty);
    });

    test('while it is being played — the players\' data is not waited for',
        () {
      expect(
        streamsAt(
          DateTime(2026, 10, 8, 15),
          results: {'m': result('m', MatchStatus.inProgress)},
        ),
        ['m'],
      );
    });

    test('a decided match streams on for half an hour after the server read '
        'its result', () {
      // Decided early, at 16:30: the closing minutes, then gone — not
      // YouTube's end screen until the planned end.
      final early = {
        'm': result('m', MatchStatus.finished,
            fetched: DateTime(2026, 10, 8, 16, 31)),
      };
      expect(streamsAt(DateTime(2026, 10, 8, 16, 50), results: early), ['m']);
      expect(streamsAt(DateTime(2026, 10, 8, 17, 5), results: early), isEmpty);
      // An overrun: the result came at 18:01, an hour past the planned end.
      final late = {
        'm': result('m', MatchStatus.finished,
            fetched: DateTime(2026, 10, 8, 18, 1)),
      };
      expect(streamsAt(DateTime(2026, 10, 8, 17, 30), results: late), ['m']);
      expect(streamsAt(DateTime(2026, 10, 8, 18, 20), results: late), ['m']);
      expect(streamsAt(DateTime(2026, 10, 8, 18, 40), results: late), isEmpty);
    });

    test('the half hour counts from when the server first saw the result '
        'decided — a later re-read (the app\'s ⟳) does not reopen the window',
        () {
      // Decided at 16:31, read again at 18:01 after a forced refresh.
      final reread = {
        'm': result('m', MatchStatus.finished,
            fetched: DateTime(2026, 10, 8, 18, 1),
            decided: DateTime(2026, 10, 8, 16, 31)),
      };
      expect(streamsAt(DateTime(2026, 10, 8, 16, 50), results: reread), ['m']);
      expect(streamsAt(DateTime(2026, 10, 8, 18, 10), results: reread), isEmpty);
    });

    test('a decided match never streams more than two hours past its planned '
        'end, nor before its day', () {
      // The nightly job re-read the result at 02:00 the next day.
      final reread = {
        'm': result('m', MatchStatus.finished,
            fetched: DateTime(2026, 10, 9, 2)),
      };
      expect(streamsAt(DateTime(2026, 10, 9, 2, 10), results: reread), isEmpty);
      // The site stored a forfeit days ahead: nothing opens before the day,
      // and on the day the stale result is long past its half hour.
      final forfeit = {
        'm': result('m', MatchStatus.forfeit,
            fetched: DateTime(2026, 10, 5, 9)),
      };
      expect(streamsAt(DateTime(2026, 10, 5, 9, 10), results: forfeit),
          isEmpty);
      expect(streamsAt(DateTime(2026, 10, 8, 13, 30), results: forfeit),
          isEmpty);
    });

    test('no video, another site, an úklid child or a hand-made match: no '
        'stream', () {
      final slots = [
        match('plain', today),
        match('vimeo', today, video: 'https://vimeo.com/123456789'),
        match('child', today, video: video, parent: 'plain'),
        match('hand', today, video: video, imported: false),
      ];
      expect(streamsAt(DateTime(2026, 10, 8, 15), slots: slots), isEmpty);
    });

    test('chronological', () {
      final slots = [
        match('later', today, video: video, start: const HourMinute(16, 0)),
        match('earlier', today, video: video),
      ];
      // 15:30: the first is being played, the second an hour before start.
      expect(
        streamsAt(DateTime(2026, 10, 8, 15, 30), slots: slots),
        ['earlier', 'later'],
      );
    });
  });
}

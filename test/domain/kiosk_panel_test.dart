import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/kiosk_panel.dart';
import 'package:rezervator/domain/models.dart';
import 'package:rezervator/features/kiosk/kiosk_ticker.dart';

void main() {
  const matchType = PrioritySlotType(
    id: 'tm',
    name: 'Zápas',
    isMatch: true,
    builtin: true,
  );

  PrioritySlot match(String id, Day date, {String? key, String? parent}) =>
      PrioritySlot(
        id: id,
        date: date,
        startsAt: const HourMinute(14, 0),
        endsAt: const HourMinute(17, 0),
        type: matchType,
        homeTeam: 'A',
        awayTeam: 'B',
        parentId: parent,
        importKey: key ?? 'cka:$id',
      );

  MatchResult result(String id, MatchStatus status) => MatchResult(
        matchId: id,
        status: status,
        fetchedAt: DateTime(2026, 10, 1),
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

  test('the list opens on the first match not decided from today on', () {
    final slots = [
      match('old', Day(2026, 10, 1)),
      match('done-today', Day(2026, 10, 8)),
      match('next', Day(2026, 10, 9)),
    ];
    final results = {
      'old': result('old', MatchStatus.finished),
      'done-today': result('done-today', MatchStatus.finished),
    };
    expect(kioskNowIndex(slots, results, today), 2);
    // Everything decided: the last one.
    expect(
      kioskNowIndex(slots.sublist(0, 2), results, today),
      1,
    );
    expect(kioskNowIndex(const [], const {}, today), 0);
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
    );
    expect([for (final s in live) s.id], ['playing']);
  });

  test('the ticker line: title and text, one line, bullets between', () {
    Message note(String title, String body) => Message(
          id: title,
          kind: MessageKind.notice,
          audience: MessageAudience.all,
          authorId: 'a',
          authorRole: MessageAuthorRole.admin,
          onDate: null,
          blockId: null,
          title: title,
          body: body,
          expiresAt: null,
          notify: true,
          createdAt: DateTime(2026, 9, 1),
          updatedAt: DateTime(2026, 9, 1),
        );
    expect(
      kioskTickerText([
        note('Brigáda', 'V  sobotu\n9:00'),
        note(' ', 'Jen text'),
      ]),
      'Brigáda: V sobotu 9:00   •   Jen text',
    );
  });
}

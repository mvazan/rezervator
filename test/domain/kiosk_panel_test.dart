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

  final today = Day(2026, 10, 8);

  test(
    'kioskNotices keeps active notices, drops expired, hidden and message ones',
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
    },
  );

  test(
    'next is the first undecided match from today, in progress included',
    () {
      final m = kioskMatches(
        slots: [
          match('old', Day(2026, 10, 1)),
          match('now', today),
          match('later', Day(2026, 10, 15)),
        ],
        results: {
          'old': result('old', MatchStatus.finished),
          'now': result('now', MatchStatus.inProgress),
        },
        today: today,
        historyDays: 21,
      );
      expect(m.next?.id, 'now');
      expect([for (final s in m.recent) s.id], ['old']);
    },
  );

  test('recent keeps the decided matches of the history window, oldest first',
      () {
    final slots = [
      for (var i = 1; i <= 5; i++) match('m$i', today.addDays(-i * 7)),
    ];
    final m = kioskMatches(
      slots: slots,
      results: {
        for (final s in slots) s.id: result(s.id, MatchStatus.finished),
      },
      today: today,
      historyDays: 21,
    );
    // 21 days back: m3 (21 days ago), m2, m1 — oldest first.
    expect([for (final s in m.recent) s.id], ['m3', 'm2', 'm1']);
    expect(m.next, isNull);
  });

  test('history 0 lists no finished match, only the next', () {
    final m = kioskMatches(
      slots: [match('old', today.addDays(-1)), match('new', today.addDays(2))],
      results: {'old': result('old', MatchStatus.finished)},
      today: today,
      historyDays: 0,
    );
    expect(m.recent, isEmpty);
    expect(m.next?.id, 'new');
  });

  test('manual matches, úklid children and a forfeit are handled', () {
    final m = kioskMatches(
      slots: [
        match('hand', Day(2026, 10, 9), key: 'xlsx:1'),
        match('child', Day(2026, 10, 9), parent: 'x'),
        match('ff', Day(2026, 10, 2)),
      ],
      results: {'ff': result('ff', MatchStatus.forfeit)},
      today: today,
      historyDays: 21,
    );
    expect(m.next, isNull);
    expect([for (final s in m.recent) s.id], ['ff']);
  });
}

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:rezervator/domain/messages.dart';
import 'package:rezervator/domain/models.dart';

/// Zprávy a nástěnka (0051): the pure half — grouping, tallies, reaction
/// lines, unread counts and the Czech labels. Every date is fixed; nothing
/// here reads the clock.
void main() {
  Message notice({
    String id = 'n1',
    DateTime? expiresAt,
    DateTime? createdAt,
  }) =>
      Message(
        id: id,
        kind: MessageKind.notice,
        audience: MessageAudience.all,
        authorId: 'admin',
        authorRole: MessageAuthorRole.admin,
        onDate: null,
        blockId: null,
        title: 'Nové dráhy',
        body: 'Od pondělí nové dráhy.',
        expiresAt: expiresAt,
        notify: true,
        createdAt: createdAt ?? DateTime(2026, 9, 1),
        updatedAt: createdAt ?? DateTime(2026, 9, 1),
      );

  Message message({
    String id = 'm1',
    MessageAudience audience = MessageAudience.block,
    Day? onDate,
    // `onDate: null` means "the default day"; this is the no-date case.
    bool undated = false,
    String? blockId = 'b1',
    String authorId = 'staff',
    MessageAuthorRole authorRole = MessageAuthorRole.player,
    DateTime? createdAt,
  }) =>
      Message(
        id: id,
        kind: MessageKind.message,
        audience: audience,
        authorId: authorId,
        authorRole: authorRole,
        onDate: undated ? null : onDate ?? Day(2026, 10, 2),
        blockId: blockId,
        title: null,
        body: 'Přijďte dřív.',
        expiresAt: null,
        notify: true,
        createdAt: createdAt ?? DateTime(2026, 10, 1),
        updatedAt: createdAt ?? DateTime(2026, 10, 1),
      );

  MessageRecipient recipient(
    String userId, {
    Reaction? reaction,
    String? reply,
    DateTime? readAt,
  }) =>
      MessageRecipient(
        messageId: 'm1',
        userId: userId,
        readAt: readAt,
        reaction: reaction,
        reply: reply,
        reactedAt: reaction == null && reply == null ? null : DateTime(2026, 10, 1, 12),
      );

  group('splitMessages', () {
    test('today and ahead stay open, earlier moves to older', () {
      final today = Day(2026, 10, 2);
      final m1 = message(id: 'm1', onDate: today);
      final m2 = message(id: 'm2', onDate: today.addDays(1));
      final m3 = message(id: 'm3', onDate: today.addDays(-1));
      final split = splitMessages([m3, m2, m1], today);
      expect(split.open.map((m) => m.id), ['m1', 'm2']);
      expect(split.older.map((m) => m.id), ['m3']);
    });

    test('same key day: posting order, however many (sort is not stable)', () {
      // Above 32 elements Dart's List.sort is a quicksort, so equal keys
      // come out in any order unless the comparator breaks the tie.
      final today = Day(2026, 10, 2);
      final ordered = [
        for (var i = 0; i < 40; i++)
          message(
            id: 'm${i.toString().padLeft(2, '0')}',
            onDate: i.isEven ? today : today.addDays(1),
            createdAt: DateTime(2026, 9, 1).add(Duration(minutes: i)),
          ),
      ];
      final shuffled = [...ordered]..shuffle(Random(7));
      final split = splitMessages(shuffled, today);
      expect(split.open.map((m) => m.id), [
        for (final m in ordered) if (m.onDate == today) m.id,
        for (final m in ordered) if (m.onDate != today) m.id,
      ]);
    });

    test('same key day and same posting time: by id', () {
      final today = Day(2026, 10, 2);
      final split = splitMessages(
          [for (final id in ['c', 'a', 'b']) message(id: id, onDate: today)],
          today);
      expect(split.open.map((m) => m.id), ['a', 'b', 'c']);
    });
  });

  group('splitNotices', () {
    test('active vs expired, oldest first within each', () {
      final now = DateTime(2026, 10, 2);
      final active1 = notice(id: 'a1', createdAt: DateTime(2026, 9, 1));
      final active2 = notice(id: 'a2', createdAt: DateTime(2026, 9, 15),
          expiresAt: DateTime(2026, 10, 4));
      final expired = notice(id: 'e1', createdAt: DateTime(2026, 8, 1),
          expiresAt: DateTime(2026, 9, 1));
      final split = splitNotices([expired, active2, active1], now);
      expect(split.active.map((m) => m.id), ['a1', 'a2']);
      expect(split.expired.map((m) => m.id), ['e1']);
    });

    test('same posting time: by id', () {
      final split = splitNotices(
          [for (final id in ['c', 'a', 'b']) notice(id: id)], DateTime(2026, 10, 2));
      expect(split.active.map((m) => m.id), ['a', 'b', 'c']);
    });
  });

  group('tally / tallyLabel', () {
    test('counts up/down/none and formats the Czech tally', () {
      final t = tally([
        recipient('p1', reaction: Reaction.up),
        recipient('p2', reaction: Reaction.up),
        recipient('p3', reaction: Reaction.down),
        recipient('p4'),
      ]);
      expect(t, const ReactionTally(up: 2, down: 1, none: 1));
      expect(tallyLabel(t), '2× 👍 · 1× 👎 · 1 bez reakce');
    });

    test('all reacted: no "bez reakce" clause', () {
      final t = tally([recipient('p1', reaction: Reaction.up)]);
      expect(tallyLabel(t), '1× 👍');
    });

    test('a reply without a chip counts as 💬, so the label is never empty', () {
      final t = tally([recipient('p1', reply: 'Ok, díky')]);
      expect(t, const ReactionTally(replied: 1));
      expect(tallyLabel(t), '1× 💬');
    });

    test('every recipient counted once, in the reaction line\'s order', () {
      final t = tally([
        recipient('p1', reaction: Reaction.up),
        recipient('p2', reaction: Reaction.down, reply: 'nestihnu'),
        recipient('p3', reply: 'Přijdu.'),
        recipient('p4', reply: 'Taky.'),
        recipient('p5'),
      ]);
      expect(t, const ReactionTally(up: 1, down: 1, replied: 2, none: 1));
      expect(tallyLabel(t), '1× 👍 · 1× 👎 · 2× 💬 · 1 bez reakce');
    });
  });

  group('reactionLine', () {
    test('Czech-sorted names, me as "ty", grouped by reaction', () {
      final line = reactionLine(
        [
          recipient('petr', reaction: Reaction.up),
          recipient('me', reaction: Reaction.up),
          recipient('tomas', reaction: Reaction.down, reply: 'nestihnu'),
          recipient('cenek'),
        ],
        const {'petr': 'Petr Novák', 'me': 'Já Hráč', 'tomas': 'Tomáš Válka', 'cenek': 'Čeněk'},
        'me',
      );
      // Names are never inflected in this UI; „ty“ closes its group.
      expect(line, '👍 Petr Novák, ty · 👎 Tomáš Válka „nestihnu“ · 1 bez reakce');
    });

    test('a reply without a chip gets its own 💬 group and is not "bez reakce"', () {
      final line = reactionLine(
        [recipient('petr', reply: 'Přijdu.'), recipient('cenek')],
        const {'petr': 'Petr Novák', 'cenek': 'Čeněk'},
        'me',
      );
      expect(line, '💬 Petr Novák „Přijdu.“ · 1 bez reakce');
      expect(tally([recipient('petr', reply: 'Přijdu.'), recipient('cenek')]),
          const ReactionTally(up: 0, down: 0, none: 1, replied: 1));
    });
  });

  group('reactionLine with namesForNone (the sent side\'s expanded list)', () {
    test('lists who has not answered, Czech-sorted, unknown ones only counted', () {
      final line = reactionLine(
        [
          recipient('petr', reaction: Reaction.up),
          recipient('tomas'),
          recipient('cenek'),
          recipient('ghost'),
        ],
        const {'petr': 'Petr Novák', 'tomas': 'Tomáš Válka', 'cenek': 'Čeněk'},
        'me',
        namesForNone: true,
      );
      expect(line, '👍 Petr Novák · bez reakce: Čeněk, Tomáš Válka a 1 další');
    });

    test('everybody known: just the names; nobody left: no clause', () {
      expect(
        reactionLine([recipient('tomas')], const {'tomas': 'Tomáš Válka'}, 'me',
            namesForNone: true),
        'bez reakce: Tomáš Válka',
      );
      expect(
        reactionLine([recipient('tomas', reaction: Reaction.down)],
            const {'tomas': 'Tomáš Válka'}, 'me',
            namesForNone: true),
        '👎 Tomáš Válka',
      );
    });

    test('the received line keeps the plain count', () {
      expect(
        reactionLine([recipient('tomas')], const {'tomas': 'Tomáš Válka'}, 'me'),
        '1 bez reakce',
      );
    });
  });

  group('Message.fromJson', () {
    test('reads author_role into authorIsAdmin', () {
      final json = {
        'id': 'm9', 'kind': 'message', 'audience': 'day', 'author_id': 'a1',
        'author_role': 'admin', 'on_date': '2026-10-02', 'block_id': null,
        'title': null, 'body': 'Ahoj.', 'expires_at': null, 'notify': true,
        'created_at': '2026-10-01T10:00:00Z', 'updated_at': '2026-10-01T10:00:00Z',
      };
      expect(Message.fromJson(json).authorIsAdmin, isTrue);
      expect(Message.fromJson({...json, 'author_role': 'player'}).authorIsAdmin, isFalse);
    });
  });

  group('unreadCounts', () {
    test('counts my unread messages and notices separately', () {
      final n1 = notice(id: 'n1');
      final m1 = message(id: 'm1');
      final counts = unreadCounts(
        all: [n1, m1],
        mine: [
          MessageRecipient(messageId: 'n1', userId: 'me', readAt: null,
              reaction: null, reply: null, reactedAt: null),
          MessageRecipient(messageId: 'm1', userId: 'me', readAt: DateTime(2026, 10, 1),
              reaction: null, reply: null, reactedAt: null),
        ],
        meId: 'me',
        now: DateTime(2026, 10, 2),
      );
      expect(counts, (messages: 0, notices: 1));
    });

    test('an unread message counts as a message, a notice as a notice; '
        'another player\'s row counts for nobody', () {
      MessageRecipient row(String messageId, String userId) => MessageRecipient(
          messageId: messageId, userId: userId, readAt: null,
          reaction: null, reply: null, reactedAt: null);
      final counts = unreadCounts(
        all: [notice(id: 'n1'), message(id: 'm1'), message(id: 'm2')],
        mine: [row('n1', 'me'), row('m1', 'me'), row('m2', 'petr')],
        meId: 'me',
        now: DateTime(2026, 10, 2),
      );
      expect(counts, (messages: 1, notices: 1));
    });

    test('an expired unread notice does not count (the board never marks it)', () {
      final counts = unreadCounts(
        all: [notice(id: 'n1', expiresAt: DateTime(2026, 10, 1))],
        mine: [
          MessageRecipient(messageId: 'n1', userId: 'me', readAt: null,
              reaction: null, reply: null, reactedAt: null),
        ],
        meId: 'me',
        now: DateTime(2026, 10, 2),
      );
      expect(counts, (messages: 0, notices: 0));
    });
  });

  group('headerLabel', () {
    test('the six forms', () {
      expect(
        headerLabel(message(audience: MessageAudience.block, authorId: 'duty1'),
            authorName: 'Bára', authorIsAdmin: false, meId: 'me'),
        'Od služby (Bára)',
      );
      expect(
        headerLabel(message(audience: MessageAudience.day, authorId: 'admin1'),
            authorName: 'Adam', authorIsAdmin: true, meId: 'me'),
        'Od správce (Adam)',
      );
      expect(
        headerLabel(message(audience: MessageAudience.admins, authorId: 'petr'),
            authorName: 'Petr Novák', authorIsAdmin: false, meId: 'me'),
        'Od hráče: Petr Novák',
      );
      expect(
        headerLabel(message(audience: MessageAudience.block, authorId: 'me'),
            authorName: 'Já Hráč', authorIsAdmin: false, meId: 'me'),
        'Ode mě hráčům',
      );
      expect(
        headerLabel(message(audience: MessageAudience.admins, authorId: 'me'),
            authorName: 'Já Hráč', authorIsAdmin: false, meId: 'me'),
        'Ode mě správci',
      );
      expect(
        headerLabel(message(audience: MessageAudience.duty, authorId: 'me'),
            authorName: 'Já Hráč', authorIsAdmin: false, meId: 'me'),
        'Ode mě službě',
      );
    });

    test('to the staff the author decides: a player or an admin', () {
      // An admin may write to „Správci“ or „Službě“ too: the header names
      // them as the admin they are, never as a player.
      for (final audience in [MessageAudience.admins, MessageAudience.duty]) {
        expect(
          headerLabel(message(audience: audience, authorId: 'petr'),
              authorName: 'Petr Novák', authorIsAdmin: false, meId: 'me'),
          'Od hráče: Petr Novák',
        );
        expect(
          headerLabel(message(audience: audience, authorId: 'admin1'),
              authorName: 'Adam', authorIsAdmin: true, meId: 'me'),
          'Od správce (Adam)',
        );
      }
    });
  });

  group('contextLabel', () {
    final b1 = TimeBlock(
        id: 'b1', startsAt: HourMinute(16, 0), endsAt: HourMinute(17, 0),
        position: 0, active: true);
    test('block, day, training-context, none', () {
      expect(contextLabel(message(audience: MessageAudience.block, onDate: Day(2026, 10, 2)), b1),
          'pá 2. 10. · 16:00–17:00');
      expect(contextLabel(message(audience: MessageAudience.day, onDate: Day(2026, 10, 2)), null),
          'celý den pá 2. 10.');
      expect(
        contextLabel(
          message(audience: MessageAudience.duty, onDate: Day(2026, 10, 5), blockId: null),
          b1,
        ),
        'k tréninku po 5. 10. · 16:00–17:00',
      );
      expect(
        contextLabel(message(audience: MessageAudience.admins, undated: true, blockId: null), null),
        null,
      );
    });
  });

  group('keyDay', () {
    test('onDate when set, else the local posting day', () {
      expect(keyDay(message(onDate: Day(2026, 10, 5))), Day(2026, 10, 5));
      expect(keyDay(message(undated: true)), Day(2026, 10, 1));
      // 23:30 UTC on 1 October is already 2 October in Prague.
      final late = Message.fromJson({
        'id': 'm8', 'kind': 'message', 'audience': 'admins', 'author_id': 'p',
        'author_role': 'player', 'on_date': null, 'block_id': null,
        'title': null, 'body': 'Ahoj.', 'expires_at': null, 'notify': true,
        'created_at': '2026-10-01T23:30:00Z', 'updated_at': '2026-10-01T23:30:00Z',
      });
      expect(keyDay(late), Day(2026, 10, 2));
    });
  });

  group('noticeFooter / seenLabel', () {
    test('„vyvěšeno … · platí do …“ and „do odvolání“', () {
      final now = DateTime(2026, 9, 28);
      expect(
        noticeFooter(notice(createdAt: DateTime(2026, 9, 28),
            expiresAt: DateTime(2026, 10, 12)), now),
        'vyvěšeno po 28. 9. · platí do 12. 10.',
      );
      expect(noticeFooter(notice(createdAt: DateTime(2026, 9, 28)), now),
          'vyvěšeno po 28. 9. · do odvolání');
    });

    test('„Zobrazilo 12 z 40“', () {
      expect(seenLabel(12, 40), 'Zobrazilo 12 z 40');
    });
  });

  group('dutyRecipientIds', () {
    final periods = [
      DutyPeriod(id: 'p1', startsOn: Day(2026, 9, 28), endsOn: Day(2026, 10, 4)),
      DutyPeriod(id: 'p2', startsOn: Day(2026, 10, 5), endsOn: Day(2026, 10, 11)),
    ];
    const assignments = [
      DutyAssignment(periodId: 'p1', userId: 'bara'),
      DutyAssignment(periodId: 'p1', userId: 'me'),
      DutyAssignment(periodId: 'p2', userId: 'jan'),
    ];

    test("today's assignees, me excluded", () {
      expect(dutyRecipientIds(periods, assignments, 'me', Day(2026, 10, 2)), ['bara']);
      expect(dutyRecipientIds(periods, assignments, 'me', Day(2026, 10, 5)), ['jan']);
    });

    test('nobody serves today, or only I do', () {
      expect(dutyRecipientIds(periods, assignments, 'me', Day(2026, 10, 20)), isEmpty);
      expect(
        dutyRecipientIds(periods, const [DutyAssignment(periodId: 'p1', userId: 'me')],
            'me', Day(2026, 10, 2)),
        isEmpty,
      );
    });

    test('only members: a placeholder on duty is nobody to write to', () {
      const withEmil = [
        DutyAssignment(periodId: 'p1', userId: 'me'),
        DutyAssignment(periodId: 'p1', userId: 'emil'),
      ];
      final today = Day(2026, 10, 2);
      // `members` = the roster's ids with an account; Emil is „hráč bez účtu“.
      expect(dutyRecipientIds(periods, withEmil, 'me', today, members: {'me', 'bara'}),
          isEmpty);
      expect(dutyRecipientIds(periods, assignments, 'me', today, members: {'me', 'bara'}),
          ['bara']);
      // No roster yet: nobody filtered out, the server decides.
      expect(dutyRecipientIds(periods, withEmil, 'me', today), ['emil']);
    });
  });

  group('dayRecipientIds', () {
    Reservation res(String id, String player, Day date, String block,
            {DateTime? cancelledAt}) =>
        Reservation(
          id: id, playerId: player, date: date, blockId: block, lane: 1,
          createdVia: 'app', createdAt: DateTime(2026, 9, 1),
          cancelledAt: cancelledAt,
        );
    final day = Day(2026, 10, 2);
    final reservations = [
      res('r1', 'jan', day, 'b1'),
      res('r2', 'jan', day, 'b2'),
      res('r3', 'petra', day, 'b2'),
      res('r4', 'me', day, 'b1'),
      res('r5', 'zrusil', day, 'b1', cancelledAt: DateTime(2026, 9, 30)),
      res('r6', 'jinde', day.addDays(1), 'b1'),
    ];

    test('the whole day: live, each once, me excluded', () {
      expect(dayRecipientIds(reservations, date: day, meId: 'me'), ['jan', 'petra']);
    });

    test('one block', () {
      expect(dayRecipientIds(reservations, date: day, blockId: 'b1', meId: 'me'), ['jan']);
    });

    test('only members: a block booked by placeholders alone reaches nobody', () {
      // `members` = the roster's ids with an account; Jan is „hráč bez účtu“.
      const members = {'me', 'petra', 'zrusil', 'jinde'};
      expect(
          dayRecipientIds(reservations, date: day, blockId: 'b1', meId: 'me',
              members: members),
          isEmpty);
      expect(dayRecipientIds(reservations, date: day, meId: 'me', members: members),
          ['petra']);
    });
  });

  group('recipientPreviewLabel', () {
    test('"Dostane N hráči: …" in Czech list form', () {
      expect(recipientPreviewLabel(['Jan Novák']), 'Dostane 1 hráč: Jan Novák');
      expect(recipientPreviewLabel(['Jan Novák', 'Petra Svobodová']),
          'Dostanou 2 hráči: Jan Novák a Petra Svobodová');
      expect(recipientPreviewLabel([]), 'Nikdo nemá rezervaci');
    });

    // The verb agrees with the numeral: 1 → Dostane, 2–4 → Dostanou (plural
    // subject), 5+ → Dostane again (a numeral of five or more takes the
    // singular, with the genitive „hráčů“).
    test('the verb follows the count: 1 Dostane, 2–4 Dostanou, 5+ Dostane', () {
      List<String> names(int n) => [for (var i = 1; i <= n; i++) 'Hráč $i'];
      expect(recipientPreviewLabel(names(3)).startsWith('Dostanou 3 hráči: '), isTrue);
      expect(recipientPreviewLabel(names(4)).startsWith('Dostanou 4 hráči: '), isTrue);
      expect(recipientPreviewLabel(names(5)).startsWith('Dostane 5 hráčů: '), isTrue);
      expect(recipientPreviewLabel(names(12)).startsWith('Dostane 12 hráčů: '), isTrue);
    });
  });

  group('serverLength', () {
    test('counts code points of the trimmed text, as char_length does', () {
      expect(serverLength('  Ahoj  '), 4);
      // One grapheme each (what TextField.maxLength counts), but 👍🏽 is
      // two code points and the family five — the server's measure.
      expect(serverLength('👍'), 1);
      expect(serverLength('👍🏽'), 2);
      expect(serverLength('👨‍👩‍👧'), 5);
      expect(serverLength('\n\t'), 0);
    });

    test('the limits are the server\'s', () {
      expect(noticeTitleMax, 80);
      expect(messageBodyMax, 500);
      expect(noticeBodyMax, 2000);
      expect(replyMax, 200);
      expect(overLimit('👍🏽' * 40, noticeTitleMax), isFalse);
      expect(overLimit('${'👍🏽' * 40}a', noticeTitleMax), isTrue);
    });
  });
}

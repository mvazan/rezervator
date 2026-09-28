/// Zprávy a nástěnka (0051), the pure half: grouping into open/older and
/// active/expired, reaction tallies and Czech-sorted reaction lines, unread
/// counts, the six "Od .../Ode mě ..." header forms, the context chip text
/// and the staff composer's recipient preview. Pure Dart over `messages`/
/// `message_recipients` rows, unit-tested; the screens only render it. The
/// rights themselves are the server's (`message_send`'s gates in
/// 0051_messages.sql) — the app only hides what the server would refuse.
/// A different file from `lib/core/messages.dart` (the unrelated snack/
/// overlay helper) — same word, unrelated module.
library;

import 'collation.dart';
import 'duties.dart' show dutyDayLabel, joinNames;
import 'labels.dart' show czechCount;
import 'models.dart';

/// The day a message is grouped and sorted by: [Message.onDate] when it
/// has one, otherwise the day it was posted (`createdAt`, local calendar
/// day). Today only decides open vs older in [splitMessages], never the key.
Day keyDay(Message m) => m.onDate ?? Day.fromDateTime(m.createdAt.toLocal());

/// [msgs] split by [keyDay] against [today]: today and ahead stay open
/// (chronological), everything earlier moves to `older` (also
/// chronological — the newest-of-the-old last, so "Starší" reads top to
/// bottom like the rest of the list once expanded). Within one key day in
/// posting order, then by id: Dart's `List.sort` is not stable (a
/// quicksort above 32 items), and the input is stream order anyway, so a
/// correction could otherwise land above the message it corrects.
({List<Message> open, List<Message> older}) splitMessages(
  Iterable<Message> msgs,
  Day today,
) {
  final sorted = [...msgs]
    ..sort((a, b) {
      final byDay = keyDay(a).compareTo(keyDay(b));
      if (byDay != 0) return byDay;
      final byPosted = a.createdAt.compareTo(b.createdAt);
      return byPosted != 0 ? byPosted : a.id.compareTo(b.id);
    });
  return (
    open: [for (final m in sorted) if (!keyDay(m).isBefore(today)) m],
    older: [for (final m in sorted) if (keyDay(m).isBefore(today)) m],
  );
}

/// Notices split into active (not expired) and expired, oldest posted
/// first in each group — the Nástěnka order (ties by id, see
/// [splitMessages]).
({List<Message> active, List<Message> expired}) splitNotices(
  Iterable<Message> notices,
  DateTime now,
) {
  final sorted = [...notices]
    ..sort((a, b) {
      final byPosted = a.createdAt.compareTo(b.createdAt);
      return byPosted != 0 ? byPosted : a.id.compareTo(b.id);
    });
  bool isExpired(Message m) =>
      m.expiresAt != null && !m.expiresAt!.isAfter(now);
  return (
    active: [for (final m in sorted) if (!isExpired(m)) m],
    expired: [for (final m in sorted) if (isExpired(m)) m],
  );
}

/// How many recipients reacted 👍, 👎, only replied, or not at all —
/// every recipient in exactly one bucket, so the four add up to them all.
class ReactionTally {
  const ReactionTally({
    this.up = 0,
    this.down = 0,
    this.none = 0,
    this.replied = 0,
  });

  final int up;
  final int down;

  /// Neither a chip nor a reply — a reply alone is an answer.
  final int none;

  /// A reply without a chip — the 💬 group of [reactionLine].
  final int replied;

  @override
  bool operator ==(Object other) =>
      other is ReactionTally &&
      other.up == up &&
      other.down == down &&
      other.none == none &&
      other.replied == replied;

  @override
  int get hashCode => Object.hash(up, down, none, replied);

  @override
  String toString() =>
      'ReactionTally(up: $up, down: $down, none: $none, replied: $replied)';
}

/// [recipients] counted by reaction — a sent message's summary.
ReactionTally tally(Iterable<MessageRecipient> recipients) {
  var up = 0, down = 0, none = 0, replied = 0;
  for (final r in recipients) {
    switch (r.reaction) {
      case Reaction.up:
        up++;
      case Reaction.down:
        down++;
      case null:
        // A reply without a chip is an answer, not "bez reakce".
        if (_hasReply(r)) {
          replied++;
        } else {
          none++;
        }
    }
  }
  return ReactionTally(up: up, down: down, none: none, replied: replied);
}

/// „2× 👍 · 1× 👎 · 1× 💬 · 3 bez reakce“ — a sent message's summary, in
/// [reactionLine]'s group order. A zero count is left out entirely (never
/// „0× 👎“); no "bez reakce" clause when everybody answered. Empty only for
/// no recipients at all — a reply alone still shows („1× 💬“), since the
/// sent tile's tap target is this text.
String tallyLabel(ReactionTally t) => [
      if (t.up > 0) '${t.up}× 👍',
      if (t.down > 0) '${t.down}× 👎',
      if (t.replied > 0) '${t.replied}× 💬',
      if (t.none > 0) _noReaction(t.none),
    ].join(' · ');

/// „3 bez reakce“ — "bez reakce" does not inflect with the count in front
/// of it, unlike "služba".
String _noReaction(int n) =>
    czechCount(n, 'bez reakce', 'bez reakce', 'bez reakce');

bool _hasReply(MessageRecipient r) => (r.reply ?? '').isNotEmpty;

/// „👍 Petra, ty · 👎 Tomáš „nestihnu“ · 1 bez reakce“ — a received
/// message's reaction line: names Czech-sorted within each reaction group
/// (👍, then 👎, then 💬 for a reply without a chip), the signed-in player
/// last in their group as „ty“, a reply quoted after its name, then how
/// many have not reacted. A recipient the roster does not know is left out
/// of the named groups but still counts toward the "bez reakce" tail when
/// they have not reacted.
String reactionLine(
  Iterable<MessageRecipient> recipients,
  Map<String, String> names,
  String? meId,
) {
  String label(MessageRecipient r) {
    final name = r.userId == meId ? 'ty' : names[r.userId];
    if (name == null) return '';
    final reply = r.reply;
    return (reply == null || reply.isEmpty) ? name : '$name „$reply“';
  }

  List<String> group(Reaction? reaction) {
    final entries = [
      for (final r in recipients)
        if (r.reaction == reaction && (reaction != null || _hasReply(r)))
          (id: r.userId, isMe: r.userId == meId, label: label(r)),
    ]..sort((a, b) {
        // „ty“ closes its group: „👍 Petra, ty“.
        if (a.isMe != b.isMe) return a.isMe ? 1 : -1;
        return compareCzech(names[a.id] ?? '', names[b.id] ?? '');
      });
    return [for (final e in entries) if (e.label.isNotEmpty) e.label];
  }

  final up = group(Reaction.up);
  final down = group(Reaction.down);
  // Replied without pressing a chip.
  final replied = group(null);
  final none =
      recipients.where((r) => r.reaction == null && !_hasReply(r)).length;
  return [
    if (up.isNotEmpty) '👍 ${up.join(', ')}',
    if (down.isNotEmpty) '👎 ${down.join(', ')}',
    if (replied.isNotEmpty) '💬 ${replied.join(', ')}',
    if (none > 0) _noReaction(none),
  ].join(' · ');
}

/// How many of [all] have an unread recipient row of [meId]'s, split by
/// kind. A notice already expired at [now] does not count: Nástěnka marks
/// only the active notices read, so an expired one left unread would keep
/// the badge up with nothing on the board to clear it.
({int messages, int notices}) unreadCounts({
  required List<Message> all,
  required List<MessageRecipient> mine,
  required String? meId,
  required DateTime now,
}) {
  if (meId == null) return (messages: 0, notices: 0);
  final byId = {for (final m in all) m.id: m};
  var messages = 0, notices = 0;
  for (final r in mine) {
    if (r.userId != meId || r.readAt != null) continue;
    final m = byId[r.messageId];
    if (m == null) continue;
    if (m.kind == MessageKind.notice) {
      final expiresAt = m.expiresAt;
      if (expiresAt == null || expiresAt.isAfter(now)) notices++;
    } else {
      messages++;
    }
  }
  return (messages: messages, notices: notices);
}

/// The six header forms a `MessageTile` shows, by who sent it and to whom:
/// „Od služby (Bára)“, „Od správce (Adam)“, „Od Petr Novák“ (names are
/// never inflected), „Ode mě hráčům“, „Ode mě správci“, „Ode mě službě“.
String headerLabel(
  Message m, {
  required String authorName,
  required bool authorIsAdmin,
  required String? meId,
}) {
  if (m.authorId != null && m.authorId == meId) {
    return switch (m.audience) {
      MessageAudience.admins => 'Ode mě správci',
      MessageAudience.duty => 'Ode mě službě',
      MessageAudience.day || MessageAudience.block => 'Ode mě hráčům',
      MessageAudience.all => 'Ode mě',
    };
  }
  return switch (m.audience) {
    MessageAudience.day || MessageAudience.block =>
      authorIsAdmin ? 'Od správce ($authorName)' : 'Od služby ($authorName)',
    MessageAudience.admins || MessageAudience.duty => 'Od $authorName',
    MessageAudience.all => authorName,
  };
}

/// „pá 2. 10. · 16:00–17:00“ (block), „celý den pá 2. 10.“ (day), „k
/// tréninku po 5. 10. · 16:00–17:00“ (a player's message with a training
/// context), or null (no date). [block] null (none, or since removed)
/// leaves the time out. Never called for the board.
String? contextLabel(Message m, TimeBlock? block) {
  final date = m.onDate;
  if (date == null) return null;
  final day = dutyDayLabel(date);
  final time = block == null ? '' : ' · ${block.label}';
  return switch (m.audience) {
    MessageAudience.day => 'celý den $day',
    MessageAudience.block => '$day$time',
    MessageAudience.admins || MessageAudience.duty => 'k tréninku $day$time',
    MessageAudience.all => day,
  };
}

/// „vyvěšeno so 28. 9. · platí do 12. 10.“ / „vyvěšeno so 28. 9. · do
/// odvolání“ — the Nástěnka card footer, in local calendar days; the
/// expiry is written without its weekday, as the spec writes it.
String noticeFooter(Message m, DateTime now) {
  final posted = dutyDayLabel(Day.fromDateTime(m.createdAt.toLocal()));
  final expires = m.expiresAt?.toLocal();
  final until = expires == null
      ? 'do odvolání'
      : 'platí do ${expires.day}. ${expires.month}.';
  return 'vyvěšeno $posted · $until';
}

/// „Zobrazilo 12 z 40“ — the admin's seen count on a notice.
String seenLabel(int read, int total) => 'Zobrazilo $read z $total';

/// Who a `duty`-audience message would reach right now: the assignees of
/// the period covering [today], [meId] excluded, and — when [members] is
/// given — only those in it. Empty when nobody serves today (or only I do,
/// or only players without an account) — the caller renders that as „Dnes
/// nikdo neslouží“.
///
/// [members] is the roster's ids with an account: `{for (final p in
/// players) if (p.hasAccount) p.id}` over `playersProvider`. The `players`
/// view already applies `message_send`'s member rule (approved, not the
/// kiosk, not a visiting superadmin) and [PlayerName.hasAccount] drops the
/// placeholders („hráč bez účtu“), so the set matches the server's. Null
/// (the roster not loaded yet) filters nobody out; the server set stays
/// authoritative either way.
List<String> dutyRecipientIds(
  Iterable<DutyPeriod> periods,
  Iterable<DutyAssignment> assignments,
  String? meId,
  Day today, {
  Set<String>? members,
}) {
  final current = [for (final p in periods) if (p.covers(today)) p];
  if (current.isEmpty) return const [];
  final periodId = current.first.id;
  return [
    for (final a in assignments)
      if (a.periodId == periodId &&
          a.userId != meId &&
          (members == null || members.contains(a.userId)))
        a.userId,
  ];
}

/// Who a `day`/`block`-audience message would reach: players with a live
/// reservation on [date] (any block, or [blockId] when given), [meId]
/// excluded, each once, and — when [members] is given — only those in it:
/// the set `message_send` computes server-side, so the staff composer can
/// preview it before sending. [members] is the same roster set as for
/// [dutyRecipientIds] (ids with an account, from `playersProvider`), which
/// leaves out a placeholder's booking („hráč bez účtu“) just as the server
/// does; null (the roster not loaded yet) filters nobody out. The server
/// set is authoritative.
List<String> dayRecipientIds(
  Iterable<Reservation> reservations, {
  required Day date,
  String? blockId,
  String? meId,
  Set<String>? members,
}) {
  final seen = <String>{};
  return [
    for (final r in reservations)
      if (r.isLive &&
          r.date == date &&
          (blockId == null || r.blockId == blockId) &&
          r.playerId != meId &&
          (members == null || members.contains(r.playerId)) &&
          seen.add(r.playerId))
        r.playerId,
  ];
}

/// „Dostane 2 hráči: Jan Novák a Petra Svobodová“ / „Nikdo nemá
/// rezervaci“ for an empty list — the staff composer's live recipient
/// preview. Keeps the order of [names]: sort them with [compareCzech]
/// first.
String recipientPreviewLabel(List<String> names) => names.isEmpty
    ? 'Nikdo nemá rezervaci'
    : 'Dostane ${czechCount(names.length, 'hráč', 'hráči', 'hráčů')}: '
        '${joinNames(names)}';

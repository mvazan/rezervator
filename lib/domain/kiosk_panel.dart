/// The kiosk's side panel, the pure half: which notices are up, which matches
/// the list shows and which one is being played. Pure Dart, unit-tested;
/// `KioskInfoPanel` only renders it.
library;

import 'messages.dart' show isScheduled, noticePostedAt, splitNotices;
import 'models.dart';
import 'results.dart' show isLive;
import 'youtube.dart' show youtubeVideoId;

/// The notices on the wall right now: kind notice, not expired, not hidden
/// from the kiosk by the admin, newest first (the Nástěnka order).
List<Message> kioskNotices(Iterable<Message> messages, DateTime now) =>
    splitNotices(
      messages.where((m) => m.kind == MessageKind.notice && m.showOnKiosk),
      now,
    ).active;

/// Whether [m] is a fresh notice on the kiosk (0080): up for less than
/// [days] days at [now], counted from when it went up ([noticePostedAt]).
/// A notice scheduled for later ([isScheduled]) is never fresh — it is not
/// up yet. A notice posted after [now] is fresh: the kiosk's minute clock
/// runs up to ~75 s behind, so a notice that has just gone up is usually
/// „ahead“ of it.
bool isFreshNotice(Message m, DateTime now, int days) =>
    !isScheduled(m, now) &&
    now.difference(noticePostedAt(m)) < Duration(days: days);

/// How long [m] stays on the kiosk — the panel's card and the status bar —
/// before the next notice: twice [turn] when fresh notices linger
/// ([KioskNoticesFresh.lingers]) and [m] is fresh for [days]
/// ([isFreshNotice]), otherwise [turn].
Duration kioskNoticeTurn(
  Message m, {
  required DateTime now,
  required Duration turn,
  required KioskNoticesFresh fresh,
  required int days,
}) =>
    fresh.lingers && isFreshNotice(m, now, days) ? turn * 2 : turn;

bool _decided(MatchResult? r) =>
    r?.status == MatchStatus.finished || r?.status == MatchStatus.forfeit;

/// The competition year [today] is in: from 1 July to 30 June of the next
/// calendar year. The drawer never lists a match outside it.
({Day start, Day end}) kioskSeason(Day today) {
  final year = today.month >= 7 ? today.year : today.year - 1;
  return (start: Day(year, 7, 1), end: Day(year + 1, 6, 30));
}

/// The Monday of [day]'s ISO week.
Day mondayOf(Day day) => day.addDays(1 - day.weekday);

/// The matches the drawer lists, chronological.
typedef KioskMatchWindow = ({
  List<PrioritySlot> matches,

  /// There are matches of the season before the first listed day.
  bool moreBefore,

  /// There are matches of the season after the last listed day.
  bool moreAfter,
});

/// The alley's federation matches from [weeksBack] weeks before the current
/// week to [weeksAhead] weeks after it (the league plays in rounds a week
/// apart), both counted from the current Monday/Sunday and widened by
/// [extraBack]/[extraAhead] weeks the visitor asked for with „Zobrazit
/// další“. With [showUpcoming] off nothing after today is listed. Never
/// outside the current season ([kioskSeason]).
KioskMatchWindow kioskMatchWindow({
  required List<PrioritySlot> slots,
  required Day today,
  required int weeksBack,
  required int weeksAhead,
  required bool showUpcoming,
  int extraBack = 0,
  int extraAhead = 0,
}) {
  final season = kioskSeason(today);
  final thisMonday = mondayOf(today);
  var from = thisMonday.addDays(-7 * (weeksBack + extraBack));
  var to = showUpcoming
      ? thisMonday.addDays(6 + 7 * (weeksAhead + extraAhead))
      : today;
  if (from.isBefore(season.start)) from = season.start;
  if (to.isAfter(season.end)) to = season.end;
  final all = [
    for (final s in slots)
      if (s.type.isMatch &&
          s.parentId == null &&
          s.fromFederation &&
          !s.date.isBefore(season.start) &&
          !s.date.isAfter(season.end))
        s,
  ]..sort((a, b) {
      final byDay = a.date.compareTo(b.date);
      return byDay != 0 ? byDay : a.startsAt.compareTo(b.startsAt);
    });
  return (
    matches: [
      for (final s in all)
        if (!s.date.isBefore(from) && !s.date.isAfter(to)) s,
    ],
    moreBefore: all.any((s) => s.date.isBefore(from)),
    moreAfter: showUpcoming && all.any((s) => s.date.isAfter(to)),
  );
}

/// Where the list opens (Výsledky's rule): the first coming match — from
/// today on, neither decided nor being played — is the first row hidden
/// below the bottom edge, as many played and playing matches as fit above
/// it. [matches]'s length when nothing is coming any more.
int kioskFirstUpcomingIndex(
  List<PrioritySlot> matches,
  Map<String, MatchResult> results,
  Day today,
) {
  for (var i = 0; i < matches.length; i++) {
    final r = results[matches[i].id];
    if (!matches[i].date.isBefore(today) &&
        !_decided(r) &&
        r?.status != MatchStatus.inProgress) {
      return i;
    }
  }
  return matches.length;
}

/// The days a visitor's scroll of the board brought into view: those of
/// [next] that [previous] did not show — before it when the board went
/// back, after it when it went forward (the days that left the screen do
/// not count). Null when nothing new came into view. [previous] null = the
/// board as it opens, [today] at its left edge and as many days as [next].
({Day first, Day last})? kioskNewlyShownDays(
  ({Day first, Day last})? previous,
  ({Day first, Day last}) next, {
  required Day today,
}) {
  final prev =
      previous ??
      (first: today, last: today.addDays(next.last.differenceInDays(next.first)));
  if (next.first.isBefore(prev.first)) {
    final dayBefore = prev.first.addDays(-1);
    return (
      first: next.first,
      last: next.last.isBefore(dayBefore) ? next.last : dayBefore,
    );
  }
  if (next.last.isAfter(prev.last)) {
    final dayAfter = prev.last.addDays(1);
    return (
      first: next.first.isAfter(dayAfter) ? next.first : dayAfter,
      last: next.last,
    );
  }
  return null;
}

/// The matches being played whose figures the drawer can show: status in
/// progress, still within the live window at [now] ([isLive]: a row the
/// site left „in progress“ is not live the next day), AND [withData] says
/// the site has delivered their players — a match merely marked as playing
/// has nothing to put on the drawer yet. Chronological, so the rotation
/// order is stable.
List<PrioritySlot> kioskLiveMatches({
  required List<PrioritySlot> slots,
  required Map<String, MatchResult> results,
  required DateTime now,
  required Set<String> withData,
}) {
  return [
    for (final s in slots)
      if (s.type.isMatch &&
          s.parentId == null &&
          s.fromFederation &&
          results[s.id]?.status == MatchStatus.inProgress &&
          isLive(s, results[s.id], now) &&
          withData.contains(s.id))
        s,
  ]..sort((a, b) {
      final byDay = a.date.compareTo(b.date);
      return byDay != 0 ? byDay : a.startsAt.compareTo(b.startsAt);
    });
}

/// How long a decided match streams on after the server first saw it
/// decided (0066, `decided_at`; the last read when a row predates it): the
/// closing minutes of a stream run after the site stamps the result.
const streamGrace = Duration(minutes: 30);

/// How far past the planned end a decided match may stream at all: an
/// overrun keeps its stream, a result re-read the next night does not
/// reopen the window.
const streamOverrun = Duration(hours: 2);

/// The matches whose stream the kiosk's window shows (0066): the alley's
/// own federation matches with a YouTube video that are on air — [isLive]
/// (from an hour before the start until the site stamps the result, at
/// most twelve hours), or decided and still within [streamGrace] of the
/// moment the server first saw it decided (`decided_at`; a forced re-read
/// in the app does not reopen the window), from an hour before the start
/// (a forfeit the site stores days ahead opens nothing) to at most
/// [streamOverrun] past the planned end. Not gated on the players' data
/// like [kioskLiveMatches]: a stream starts before the first throw.
/// Chronological.
List<PrioritySlot> kioskStreamMatches({
  required List<PrioritySlot> slots,
  required Map<String, MatchResult> results,
  required DateTime now,
}) {
  bool onAir(PrioritySlot s) {
    final r = results[s.id];
    if (isLive(s, r, now)) return true;
    if (r == null || !_decided(r) || !s.timeKnown) return false;
    final start = DateTime(
      s.date.year,
      s.date.month,
      s.date.day,
      s.startsAt.hour,
      s.startsAt.minute,
    );
    final end = DateTime(
      s.date.year,
      s.date.month,
      s.date.day,
      s.endsAt.hour,
      s.endsAt.minute,
    );
    final until = (r.decidedAt ?? r.fetchedAt).add(streamGrace);
    final latest = end.add(streamOverrun);
    return !now.isBefore(start.subtract(const Duration(hours: 1))) &&
        now.isBefore(until.isBefore(latest) ? until : latest);
  }

  return [
    for (final s in slots)
      if (s.type.isMatch &&
          s.parentId == null &&
          s.fromFederation &&
          hasKioskVideo(s) &&
          onAir(s))
        s,
  ]..sort((a, b) {
      final byDay = a.date.compareTo(b.date);
      return byDay != 0 ? byDay : a.startsAt.compareTo(b.startsAt);
    });
}

/// Whether the kiosk can play [slot]'s video: a YouTube one.
bool hasKioskVideo(PrioritySlot slot) =>
    youtubeVideoId(slot.videoUrl ?? '') != null;

/// What the kiosk's ▶ at [slot] says: live while it is being played (from
/// an hour before the start, as [isLive]), a recording once decided, the
/// video otherwise — a stream announced ahead.
String kioskStreamLabel(PrioritySlot slot, MatchResult? result, DateTime now) =>
    isLive(slot, result, now)
    ? 'Sledovat živě'
    : _decided(result)
    ? 'Přehrát záznam'
    : 'Pustit video';

/// The streams the kiosk shows (0066, 0072): [live] — the matches on air
/// the window opens by itself ([kioskStreamMatches], when the admin lets
/// it) — less the [closed] ones, then those a visitor [opened], in the
/// order they did; a stream opened by hand that is also live counts once,
/// as opened. Slots gone or without a video drop out. One window ([max]
/// 1) turns through them all; with more, each stream has its own and
/// there are never more than [max]: what visitors opened comes first (the
/// latest [max] of it), the live ones take the windows left.
List<PrioritySlot> kioskVisibleStreams({
  required List<PrioritySlot> slots,
  required List<PrioritySlot> live,
  required List<String> opened,
  required Set<String> closed,
  required int max,
}) {
  final byId = {for (final s in slots) s.id: s};
  final manual = [
    for (final id in opened) ?byId[id],
  ].where(hasKioskVideo).toList();
  final auto = [
    for (final s in live)
      if (!closed.contains(s.id) && !opened.contains(s.id)) s,
  ];
  if (max <= 1) return [...auto, ...manual];
  final kept = manual.length > max
      ? manual.sublist(manual.length - max)
      : manual;
  return [...auto.take(max - kept.length), ...kept];
}

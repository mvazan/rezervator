/// The kiosk's side panel, the pure half: which notices are up and which
/// matches it lists. Pure Dart, unit-tested; `KioskInfoPanel` only renders it.
library;

import 'messages.dart' show splitNotices;
import 'models.dart';

/// The notices on the wall right now: kind notice, not expired, not hidden
/// from the kiosk by the admin, oldest posted first (the Nástěnka order).
List<Message> kioskNotices(Iterable<Message> messages, DateTime now) =>
    splitNotices(
      messages.where((m) => m.kind == MessageKind.notice && m.showOnKiosk),
      now,
    ).active;

bool _decided(MatchResult? r) =>
    r?.status == MatchStatus.finished || r?.status == MatchStatus.forfeit;

/// The alley's federation matches for the panel: [next] is the first match
/// not decided yet that is today or later (a match in progress counts —
/// it is "now"), [recent] the decided ones of the last [historyDays] days up
/// to today, oldest first (chronological, like every list in the app).
/// [historyDays] 0 lists none.
({PrioritySlot? next, List<PrioritySlot> recent}) kioskMatches({
  required List<PrioritySlot> slots,
  required Map<String, MatchResult> results,
  required Day today,
  required int historyDays,
}) {
  final matches =
      [
        for (final s in slots)
          if (s.type.isMatch && s.parentId == null && s.fromFederation) s,
      ]..sort((a, b) {
        final byDay = a.date.compareTo(b.date);
        return byDay != 0 ? byDay : a.startsAt.compareTo(b.startsAt);
      });
  PrioritySlot? next;
  for (final s in matches) {
    if (!s.date.isBefore(today) && !_decided(results[s.id])) {
      next = s;
      break;
    }
  }
  final since = today.addDays(-historyDays);
  final recent = [
    for (final s in matches)
      if (historyDays > 0 &&
          !s.date.isBefore(since) &&
          !s.date.isAfter(today) &&
          _decided(results[s.id]))
        s,
  ];
  return (next: next, recent: recent);
}

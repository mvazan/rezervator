/// The kiosk's side panel, the pure half: which notices are up and which
/// matches it lists. Pure Dart, unit-tested; `KioskInfoPanel` only renders it.
library;

import 'messages.dart' show splitNotices;
import 'models.dart';

/// How many finished matches the panel lists.
const kioskRecentMatches = 3;

/// The notices on the wall right now: kind notice, not expired, oldest
/// posted first (the Nástěnka order).
List<Message> kioskNotices(Iterable<Message> messages, DateTime now) =>
    splitNotices(
      messages.where((m) => m.kind == MessageKind.notice),
      now,
    ).active;

bool _decided(MatchResult? r) =>
    r?.status == MatchStatus.finished || r?.status == MatchStatus.forfeit;

/// The alley's federation matches for the panel: [next] is the first match
/// not decided yet that is today or later (a match in progress counts —
/// it is "now"), [recent] the last [kioskRecentMatches] decided ones up to
/// today, oldest first (chronological, like every list in the app).
({PrioritySlot? next, List<PrioritySlot> recent}) kioskMatches({
  required List<PrioritySlot> slots,
  required Map<String, MatchResult> results,
  required Day today,
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
  final decided = [
    for (final s in matches)
      if (!s.date.isAfter(today) && _decided(results[s.id])) s,
  ];
  final recent = decided.length > kioskRecentMatches
      ? decided.sublist(decided.length - kioskRecentMatches)
      : decided;
  return (next: next, recent: recent);
}

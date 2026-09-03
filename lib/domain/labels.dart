/// Event wording shared by the in-grid tiles and the off-block bands.
/// Pure Dart — widgets only render these strings.
library;

import 'models.dart';
import 'schedule.dart';

/// '🏆 {title}' for matches, '⛔ {title}' for other blockages — the in-grid
/// and band wording (day headers keep headerEventLabel's 🏠/none/⛔).
String slotEventLabel(PrioritySlot m) =>
    '${m.type.isMatch ? '🏆' : '⛔'} ${m.title}';

/// '🔒 {renterName}', plus ' (výjimka)' for an occurrence an exception row
/// reshaped (fewer lanes / other times than the series).
String rentalLabel(Rental r) =>
    '🔒 ${r.renterName}${r.isOverridden ? ' (výjimka)' : ''}';

/// What an exception row changes against its series: 'vynecháno', else the
/// differing parts ('dráhy 1, 2', '17:00–18:00') joined by ' · ', or
/// 'beze změny' when nothing differs.
String rentalExceptionSummary(Rental parent, Rental child) {
  if (child.skipped) return 'vynecháno';
  final parts = [
    if (!_sameLanes(parent.lanes, child.lanes))
      'dráhy ${child.lanes.join(', ')}',
    if (child.startsAt != parent.startsAt || child.endsAt != parent.endsAt)
      '${child.startsAt.display()}–${child.endsAt.display()}',
  ];
  return parts.isEmpty ? 'beze změny' : parts.join(' · ');
}

bool _sameLanes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Czech plural: '1 výjimka' / '2–4 výjimky' / '5+ výjimek'.
String rentalExceptionCountLabel(int n) {
  if (n == 1) return '1 výjimka';
  if (n >= 2 && n <= 4) return '$n výjimky';
  return '$n výjimek';
}

/// Band text: the label above + ' · od–do' using HourMinute.display().
String eventBandLabel(OffBlockEvent e) {
  final label = switch (e) {
    OffBlockPriority(:final slot) => slotEventLabel(slot),
    OffBlockRental(:final rental) => rentalLabel(rental),
  };
  return '$label · ${e.start.display()}–${e.end.display()}';
}

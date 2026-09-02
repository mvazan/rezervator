/// Event wording shared by the in-grid tiles and the off-block bands.
/// Pure Dart — widgets only render these strings.
library;

import 'models.dart';
import 'schedule.dart';

/// '🏆 {title}' for matches, '⛔ {title}' for other blockages — the in-grid
/// and band wording (day headers keep headerEventLabel's 🏠/none/⛔).
String slotEventLabel(PrioritySlot m) =>
    '${m.type.isMatch ? '🏆' : '⛔'} ${m.title}';

/// '🔒 {renterName}'.
String rentalLabel(Rental r) => '🔒 ${r.renterName}';

/// Band text: the label above + ' · od–do' using HourMinute.display().
String eventBandLabel(OffBlockEvent e) {
  final label = switch (e) {
    OffBlockPriority(:final slot) => slotEventLabel(slot),
    OffBlockRental(:final rental) => rentalLabel(rental),
  };
  return '$label · ${e.start.display()}–${e.end.display()}';
}

/// Nepravidelné pronájmy jako skupiny: jeden nájemce, víc jednorázových
/// termínů (0041). Čistý Dart — seskupení i řazení žije tady, ne ve
/// widgetech.
library;

import 'collation.dart';
import 'models.dart';

/// One renter's one-time dates. [id] is the rental_groups row, or null for
/// a lone one-time rental — the UI treats both the same way; the group
/// appears server-side with the second date (rental_add_date).
class RentalGroup {
  const RentalGroup({
    required this.id,
    required this.renterName,
    required this.color,
    required this.dates,
  });

  final String? id;
  final String renterName;
  final int color;

  /// Chronological, never empty; every row has [Rental.date].
  final List<Rental> dates;

  /// The first date on or after [today], null when all are past.
  Day? nextDate(Day today) {
    for (final d in dates) {
      if (!d.date!.isBefore(today)) return d.date;
    }
    return null;
  }
}

/// Groups the one-time rows of [rentals] — by `group_id`, a lone row as a
/// group of one — and skips weekly series and exception rows. Groups sort
/// by their next upcoming date; those with nothing ahead go last, the most
/// recently ended first; ties by renter name (Czech collation).
List<RentalGroup> rentalGroupsOf(List<Rental> rentals, {required Day today}) {
  final byGroup = <String, List<Rental>>{};
  final lone = <Rental>[];
  for (final r in rentals) {
    if (r.parentId != null || r.date == null) continue;
    final g = r.groupId;
    if (g == null) {
      lone.add(r);
    } else {
      (byGroup[g] ??= []).add(r);
    }
  }
  int byDate(Rental a, Rental b) {
    final c = a.date!.compareTo(b.date!);
    return c != 0 ? c : a.startsAt.compareTo(b.startsAt);
  }
  final groups = [
    for (final e in byGroup.entries)
      RentalGroup(
        id: e.key,
        renterName: e.value.first.renterName,
        color: e.value.first.color,
        dates: e.value..sort(byDate),
      ),
    for (final r in lone)
      RentalGroup(id: null, renterName: r.renterName, color: r.color, dates: [r]),
  ];
  groups.sort((a, b) {
    final na = a.nextDate(today);
    final nb = b.nextDate(today);
    if (na != null && nb != null) {
      final c = na.compareTo(nb);
      if (c != 0) return c;
    } else if (na != null) {
      return -1;
    } else if (nb != null) {
      return 1;
    } else {
      final c = b.dates.last.date!.compareTo(a.dates.last.date!);
      if (c != 0) return c;
    }
    return compareCzech(a.renterName, b.renterName);
  });
  return groups;
}

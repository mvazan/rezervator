import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/models.dart';
import '../../../domain/rental_groups.dart';
import 'rental_date_dialog.dart';

/// The dates of one nepravidelný pronájem — each opening [RentalDateDialog]
/// to edit, a delete per row and Přidat termín for a new one. Watches the
/// rentals stream itself, so the list follows adds and deletes made from
/// the dialogs it opens while it stays up — including the moment a lone
/// rental gains its group: the group is re-found by the rows it was opened
/// with, not by an id it may not have had yet.
class RentalDatesDialog extends ConsumerWidget {
  const RentalDatesDialog({
    super.key,
    required this.group,
    required this.laneCount,
  });

  final RentalGroup group;
  final int laneCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rentalsAsync = ref.watch(rentalsProvider);
    final rentals = rentalsAsync.value ?? const <Rental>[];
    final now = today();
    // Re-found on every emission: by the group id when the snapshot already
    // had one, otherwise by ANY row it was opened with. Anchoring on a single
    // row would lose the group the moment that row is deleted from this very
    // list — the fallback would then serve the stale snapshot and the deleted
    // date would sit there, tappable and falsely saveable.
    final openedIds = {for (final d in group.dates) d.id};
    final live = rentalGroupsOf(rentals, today: now)
            .where((g) =>
                (g.id != null && g.id == group.id) ||
                g.dates.any((d) => openedIds.contains(d.id)))
            .firstOrNull;

    // Every date gone: the last delete took the group with it (the 0041
    // prune trigger). Serving the snapshot here would list a date that no
    // longer exists — tappable, and saveable into a zero-row update that
    // reports success. Only trust the absence once the stream actually has
    // data; without a value we cannot tell "deleted" from "not loaded yet".
    if (live == null && rentalsAsync.hasValue) {
      return AlertDialog(
        title: Text('Termíny · ${group.renterName}'),
        content: const Text('Tenhle pronájem už nemá žádné termíny.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Zavřít'),
          ),
        ],
      );
    }
    final shown = live ?? group;

    return AlertDialog(
      title: Text('Termíny · ${shown.renterName}'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final d in shown.dates) _tile(context, shown, d, now),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Zavřít'),
        ),
        FilledButton.icon(
          onPressed: () => showDialog<bool>(
            context: context,
            builder: (_) => RentalDateDialog(
              anchor: shown.dates.last,
              laneCount: laneCount,
            ),
          ),
          icon: const Icon(Icons.add),
          label: const Text('Přidat termín'),
        ),
      ],
    );
  }

  Widget _tile(BuildContext context, RentalGroup live, Rental d, Day now) {
    final date = d.date!;
    // A date that has passed stays on the list for the record; there is
    // nothing left to change about it.
    final past = date.isBefore(now);
    final parts = [
      '${d.startsAt.display()}–${d.endsAt.display()}',
      'dráhy ${d.lanes.join(', ')}',
      if (d.note.isNotEmpty) d.note,
    ];
    return ListTile(
      enabled: !past,
      contentPadding: EdgeInsets.zero,
      title: Text(dayFull(date)),
      subtitle: Text(parts.join(' · ')),
      onTap: () => showDialog<bool>(
        context: context,
        builder: (_) => RentalDateDialog(
          anchor: live.dates.last,
          existing: d,
          laneCount: laneCount,
        ),
      ),
      trailing: past
          ? null
          : IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Smazat termín',
              onPressed: () => confirmDelete(
                context,
                title: 'Smazat termín?',
                message: '${dayFull(date)} · ${live.renterName}: dráhy se '
                    'uvolní. Je-li to poslední termín, zmizí celý pronájem.',
                action: () => Api.deleteRental(d.id),
                success: 'Termín smazán.',
              ),
            ),
    );
  }
}

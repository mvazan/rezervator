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
/// rental gains its group: the group is re-found by its id OR by any row
/// this dialog has seen, and it LEARNS — every emission hands it the id it
/// may not have had at open time and the rows added since.
class RentalDatesDialog extends ConsumerStatefulWidget {
  const RentalDatesDialog({
    super.key,
    required this.group,
    required this.laneCount,
  });

  final RentalGroup group;
  final int laneCount;

  @override
  ConsumerState<RentalDatesDialog> createState() => _RentalDatesDialogState();
}

class _RentalDatesDialogState extends ConsumerState<RentalDatesDialog> {
  /// The group id as far as this dialog knows it — null while it was opened
  /// on a lone one-time rental, filled in the moment the server gives that
  /// rental a group (rental_add_date).
  String? _groupId;

  /// Every row id this dialog has ever seen in its group. Opened ids alone
  /// are not enough: a lone rental opened with {R} that gains a group {R, N}
  /// and then loses R would be unfindable — id still null, and N never among
  /// the ids it started with.
  final Set<String> _knownIds = {};

  @override
  void initState() {
    super.initState();
    _groupId = widget.group.id;
    _knownIds.addAll(widget.group.dates.map((d) => d.id));
  }

  @override
  Widget build(BuildContext context) {
    final rentalsAsync = ref.watch(rentalsProvider);
    final rentals = rentalsAsync.value ?? const <Rental>[];
    final now = today();
    // Re-found on every emission: by the group id once one is known,
    // otherwise by ANY row this dialog has seen. Anchoring on a single row
    // would lose the group the moment that row is deleted from this very
    // list — the fallback would then serve the stale snapshot and the deleted
    // date would sit there, tappable and falsely saveable.
    final live = rentalGroupsOf(rentals, today: now)
            .where((g) =>
                (_groupId != null && g.id == _groupId) ||
                g.dates.any((d) => _knownIds.contains(d.id)))
            .firstOrNull;
    if (live != null) {
      // Absorb what this emission taught us, so the next lookup can find the
      // group by id and by rows added since. Plain field writes: they change
      // nothing on screen now, only what the NEXT build matches on.
      _groupId = live.id ?? _groupId;
      _knownIds.addAll(live.dates.map((d) => d.id));
    }

    // Every date gone: the last delete took the group with it (the 0041
    // prune trigger). Serving the snapshot here would list a date that no
    // longer exists — tappable, and saveable into a zero-row update that
    // reports success. Only trust the absence once the stream actually has
    // data; without a value we cannot tell "deleted" from "not loaded yet".
    if (live == null && rentalsAsync.hasValue) {
      return AlertDialog(
        title: Text('Termíny · ${widget.group.renterName}'),
        content: const Text('Tenhle pronájem už nemá žádné termíny.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Zavřít'),
          ),
        ],
      );
    }
    final shown = live ?? widget.group;

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
              laneCount: widget.laneCount,
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
          laneCount: widget.laneCount,
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

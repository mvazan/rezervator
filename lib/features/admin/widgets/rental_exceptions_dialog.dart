import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ui.dart';
import '../../../data/providers.dart';
import '../../../domain/labels.dart';
import '../../../domain/models.dart';
import 'rental_occurrence_dialog.dart';

/// The exception rows of one weekly rental — the dates it skips or plays on
/// other lanes / at other times — each opening [RentalOccurrenceDialog] to
/// edit, with a delete per row and Přidat výjimku for a new date. Watches
/// the rentals stream itself, so the list follows the adds and deletes
/// made from the dialogs it opens while it stays up.
class RentalExceptionsDialog extends ConsumerWidget {
  const RentalExceptionsDialog({
    super.key,
    required this.parent,
    required this.laneCount,
  });

  /// The weekly series.
  final Rental parent;
  final int laneCount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rentals = ref.watch(rentalsProvider).value ?? const <Rental>[];
    // The series as the stream has it now (its lanes or times may have been
    // edited meanwhile, and the summaries compare against them); the row
    // the caller passed until the stream delivers.
    final parent =
        rentals.where((r) => r.id == this.parent.id).firstOrNull ?? this.parent;
    final children = rentals
        .where((r) => r.parentId == parent.id && r.date != null)
        .toList()
      ..sort((a, b) => a.date!.compareTo(b.date!));
    final now = today();

    return AlertDialog(
      title: Text('Výjimky · ${parent.renterName}'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (children.isEmpty)
                const Text('Zatím žádné výjimky.')
              else
                for (final child in children)
                  _tile(context, parent: parent, child: child, today: now),
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
            builder: (_) => RentalOccurrenceDialog(
              parent: parent,
              laneCount: laneCount,
              takenDates: {for (final c in children) c.date!},
            ),
          ),
          icon: const Icon(Icons.add),
          label: const Text('Přidat výjimku'),
        ),
      ],
    );
  }

  Widget _tile(
    BuildContext context, {
    required Rental parent,
    required Rental child,
    required Day today,
  }) {
    final date = child.date!;
    // A date that has passed stays on the list for the record, but there is
    // nothing left to edit or undo about it.
    final past = date.isBefore(today);
    return ListTile(
      enabled: !past,
      contentPadding: EdgeInsets.zero,
      title: Text(dayFull(date)),
      subtitle: Text(rentalExceptionSummary(parent, child)),
      onTap: () => showDialog<bool>(
        context: context,
        builder: (_) => RentalOccurrenceDialog(
          parent: parent,
          date: date,
          existing: child,
          laneCount: laneCount,
        ),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: 'Zrušit výjimku',
        onPressed: past
            ? null
            : () => confirmDeleteRentalException(
                  context,
                  parent: parent,
                  child: child,
                ),
      ),
    );
  }
}

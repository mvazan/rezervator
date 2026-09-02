import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/labels.dart' show rentalExceptionCountLabel;
import '../../domain/models.dart';
import 'widgets/admin_scaffold.dart';
import 'widgets/rental_dialog.dart';
import 'widgets/rental_exceptions_dialog.dart';

/// One-time rentals first (sorted by date, ascending), then weekly rentals
/// (sorted by weekday, Monday..Sunday). Exception rows never get here.
int _compareRentals(Rental a, Rental b) {
  final aDate = a.date;
  final bDate = b.date;
  if (aDate != null && bDate != null) return aDate.compareTo(bDate);
  if (aDate != null) return -1;
  if (bDate != null) return 1;
  return a.weekday!.compareTo(b.weekday!);
}

/// Admin: manage lane rentals (one-time or weekly-recurring) that block
/// reservations for the rented lanes/time. A weekly rental's exception rows
/// are not listed on their own: the series counts them in its subtitle and
/// manages them in [RentalExceptionsDialog].
class RentalsScreen extends ConsumerWidget {
  const RentalsScreen({super.key});

  Future<void> _delete(BuildContext context, Rental rental) => confirmDelete(
        context,
        title: 'Smazat pronájem?',
        message: 'Opravdu smazat pronájem pro ${rental.renterName}?',
        action: () => Api.deleteRental(rental.id),
      );

  /// [exceptions]: how many exception rows hang under this weekly rental.
  String _subtitle(Rental rental, {required int exceptions}) {
    final lines = <String>[];
    final date = rental.date;
    if (date != null) {
      lines.add('jednorázově ${dayLabel(date)}');
    } else {
      lines.add(
        'každý ${weekdayFull(rental.weekday!)} '
        '${rental.startsAt.display()}–${rental.endsAt.display()}',
      );
    }
    lines.add('dráhy ${rental.lanes.join(', ')}');
    final validFrom = rental.validFrom;
    final validUntil = rental.validUntil;
    if (validFrom != null && validUntil != null) {
      lines.add('platí ${rangeLabel(validFrom, validUntil)}');
    } else if (validFrom != null) {
      lines.add('platí od ${dayLabel(validFrom)}');
    } else if (validUntil != null) {
      lines.add('platí do ${dayLabel(validUntil)}');
    }
    var subtitle = lines.join('\n');
    if (rental.note.isNotEmpty) subtitle += ' · ${rental.note}';
    if (exceptions > 0) {
      subtitle += '\n${rentalExceptionCountLabel(exceptions)}';
    }
    return subtitle;
  }

  Widget _tile(
    BuildContext context,
    Rental rental, {
    required int exceptions,
    required int laneCount,
  }) {
    return ListTile(
      title: Text(rental.renterName),
      subtitle: Text(_subtitle(rental, exceptions: exceptions)),
      isThreeLine: rental.validFrom != null ||
          rental.validUntil != null ||
          exceptions > 0,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (rental.isSeries)
            IconButton(
              icon: const Icon(Icons.edit_calendar_outlined),
              tooltip: 'Výjimky',
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => RentalExceptionsDialog(
                  parent: rental,
                  laneCount: laneCount,
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => RentalDialog(
                existing: rental,
                laneCount: laneCount,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _delete(context, rental),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final laneCount = ref.watch(settingsProvider).value?.laneCount ??
        ScheduleSettings.defaults.laneCount;

    return AdminScaffold(
      title: 'Pronájmy',
      body: AsyncBody(
        value: ref.watch(rentalsProvider),
        onRetry: () => ref.invalidate(rentalsProvider),
        builder: (rentals) {
          // Exception rows arrive on the same stream as their series:
          // counted per series here, never listed as rentals of their own.
          final listed = <Rental>[];
          final exceptions = <String, int>{};
          for (final rental in rentals) {
            final parentId = rental.parentId;
            if (parentId == null) {
              listed.add(rental);
            } else {
              exceptions[parentId] = (exceptions[parentId] ?? 0) + 1;
            }
          }
          listed.sort(_compareRentals);
          if (listed.isEmpty) {
            return const Center(child: Text('Zatím žádné pronájmy.'));
          }
          return ListView(
            children: [
              for (final rental in listed)
                _tile(
                  context,
                  rental,
                  exceptions: exceptions[rental.id] ?? 0,
                  laneCount: laneCount,
                ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showDialog<void>(
          context: context,
          builder: (_) => RentalDialog(laneCount: laneCount),
        ),
        icon: const Icon(Icons.add),
        label: const Text('Přidat pronájem'),
      ),
    );
  }
}

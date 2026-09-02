import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import 'widgets/admin_scaffold.dart';
import 'widgets/rental_dialog.dart';

/// One-time rentals first (sorted by date, ascending), then weekly rentals
/// (sorted by weekday, Monday..Sunday).
int _compareRentals(Rental a, Rental b) {
  final aDate = a.date;
  final bDate = b.date;
  if (aDate != null && bDate != null) return aDate.compareTo(bDate);
  if (aDate != null) return -1;
  if (bDate != null) return 1;
  return a.weekday!.compareTo(b.weekday!);
}

/// Admin: manage lane rentals (one-time or weekly-recurring) that block
/// reservations for the rented lanes/time.
class RentalsScreen extends ConsumerWidget {
  const RentalsScreen({super.key});

  Future<void> _delete(BuildContext context, Rental rental) => confirmDelete(
        context,
        title: 'Smazat pronájem?',
        message: 'Opravdu smazat pronájem pro ${rental.renterName}?',
        action: () => Api.deleteRental(rental.id),
      );

  String _subtitle(Rental rental) {
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
    return subtitle;
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
          final sorted = [...rentals]..sort(_compareRentals);
          if (sorted.isEmpty) {
            return const Center(child: Text('Zatím žádné pronájmy.'));
          }
          return ListView(
            children: [
              for (final rental in sorted)
                ListTile(
                  title: Text(rental.renterName),
                  subtitle: Text(_subtitle(rental)),
                  isThreeLine:
                      rental.validFrom != null || rental.validUntil != null,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
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

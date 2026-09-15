import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/collation.dart';
import '../../domain/labels.dart'
    show rentalDateCountLabel, rentalExceptionCountLabel, rentalMoreDatesLabel;
import '../../domain/models.dart';
import '../../domain/rental_groups.dart';
import 'widgets/admin_scaffold.dart';
import 'widgets/rental_dates_dialog.dart';
import 'widgets/rental_dialog.dart';
import 'widgets/rental_exceptions_dialog.dart';
import 'widgets/rental_group_dialog.dart';

/// Weekly series by weekday (Monday..Sunday), then start time, then renter.
int _compareSeries(Rental a, Rental b) {
  final byWeekday = a.weekday!.compareTo(b.weekday!);
  if (byWeekday != 0) return byWeekday;
  final byStart = a.startsAt.compareTo(b.startsAt);
  return byStart != 0 ? byStart : compareCzech(a.renterName, b.renterName);
}

/// Admin: manage lane rentals that block reservations for the rented
/// lanes/time. Two sections, because the two are different animals: a
/// pravidelný pronájem is a weekly rule (its exception rows are not listed
/// on their own — the series counts them and manages them in
/// [RentalExceptionsDialog]), a nepravidelný pronájem is one renter's list
/// of dates ([RentalGroup]), each with its own time and lanes.
class RentalsScreen extends ConsumerWidget {
  const RentalsScreen({super.key});

  Future<void> _delete(BuildContext context, Rental rental) => confirmDelete(
        context,
        title: 'Smazat pronájem?',
        message: 'Opravdu smazat pronájem pro ${rental.renterName}?',
        action: () => Api.deleteRental(rental.id),
      );

  Future<void> _deleteGroup(BuildContext context, RentalGroup group) {
    final n = group.dates.length;
    final id = group.id;
    return confirmDelete(
      context,
      title: 'Smazat pronájem?',
      message: n == 1
          ? 'Opravdu smazat pronájem pro ${group.renterName}?'
          : 'Opravdu smazat pronájem pro ${group.renterName} včetně '
              '${rentalDateCountLabel(n)}?',
      action: () => id != null
          ? Api.deleteRentalGroup(id)
          : Api.deleteRental(group.dates.single.id),
    );
  }

  /// [exceptions]: how many exception rows hang under this weekly rental.
  String _subtitle(Rental rental, {required int exceptions}) {
    final lines = <String>[];
    lines.add(
      'každý ${weekdayFull(rental.weekday!)} '
      '${rental.startsAt.display()}–${rental.endsAt.display()}',
    );
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

  Widget _seriesTile(
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
            tooltip: 'Smazat',
            onPressed: () => _delete(context, rental),
          ),
        ],
      ),
    );
  }

  String _groupSubtitle(RentalGroup group) {
    String line(Rental d) {
      final parts = [
        dayLabel(d.date!),
        '${d.startsAt.display()}–${d.endsAt.display()}',
        'dráhy ${d.lanes.join(', ')}',
        if (d.note.isNotEmpty) d.note,
      ];
      return parts.join(' · ');
    }

    final shown = group.dates.take(2).map(line).toList();
    final rest = group.dates.length - shown.length;
    if (rest > 0) shown.add(rentalMoreDatesLabel(rest));
    return shown.join('\n');
  }

  Widget _groupTile(BuildContext context, RentalGroup group,
      {required int laneCount}) {
    return ListTile(
      title: Text(group.renterName),
      subtitle: Text(_groupSubtitle(group)),
      isThreeLine: group.dates.length > 1,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.event_note_outlined),
            tooltip: 'Termíny',
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) =>
                  RentalDatesDialog(group: group, laneCount: laneCount),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'Upravit',
            onPressed: () => showDialog<bool>(
              context: context,
              builder: (_) => RentalGroupDialog(group: group),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Smazat',
            onPressed: () => _deleteGroup(context, group),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      );

  /// Which kind to add — a series is a rule, a group is a list; the two
  /// forms share almost nothing, so the choice comes first.
  Future<void> _add(BuildContext context, int laneCount) async {
    final kind = await showModalBottomSheet<RentalKind>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.repeat),
              title: const Text('Pravidelný'),
              subtitle: const Text('Každý týden ve stejný den a čas.'),
              onTap: () => Navigator.of(sheetContext).pop(RentalKind.weekly),
            ),
            ListTile(
              leading: const Icon(Icons.event_note_outlined),
              title: const Text('Nepravidelný'),
              subtitle: const Text(
                  'Jeden nájemce, libovolné termíny — každý s vlastním časem a drahami.'),
              onTap: () => Navigator.of(sheetContext).pop(RentalKind.irregular),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (kind == null || !context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => RentalDialog(kind: kind, laneCount: laneCount),
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
          final series = <Rental>[];
          final exceptions = <String, int>{};
          for (final rental in rentals) {
            final parentId = rental.parentId;
            if (parentId != null) {
              exceptions[parentId] = (exceptions[parentId] ?? 0) + 1;
            } else if (rental.weekday != null) {
              series.add(rental);
            }
          }
          series.sort(_compareSeries);
          final groups = rentalGroupsOf(rentals, today: today());
          if (series.isEmpty && groups.isEmpty) {
            return const Center(child: Text('Zatím žádné pronájmy.'));
          }
          return ListView(
            children: [
              if (series.isNotEmpty) _header(context, 'Pravidelné'),
              for (final rental in series)
                _seriesTile(
                  context,
                  rental,
                  exceptions: exceptions[rental.id] ?? 0,
                  laneCount: laneCount,
                ),
              if (groups.isNotEmpty) _header(context, 'Nepravidelné'),
              for (final group in groups)
                _groupTile(context, group, laneCount: laneCount),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _add(context, laneCount),
        icon: const Icon(Icons.add),
        label: const Text('Přidat pronájem'),
      ),
    );
  }
}

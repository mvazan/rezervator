import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/day_edit.dart';
import '../../domain/grouping.dart';
import '../../domain/labels.dart';
import '../../domain/models.dart';
import 'slot_types_screen.dart';
import 'widgets/admin_scaffold.dart';
import 'widgets/blockage_dialog.dart';
import 'widgets/override_dialog.dart';
import 'widgets/rental_occurrence_dialog.dart';

/// Admin: manage per-day closures that take precedence over the weekly
/// training-day rule. An override closes a day with a reason (e.g. "Malování
/// drah"); the schedule then shows it as closed and cancels colliding
/// reservations.
class OverridesScreen extends ConsumerWidget {
  const OverridesScreen({super.key});

  Future<void> _deleteRun(BuildContext context, List<DayOverride> run) =>
      confirmDelete(
        context,
        title: 'Smazat výjimku?',
        message: run.length == 1
            ? 'Den se vrátí k týdennímu pravidlu.'
            : '${run.length} dní se vrátí k týdennímu pravidlu.',
        action: () async {
          for (final o in run) {
            await Api.deleteDayOverride(o.date);
          }
        },
      );

  Future<void> _deleteBlockage(BuildContext context, PrioritySlot slot) =>
      confirmDelete(
        context,
        title: 'Smazat blokaci?',
        message: 'Opravdu smazat „${slot.title}" (${dayLabel(slot.date)})?',
        action: () => Api.deletePrioritySlot(slot.id),
      );

  /// Returns a schedule-fork day to the weekly rules. A training day goes
  /// back to the template blocks; a NON-training day closes again (every
  /// reservation that date cancels, closed write FIRST so a failure between
  /// the two calls can't leave the day wide open).
  Future<void> _restore(BuildContext context, DayOverride override,
      List<TimeBlock> blocks, ScheduleSettings settings) async {
    final isTraining =
        settings.trainingWeekdays.contains(override.date.weekday);
    final plan = planRestoreTemplate(
      date: override.date,
      isTraining: isTraining,
      blocks: blocks,
      rows: await Api.futureLiveReservations(today()),
    );
    if (!context.mounted) return;
    final templateIds = plan.templateIds;
    final losing = plan.cancellations;
    final confirmed = await confirmDialog(
      context,
      title: 'Vrátit den k týdennímu rozvrhu?',
      message: losing == 0
          ? (isTraining
              ? 'Jednodenní změna rozvrhu se zruší.'
              : 'Jednodenní změna se zruší a den bude zase zavřený.')
          : (isTraining
              ? 'Jednodenní změna se zruší a $losing rezervací mimo týdenní '
                  'bloky bude zrušeno („změna rozvrhu").'
              : 'Den bude zase zavřený a všech $losing rezervací bude '
                  'zrušeno („změna rozvrhu").'),
      confirmLabel: 'Vrátit',
    );
    if (!confirmed || !context.mounted) return;
    await tryAction(
      context,
      () => Api.restoreDayToTemplate(override.date,
          isTraining: isTraining, templateIds: templateIds),
      success: 'Den vrácen k týdennímu rozvrhu.',
      errorText: friendlyDbError,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overridesValue = ref.watch(dayOverridesProvider);
    final settings =
        ref.watch(settingsProvider).value ?? ScheduleSettings.defaults;
    final blocks = ref.watch(timeBlocksProvider).value ?? const <TimeBlock>[];
    final blockById = {for (final b in blocks) b.id: b};
    final slots = ref.watch(prioritySlotsProvider);
    final types = ref.watch(slotTypesProvider).value ?? const [];
    // Blokace: every non-match priority slot the admin manages by hand —
    // úklid children (parentId set) live and die with their match.
    final blockages = [
      for (final s in slots)
        if (!s.type.isMatch && s.parentId == null) s,
    ];
    final now = today();
    // Upcoming first (ascending); past collapsed at the bottom (most recent
    // first), so the default view is only what still matters.
    final upcomingBlockages =
        blockages.where((s) => !s.date.isBefore(now)).toList()
          ..sort((a, b) =>
              compareDayTime(a.date, a.startsAt, b.date, b.startsAt));
    final pastBlockages = blockages.where((s) => s.date.isBefore(now)).toList()
      ..sort((a, b) => compareDayTime(b.date, b.startsAt, a.date, a.startsAt));
    // Pronájmy: exception rows of weekly rentals (one occurrence skipped or
    // on other lanes/times) — orphans whose series is gone are not listed.
    final rentals = ref.watch(rentalsProvider).value ?? const <Rental>[];
    final seriesById = {
      for (final r in rentals)
        if (r.parentId == null) r.id: r,
    };
    final rentalExceptions = [
      for (final r in rentals)
        if (r.parentId != null &&
            seriesById.containsKey(r.parentId) &&
            r.date != null)
          r,
    ];
    final upcomingRentalExceptions =
        rentalExceptions.where((r) => !r.date!.isBefore(now)).toList()
          ..sort((a, b) =>
              compareDayTime(a.date!, a.startsAt, b.date!, b.startsAt));
    final pastRentalExceptions =
        rentalExceptions.where((r) => r.date!.isBefore(now)).toList()
          ..sort((a, b) =>
              compareDayTime(b.date!, b.startsAt, a.date!, a.startsAt));

    return AdminScaffold(
      title: 'Výjimky dnů',
      body: AsyncBody(
        value: overridesValue,
        onRetry: () => ref.invalidate(dayOverridesProvider),
        builder: (overrides) {
          final closures = [
            for (final o in overrides)
              if (o.closed) o,
          ];
          // Day-scoped schedule changes made from the calendar (open
          // overrides with a block selection) — listed so the admin has one
          // tidy place to see and undo every one-day fork.
          final forks = [
            for (final o in overrides)
              if (!o.closed && o.blockIds != null) o,
          ];
          final upcoming = closures.where((o) => !o.date.isBefore(now)).toList()
            ..sort((a, b) => a.date.compareTo(b.date));
          final past = closures.where((o) => o.date.isBefore(now)).toList()
            ..sort((a, b) => b.date.compareTo(a.date));
          final upcomingForks =
              forks.where((o) => !o.date.isBefore(now)).toList()
                ..sort((a, b) => a.date.compareTo(b.date));
          final pastForks = forks.where((o) => o.date.isBefore(now)).toList()
            ..sort((a, b) => b.date.compareTo(a.date));

          if (closures.isEmpty &&
              forks.isEmpty &&
              blockages.isEmpty &&
              rentalExceptions.isEmpty) {
            return const Center(child: Text('Zatím žádné výjimky.'));
          }
          return ListView(
            children: [
              if (upcoming.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Žádné nadcházející výjimky.'),
                )
              else
                for (final run in closureRuns(upcoming))
                  _ClosureTile(
                      run: run, onDelete: () => _deleteRun(context, run)),
              if (past.isNotEmpty)
                ExpansionTile(
                  title: Text('Minulé (${past.length})'),
                  children: [
                    for (final run in closureRuns(past))
                      _ClosureTile(
                          run: run, onDelete: () => _deleteRun(context, run)),
                  ],
                ),
              if (forks.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 20, 16, 4),
                  child: Text(
                    'Jednodenní změny rozvrhu',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                for (final override in upcomingForks)
                  _ForkTile(
                    fork: override,
                    blockById: blockById,
                    onRestore: () =>
                        _restore(context, override, blocks, settings),
                  ),
                if (pastForks.isNotEmpty)
                  ExpansionTile(
                    title: Text('Minulé změny (${pastForks.length})'),
                    children: [
                      for (final override in pastForks)
                        _ForkTile(
                          fork: override,
                          blockById: blockById,
                          onRestore: null,
                        ),
                    ],
                  ),
              ],
              if (rentalExceptions.isNotEmpty) ...[
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 20, 16, 4),
                  child: Text(
                    'Pronájmy',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                for (final child in upcomingRentalExceptions)
                  _RentalExceptionTile(
                    parent: seriesById[child.parentId]!,
                    child: child,
                    laneCount: settings.laneCount,
                  ),
                if (pastRentalExceptions.isNotEmpty)
                  ExpansionTile(
                    title: Text('Minulé výjimky pronájmů '
                        '(${pastRentalExceptions.length})'),
                    children: [
                      for (final child in pastRentalExceptions)
                        _RentalExceptionTile(
                          parent: seriesById[child.parentId]!,
                          child: child,
                          laneCount: settings.laneCount,
                        ),
                    ],
                  ),
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 4, 0),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Blokace',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.tune),
                      tooltip: 'Typy blokací',
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const SlotTypesScreen()),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.add),
                      tooltip: 'Přidat blokaci',
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => BlockageDialog(types: types),
                      ),
                    ),
                  ],
                ),
              ),
              if (blockages.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Zatím žádné blokace.'),
                )
              else ...[
                for (final slot in upcomingBlockages)
                  _BlockageTile(
                    slot: slot,
                    types: types,
                    onDelete: () => _deleteBlockage(context, slot),
                  ),
                if (pastBlockages.isNotEmpty)
                  ExpansionTile(
                    title: Text('Minulé blokace (${pastBlockages.length})'),
                    children: [
                      for (final slot in pastBlockages)
                        _BlockageTile(
                          slot: slot,
                          types: types,
                          onDelete: () => _deleteBlockage(context, slot),
                        ),
                    ],
                  ),
              ],
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showDialog<void>(
          context: context,
          builder: (_) =>
              OverrideDialog(overrides: overridesValue.value ?? const []),
        ),
        icon: const Icon(Icons.add),
        label: const Text('Přidat výjimku'),
      ),
    );
  }
}

/// One range tile per closure run; deleting it removes every day of it.
class _ClosureTile extends StatelessWidget {
  const _ClosureTile({required this.run, required this.onDelete});

  final List<DayOverride> run;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(run.length == 1
          ? dayFull(run.first.date)
          : '${dayFull(run.first.date)} – ${dayFull(run.last.date)}'),
      subtitle: Text('Zavřeno — ${run.first.reason}'
          '${run.length > 1 ? ' (${run.length} dní)' : ''}'),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        onPressed: onDelete,
      ),
    );
  }
}

/// A one-day schedule fork: the blocks the day was given (specials marked
/// "jen tento den") and the undo back to the weekly rules.
class _ForkTile extends StatelessWidget {
  const _ForkTile({
    required this.fork,
    required this.blockById,
    required this.onRestore,
  });

  final DayOverride fork;
  final Map<String, TimeBlock> blockById;

  /// Null for a past day — nothing left to undo.
  final VoidCallback? onRestore;

  @override
  Widget build(BuildContext context) {
    final parts = [
      for (final id in fork.blockIds!)
        if (blockById[id] != null)
          blockById[id]!.position < 0
              ? '${blockById[id]!.label} (jen tento den)'
              : blockById[id]!.label,
    ];
    return ListTile(
      title: Text(dayFull(fork.date)),
      subtitle: Text(
        parts.isEmpty ? 'Žádné bloky (den zavřen)' : parts.join(' · '),
      ),
      trailing: onRestore == null
          ? null
          : IconButton(
              icon: const Icon(Icons.undo),
              tooltip: 'Vrátit den k týdennímu rozvrhu',
              onPressed: onRestore,
            ),
    );
  }
}

/// One exception to a weekly rental: the date and renter, what the day
/// changes against the series (or 'vynecháno'); tap edits it in the
/// [RentalOccurrenceDialog], the bin returns the date to the series.
class _RentalExceptionTile extends StatelessWidget {
  const _RentalExceptionTile({
    required this.parent,
    required this.child,
    required this.laneCount,
  });

  /// The weekly series [child] overrides for one date.
  final Rental parent;
  final Rental child;
  final int laneCount;

  @override
  Widget build(BuildContext context) {
    final date = child.date!;
    return ListTile(
      leading: const Icon(Icons.lock_outline),
      title: Text('${dayLabel(date)} · ${parent.renterName}'),
      subtitle: Text(rentalExceptionSummary(parent, child)),
      onTap: () => showDialog<void>(
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
        onPressed: () =>
            confirmDeleteRentalException(context, parent: parent, child: child),
      ),
    );
  }
}

/// A manual blockage (non-match priority slot): its window and type, edit
/// (the [BlockageDialog]) and delete.
class _BlockageTile extends StatelessWidget {
  const _BlockageTile({
    required this.slot,
    required this.types,
    required this.onDelete,
  });

  final PrioritySlot slot;
  final List<PrioritySlotType> types;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(
        '${dayLabel(slot.date)} · '
        '${slot.startsAt.display()}–${slot.endsAt.display()} · '
        '${slot.title}',
      ),
      subtitle: switch ([
        if (slot.type.lanes != null) 'dráhy ${slot.type.lanes!.join(', ')}',
        if (slot.description.isNotEmpty) slot.description,
      ].join(' · ')) {
        '' => null,
        final sub => Text(sub),
      },
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => BlockageDialog(existing: slot, types: types),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }
}

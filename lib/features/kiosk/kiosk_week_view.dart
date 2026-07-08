/// Kiosk week grid: same schedule pipeline as WeekScreen, but display-only
/// until a player is selected — then free cells book for THAT player.
/// No cancel affordance anywhere (kiosk performs exactly one action type).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import '../../domain/schedule.dart';

/// Scans forward from [today] (exclusive) up to [horizonDays] and returns the
/// first date that would render as an [OpenDay] — i.e. has a non-empty
/// resolved block list, whether via a day override or the default active
/// blocks on a training weekday. Matches/rentals/reservations don't affect
/// open/closed status (only which slots within an open day are free), so
/// they're passed empty here — cheap, and exactly the same override/weekday
/// resolution buildWeekSchedule already does for the live grid.
Day? nextTrainingDay({
  required Day today,
  required ScheduleSettings settings,
  required List<TimeBlock> blocks,
  required List<DayOverride> overrides,
  required int horizonDays,
}) {
  // One buildWeekSchedule call per Monday-aligned week, starting at today's
  // own Monday and stepping 7 days at a time. Consecutive mondays are always
  // exactly 7 days apart, so this can never leave a gap between windows —
  // stopping only once a week's Monday already lies beyond the horizon
  // (at that point every day in it does too, since day 0 of the week is
  // already out of range).
  final todayMonday = today.addDays(1 - today.weekday);
  for (var monday = todayMonday;
      monday.differenceInDays(today) <= horizonDays;
      monday = monday.addDays(7)) {
    final week = buildWeekSchedule(
      monday: monday,
      today: today,
      now: const HourMinute(0, 0),
      settings: settings,
      blocks: blocks,
      overrides: overrides,
      matches: const [],
      rentals: const [],
      reservations: const [],
    );
    for (final day in week.days) {
      if (!day.date.isAfter(today)) continue;
      if (day.date.differenceInDays(today) > horizonDays) continue;
      if (day is OpenDay) return day.date;
    }
  }
  return null;
}

class KioskWeekView extends ConsumerWidget {
  const KioskWeekView({
    super.key,
    required this.weekOffset,
    required this.onWeekOffsetChanged,
    required this.selected,
    required this.onBooked,
  });

  final int weekOffset;
  final ValueChanged<int> onWeekOffsetChanged;

  /// The currently selected player, or null when the grid is display-only.
  final PlayerName? selected;

  /// Called after a booking attempt completes (success or failure) so the
  /// shell can decide whether to keep the selection (it always does — kiosk
  /// supports multi-booking per player before the ✕ or idle timeout clears
  /// the selection).
  final VoidCallback onBooked;

  Day _monday(Day today) => today.addDays(1 - today.weekday + 7 * weekOffset);

  Future<void> _book(BuildContext context, WidgetRef ref, Day date,
      TimeBlock block, int lane, PlayerName player) async {
    final message =
        '${player.displayName} · ${dayFull(date)} · ${block.label} · Dráha $lane';
    final confirmed = await confirmDialog(
      context,
      title: 'Rezervovat termín?',
      message: message,
      confirmLabel: 'Rezervovat',
    );
    if (!confirmed || !context.mounted) return;
    await tryAction(
      context,
      () => Api.createReservation(
          playerId: player.id, date: date, blockId: block.id, lane: lane),
      success: 'Zarezervováno.',
      errorText: friendlyDbError,
    );
    onBooked();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nowDt = DateTime.now();
    final todayDay = Day.fromDateTime(nowDt);
    final now = HourMinute(nowDt.hour, nowDt.minute);
    final monday = _monday(todayDay);

    final settings =
        ref.watch(settingsProvider).value ?? ScheduleSettings.defaults;
    final timeBlocks = ref.watch(timeBlocksProvider);
    final overrides = ref.watch(dayOverridesProvider).value ?? const [];
    final matches = ref.watch(matchesProvider).value ?? const [];
    final rentals = ref.watch(rentalsProvider).value ?? const [];
    final weekReservations = ref.watch(weekReservationsProvider(monday));
    final players = ref.watch(playersProvider).value ?? const [];

    final header = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton(
            iconSize: 32,
            icon: const Icon(Icons.chevron_left),
            onPressed: () => onWeekOffsetChanged(weekOffset - 1),
          ),
          Expanded(
            child: Text(
              rangeLabel(monday, monday.addDays(6)),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          if (weekOffset != 0)
            TextButton(
              onPressed: () => onWeekOffsetChanged(0),
              child: const Text('dnes'),
            ),
          IconButton(
            iconSize: 32,
            icon: const Icon(Icons.chevron_right),
            onPressed: () => onWeekOffsetChanged(weekOffset + 1),
          ),
        ],
      ),
    );

    if (timeBlocks.isLoading) {
      return Column(
        children: [
          header,
          const Expanded(child: Center(child: CircularProgressIndicator())),
        ],
      );
    }

    if (timeBlocks.hasError) {
      return Column(
        children: [
          header,
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Rozvrh se nepodařilo načíst.'),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: () => ref.invalidate(timeBlocksProvider),
                    child: const Text('Zkusit znovu'),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    final dbBlocks = timeBlocks.value ?? const [];
    final blocksFromDb = dbBlocks.isNotEmpty;
    final blocks = blocksFromDb ? dbBlocks : defaultTimeBlocks();
    final reservations = weekReservations.value ?? const [];
    // Same reasoning as WeekScreen: cells stay inert while the placeholder
    // grid is shown or this week's reservation stream hasn't loaded — a
    // booking attempt against either would either hit unmapped placeholder
    // ids or race the RPC's own authoritative slot-taken check.
    final interactive = blocksFromDb && weekReservations.hasValue;

    final week = buildWeekSchedule(
      monday: monday,
      today: todayDay,
      now: now,
      settings: settings,
      blocks: blocks,
      overrides: overrides,
      matches: matches,
      rentals: rentals,
      reservations: reservations,
    );
    final nameById = {for (final p in players) p.id: p.displayName};

    return Column(
      children: [
        header,
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
            children: [
              for (final day in week.days)
                _KioskDaySection(
                  day: day,
                  nameById: nameById,
                  interactive: interactive,
                  selected: selected,
                  onBook: (date, block, lane) =>
                      _book(context, ref, date, block, lane, selected!),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _KioskDaySection extends StatelessWidget {
  const _KioskDaySection({
    required this.day,
    required this.nameById,
    required this.interactive,
    required this.selected,
    required this.onBook,
  });

  final DaySchedule day;
  final Map<String, String> nameById;
  final bool interactive;
  final PlayerName? selected;
  final void Function(Day, TimeBlock, int lane) onBook;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(dayFull(day.date),
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700)),
            for (final m in day.matches)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '🏆 ${m.opponent} · ${m.startsAt.display()}–${m.endsAt.display()}',
                  style: TextStyle(color: scheme.primary, fontSize: 14),
                ),
              ),
            const SizedBox(height: 8),
            switch (day) {
              ClosedDay(:final reason) => Text(
                  reason.isEmpty ? 'Zavřeno' : 'Zavřeno — $reason',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              OpenDay() => _grid(context, day as OpenDay),
            },
          ],
        ),
      ),
    );
  }

  Widget _grid(BuildContext context, OpenDay day) {
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const FixedColumnWidth(88),
        columnWidths: const {0: FixedColumnWidth(100)},
        border: TableBorder.all(
            color: scheme.outlineVariant.withValues(alpha: 0.5)),
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          TableRow(
            children: [
              const SizedBox.shrink(),
              for (var lane = 1; lane <= day.laneCount; lane++)
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text('Dráha $lane',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
            ],
          ),
          for (final block in day.blocks)
            TableRow(
              children: [
                Padding(
                  padding: const EdgeInsets.all(6),
                  child:
                      Text(block.label, style: const TextStyle(fontSize: 13)),
                ),
                for (var lane = 1; lane <= day.laneCount; lane++)
                  _KioskSlotCell(
                    state: day.slot(block.id, lane),
                    nameById: nameById,
                    interactive: interactive,
                    selected: selected,
                    onBook: () => onBook(day.date, block, lane),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _KioskSlotCell extends StatelessWidget {
  const _KioskSlotCell({
    required this.state,
    required this.nameById,
    required this.interactive,
    required this.selected,
    required this.onBook,
  });

  final SlotState state;
  final Map<String, String> nameById;
  final bool interactive;
  final PlayerName? selected;
  final VoidCallback onBook;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Kiosk cells are ≥ 56 px tall (spec: big touch targets on a tablet),
    // taller than WeekScreen's 44 px equivalents.
    const height = 56.0;

    switch (state) {
      case MatchSlot():
        return Container(
          height: height,
          color: scheme.errorContainer.withValues(alpha: 0.6),
          alignment: Alignment.center,
          child: Text('Zápas',
              style: TextStyle(fontSize: 12, color: scheme.onErrorContainer)),
        );
      case RentedSlot(:final rental):
        return Container(
          height: height,
          color: scheme.tertiaryContainer.withValues(alpha: 0.7),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            rental.renterName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: scheme.onTertiaryContainer),
          ),
        );
      case ReservedSlot(:final reservation):
        // Kiosk never cancels — no InkWell, no tap handler, regardless of
        // whose reservation this is or whether it's admin-cancellable.
        final name = nameById[reservation.playerId] ?? '?';
        return Container(
          height: height,
          color: scheme.surfaceContainerHighest,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        );
      case FreeSlot(:final inPast, :final beyondHorizon):
        final bookable =
            interactive && selected != null && !inPast && !beyondHorizon;
        if (!bookable) {
          // Free but not currently bookable (no player selected yet, or the
          // slot is out of range) still reads as "free" via a subtle outline
          // so the schedule communicates availability at a glance even
          // before anyone picks up the picker.
          return Container(
            height: height,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: 0.6)),
            ),
          );
        }
        return InkWell(
          onTap: onBook,
          child: Container(
            height: height,
            alignment: Alignment.center,
            color: scheme.primary.withValues(alpha: 0.9),
            child: const Icon(Icons.add, size: 28, color: Colors.white),
          ),
        );
    }
  }
}

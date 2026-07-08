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
import '../schedule/widgets/day_header.dart';
import '../schedule/widgets/slot_tile.dart';

/// True when [date] resolves as an [OpenDay] under exactly the resolution the
/// grid renders with (buildWeekSchedule): closed overrides and non-training
/// weekdays are closed, and an override's blockIds are filtered against the
/// real block set — an override whose ids no longer resolve to any existing
/// block is a ClosedDay, not open. Matches/rentals/reservations never affect
/// open-vs-closed status (only which slots within an open day are free), so
/// they're passed empty.
///
/// This is the ONLY day-type probe outside the grid itself — the status bar
/// and [nextTrainingDay] both go through it, so they can never disagree with
/// what the grid shows.
bool isDayOpen({
  required Day date,
  required Day today,
  required ScheduleSettings settings,
  required List<TimeBlock> blocks,
  required List<DayOverride> overrides,
}) {
  final week = buildWeekSchedule(
    monday: date.addDays(1 - date.weekday),
    today: today,
    now: const HourMinute(0, 0),
    settings: settings,
    blocks: blocks,
    overrides: overrides,
    matches: const [],
    rentals: const [],
    reservations: const [],
  );
  // WeekSchedule.days is contractually Monday..Sunday, so [weekday - 1] is
  // exactly [date]'s entry.
  return week.days[date.weekday - 1] is OpenDay;
}

/// Scans forward from [today] (exclusive) up to [horizonDays] and returns the
/// first date that resolves open per [isDayOpen] — the "Další trénink" the
/// kiosk status bar shows on days without training.
Day? nextTrainingDay({
  required Day today,
  required ScheduleSettings settings,
  required List<TimeBlock> blocks,
  required List<DayOverride> overrides,
  required int horizonDays,
}) {
  for (var offset = 1; offset <= horizonDays; offset++) {
    final date = today.addDays(offset);
    if (isDayOpen(
      date: date,
      today: today,
      settings: settings,
      blocks: blocks,
      overrides: overrides,
    )) {
      return date;
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

  Future<void> _book(
    BuildContext context,
    WidgetRef ref,
    Day date,
    TimeBlock block,
    int lane,
    PlayerName player,
  ) async {
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
        playerId: player.id,
        date: date,
        blockId: block.id,
        lane: lane,
      ),
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: switch (day) {
          ClosedDay(:final reason) => DayHeader(
            date: day.date,
            matches: day.matches,
            closedReason: reason,
          ),
          OpenDay() => _openDay(context, day as OpenDay),
        },
      ),
    );
  }

  Widget _openDay(BuildContext context, OpenDay day) {
    // "Volných" counts cells that are free in principle (not in the past,
    // not beyond the booking horizon) — the kiosk has no per-player/admin
    // policy the way the app does, so this is independent of `selected` and
    // `interactive`.
    final freeCount = day.blocks
        .expand(
          (block) => [
            for (var lane = 1; lane <= day.laneCount; lane++)
              day.slot(block.id, lane),
          ],
        )
        .where(
          (state) => state is FreeSlot && !state.inPast && !state.beyondHorizon,
        )
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DayHeader(
          date: day.date,
          matches: day.matches,
          chipLabel: '$freeCount volných',
        ),
        const SizedBox(height: 6),
        _grid(context, day),
      ],
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
          color: scheme.outlineVariant.withValues(alpha: 0.5),
        ),
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          TableRow(
            children: [
              const SizedBox.shrink(),
              for (var lane = 1; lane <= day.laneCount; lane++)
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text(
                    'Dráha $lane',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
            ],
          ),
          for (final block in day.blocks)
            TableRow(
              children: [
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text(
                    block.label,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                for (var lane = 1; lane <= day.laneCount; lane++)
                  _kioskSlotTile(
                    day: day,
                    block: block,
                    lane: lane,
                    onBook: () => onBook(day.date, block, lane),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  /// Resolves a single kiosk cell's [SlotTile]: booking-only policy — a
  /// [FreeSlot] is tappable only when the grid is interactive, a player is
  /// selected, and the slot isn't in the past or beyond the booking horizon;
  /// a [ReservedSlot] NEVER gets a tap handler regardless of whose
  /// reservation it is (kiosk performs exactly one action type — booking —
  /// never cancellation, unlike the app's `slotTileFor` policy helper).
  Widget _kioskSlotTile({
    required OpenDay day,
    required TimeBlock block,
    required int lane,
    required VoidCallback onBook,
  }) {
    final state = day.slot(block.id, lane);
    switch (state) {
      case MatchSlot():
      case RentedSlot():
        return SlotTile(state: state, size: SlotTileSize.large);
      case ReservedSlot(:final reservation):
        final name = nameById[reservation.playerId] ?? '?';
        return SlotTile(
          state: state,
          size: SlotTileSize.large,
          playerName: name,
        );
      case FreeSlot(:final inPast, :final beyondHorizon):
        final bookable =
            interactive && selected != null && !inPast && !beyondHorizon;
        return SlotTile(
          state: state,
          size: SlotTileSize.large,
          onTap: bookable ? onBook : null,
        );
    }
  }
}

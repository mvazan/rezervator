import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import '../../domain/schedule.dart';

/// Live week view: grid computed by buildWeekSchedule, booking via RPCs.
class WeekScreen extends ConsumerStatefulWidget {
  const WeekScreen({super.key});

  @override
  ConsumerState<WeekScreen> createState() => _WeekScreenState();
}

class _WeekScreenState extends ConsumerState<WeekScreen> {
  int _weekOffset = 0;

  Day _monday(Day today) => today.addDays(1 - today.weekday + 7 * _weekOffset);

  Future<void> _book(Day date, TimeBlock block, int lane, String playerId) async {
    final ok = await confirmDialog(
      context,
      title: 'Rezervovat termín?',
      message: '${dayFull(date)} · ${block.label} · Dráha $lane',
      confirmLabel: 'Rezervovat',
    );
    if (!ok || !mounted) return;
    await tryAction(
      context,
      () => Api.createReservation(
          playerId: playerId, date: date, blockId: block.id, lane: lane),
      success: 'Zarezervováno.',
      errorText: friendlyDbError,
    );
  }

  Future<void> _cancel(Day date, TimeBlock block, Reservation r) async {
    final ok = await confirmDialog(
      context,
      title: 'Zrušit rezervaci?',
      message: '${dayFull(date)} · ${block.label} · Dráha ${r.lane}',
      confirmLabel: 'Zrušit rezervaci',
      cancelLabel: 'Zpět',
    );
    if (!ok || !mounted) return;
    await tryAction(
      context,
      () => Api.cancelReservation(r.id),
      success: 'Rezervace zrušena.',
      errorText: friendlyDbError,
    );
  }

  @override
  Widget build(BuildContext context) {
    final nowDt = DateTime.now();
    final todayDay = Day.fromDateTime(nowDt);
    final now = HourMinute(nowDt.hour, nowDt.minute);
    final monday = _monday(todayDay);

    final settings =
        ref.watch(settingsProvider).value ?? ScheduleSettings.defaults;
    final dbBlocks = ref.watch(timeBlocksProvider).value ?? const [];
    final blocks = dbBlocks.isEmpty ? defaultTimeBlocks() : dbBlocks;
    final overrides = ref.watch(dayOverridesProvider).value ?? const [];
    final matches = ref.watch(matchesProvider).value ?? const [];
    final rentals = ref.watch(rentalsProvider).value ?? const [];
    final reservations =
        ref.watch(weekReservationsProvider(monday)).value ?? const [];
    final players = ref.watch(playersProvider).value ?? const [];
    final me = ref.watch(myProfileProvider).value;
    final mine = ref.watch(myActiveReservationsProvider).value ?? const [];

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
    final myCount =
        me == null ? 0 : activeReservationCount(mine, me.id, todayDay);
    final nameById = {for (final p in players) p.id: p.displayName};

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left),
                onPressed: () => setState(() => _weekOffset--),
              ),
              Expanded(
                child: Text(
                  rangeLabel(monday, monday.addDays(6)),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (_weekOffset != 0)
                TextButton(
                  onPressed: () => setState(() => _weekOffset = 0),
                  child: const Text('dnes'),
                ),
              IconButton(
                icon: const Icon(Icons.chevron_right),
                onPressed: () => setState(() => _weekOffset++),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
            children: [
              for (final day in week.days)
                _DaySection(
                  day: day,
                  me: me,
                  myCount: myCount,
                  settings: settings,
                  nameById: nameById,
                  onBook: _book,
                  onCancel: _cancel,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DaySection extends StatelessWidget {
  const _DaySection({
    required this.day,
    required this.me,
    required this.myCount,
    required this.settings,
    required this.nameById,
    required this.onBook,
    required this.onCancel,
  });

  final DaySchedule day;
  final Profile? me;
  final int myCount;
  final ScheduleSettings settings;
  final Map<String, String> nameById;
  final void Function(Day, TimeBlock, int, String) onBook;
  final void Function(Day, TimeBlock, Reservation) onCancel;

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
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
            for (final m in day.matches)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '🏆 ${m.opponent} · ${m.startsAt.display()}–${m.endsAt.display()}',
                  style: TextStyle(color: scheme.primary, fontSize: 13),
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
        defaultColumnWidth: const FixedColumnWidth(72),
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
                      Text(block.label, style: const TextStyle(fontSize: 12)),
                ),
                for (var lane = 1; lane <= day.laneCount; lane++)
                  _SlotCell(
                    state: day.slot(block.id, lane),
                    me: me,
                    myCount: myCount,
                    settings: settings,
                    nameById: nameById,
                    onBook: () =>
                        me == null ? null : onBook(day.date, block, lane, me!.id),
                    onCancel: (r) => onCancel(day.date, block, r),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _SlotCell extends StatelessWidget {
  const _SlotCell({
    required this.state,
    required this.me,
    required this.myCount,
    required this.settings,
    required this.nameById,
    required this.onBook,
    required this.onCancel,
  });

  final SlotState state;
  final Profile? me;
  final int myCount;
  final ScheduleSettings settings;
  final Map<String, String> nameById;
  final VoidCallback? onBook;
  final void Function(Reservation) onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const height = 44.0;

    switch (state) {
      case MatchSlot():
        return Container(
          height: height,
          color: scheme.errorContainer.withValues(alpha: 0.6),
          alignment: Alignment.center,
          child: Text('Zápas',
              style: TextStyle(
                  fontSize: 11, color: scheme.onErrorContainer)),
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
            style:
                TextStyle(fontSize: 10, color: scheme.onTertiaryContainer),
          ),
        );
      case ReservedSlot(:final reservation):
        final isMine = me != null && reservation.playerId == me!.id;
        final name = nameById[reservation.playerId] ?? '?';
        final cancellable = me != null &&
            canCancel(state: state, myPlayerId: me!.id);
        return InkWell(
          onTap: cancellable ? () => onCancel(reservation) : null,
          child: Container(
            height: height,
            color: isMine
                ? scheme.primaryContainer
                : scheme.surfaceContainerHighest,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 10,
                fontWeight: isMine ? FontWeight.w700 : FontWeight.w400,
                color: isMine
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
              ),
            ),
          ),
        );
      case FreeSlot():
        final bookable = me != null &&
            canBook(state: state, myActiveCount: myCount, settings: settings);
        if (!bookable) {
          return Container(
            height: height,
            color: scheme.surface.withValues(alpha: 0.4),
          );
        }
        return InkWell(
          onTap: onBook,
          child: Container(
            height: height,
            alignment: Alignment.center,
            child: Icon(Icons.add,
                size: 18,
                color: scheme.primary.withValues(alpha: 0.45)),
          ),
        );
    }
  }
}

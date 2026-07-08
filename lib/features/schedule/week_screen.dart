import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import '../../domain/schedule.dart';
import 'widgets/day_header.dart';
import 'widgets/slot_tile.dart';

/// Live week view: grid computed by buildWeekSchedule, booking via RPCs.
class WeekScreen extends ConsumerStatefulWidget {
  const WeekScreen({super.key});

  @override
  ConsumerState<WeekScreen> createState() => _WeekScreenState();
}

class _WeekScreenState extends ConsumerState<WeekScreen> {
  int _weekOffset = 0;

  Day _monday(Day today) => today.addDays(1 - today.weekday + 7 * _weekOffset);

  Future<void> _book(
      Day date, TimeBlock block, int lane, Profile me, bool isAdmin) async {
    final message = '${dayFull(date)} · ${block.label} · Dráha $lane';
    String? playerId;
    if (isAdmin) {
      playerId = await showDialog<String>(
        context: context,
        builder: (dialogContext) => _BookingDialog(
          message: message,
          me: me,
          players: ref.read(playersProvider).value ?? const [],
        ),
      );
    } else {
      final confirmed = await confirmDialog(
        context,
        title: 'Rezervovat termín?',
        message: message,
        confirmLabel: 'Rezervovat',
      );
      playerId = confirmed ? me.id : null;
    }
    if (playerId == null || !mounted) return;
    await tryAction(
      context,
      () => Api.createReservation(
          playerId: playerId!, date: date, blockId: block.id, lane: lane),
      success: 'Zarezervováno.',
      errorText: friendlyDbError,
    );
  }

  Future<void> _cancel(Day date, TimeBlock block, Reservation r,
      {required bool ownFuture}) async {
    if (ownFuture) {
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
      return;
    }
    final note = await promptText(
      context,
      title: 'Zrušit rezervaci — poznámka',
      hint: 'nepřišel',
      confirmLabel: 'Zrušit rezervaci',
    );
    if (note == null || !mounted) return;
    await tryAction(
      context,
      () => Api.cancelReservation(r.id, note: note),
      success: 'Rezervace zrušena.',
      errorText: friendlyDbError,
    );
  }

  void _go(int delta) {
    setState(() => _weekOffset = delta == 0 ? 0 : _weekOffset + delta);
    // Views cannot stream (see playersProvider doc), so an explicit refresh
    // on navigation is the only way approved-after-start players stop
    // rendering as '?' without a full app restart.
    ref.invalidate(playersProvider);
  }

  @override
  Widget build(BuildContext context) {
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
    final me = ref.watch(myProfileProvider).value;
    final mine = ref.watch(myActiveReservationsProvider).value ?? const [];

    final header = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () => _go(-1),
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
              onPressed: () => _go(0),
              child: const Text('dnes'),
            ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: () => _go(1),
          ),
        ],
      ),
    );

    if (timeBlocks.isLoading) {
      return Column(
        children: [
          header,
          const Expanded(
            child: Center(child: CircularProgressIndicator()),
          ),
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
    // Cells stay inert while the placeholder grid is shown (placeholder ids
    // like 'default-N' are not UUIDs — the RPC would reject them with an
    // unmapped error; the placeholder only shows the shape of the schedule
    // before the backend is seeded) and while this week's reservations are
    // still loading/erroring (booking against a stale/absent view of who
    // already holds the slot would race the RPC's own authoritative check).
    final interactive =
        blocksFromDb && weekReservations.hasValue && me != null;

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
        header,
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
                  interactive: interactive,
                  onBook: (date, block, lane) =>
                      _book(date, block, lane, me!, me.isAdmin),
                  onCancel: (date, block, r, {required ownFuture}) =>
                      _cancel(date, block, r, ownFuture: ownFuture),
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
    required this.interactive,
    required this.onBook,
    required this.onCancel,
  });

  final DaySchedule day;
  final Profile? me;
  final int myCount;
  final ScheduleSettings settings;
  final Map<String, String> nameById;

  /// False while blocks are the placeholder grid or this week's reservation
  /// stream isn't loaded yet — see the doc comment in build() for why.
  final bool interactive;
  final void Function(Day, TimeBlock, int lane) onBook;
  final void Function(Day, TimeBlock, Reservation,
      {required bool ownFuture}) onCancel;

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
    final isAdmin = me?.isAdmin ?? false;
    final freeCount = day.blocks
        .expand((block) =>
            [for (var lane = 1; lane <= day.laneCount; lane++) (block, lane)])
        .where((entry) => canBook(
              state: day.slot(entry.$1.id, entry.$2),
              myActiveCount: myCount,
              settings: settings,
              isAdmin: isAdmin,
            ))
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
                  _slotTile(day, block, lane),
              ],
            ),
        ],
      ),
    );
  }

  /// Resolves the same booking/cancel policy the old `_SlotCell` computed
  /// inline (canBook/canCancel, admin exemptions, name lookup) into the
  /// slim SlotTile contract: a display name, isMine/quiet flags, and a
  /// single resolved tap handler (or null to render the cell inert).
  Widget _slotTile(OpenDay day, TimeBlock block, int lane) {
    final state = day.slot(block.id, lane);
    switch (state) {
      case MatchSlot():
      case RentedSlot():
        return SlotTile(state: state, size: SlotTileSize.compact);
      case ReservedSlot(:final reservation):
        final isMine = me != null && reservation.playerId == me!.id;
        final name = nameById[reservation.playerId] ?? '?';
        // Pozn.: RPC dovoluje rezervovat i dnešní už začatý blok (kontroluje
        // jen p_date < today); klient ho schovává jako inPast. Kiosk může
        // chtít tuto benevolenci využít.
        final ownFuture = isMine && canCancel(state: state, myPlayerId: me!.id);
        // Admins may cancel any reservation (own/foreign, past/future); a
        // non-admin may only cancel their own not-yet-started one.
        final cancellable =
            interactive && me != null && (me!.isAdmin || ownFuture);
        return SlotTile(
          state: state,
          size: SlotTileSize.compact,
          playerName: name,
          isMine: isMine,
          onTap: cancellable
              ? () => onCancel(day.date, block, reservation,
                  ownFuture: ownFuture)
              : null,
        );
      case FreeSlot():
        final isAdmin = me?.isAdmin ?? false;
        final bookable = interactive &&
            me != null &&
            canBook(
                state: state,
                myActiveCount: myCount,
                settings: settings,
                isAdmin: isAdmin);
        // Cells only bookable through the admin exemption (inPast or
        // beyondHorizon, which a regular player could never book) render the
        // '+' quieter, so admins can tell at a glance which slots are
        // ordinarily locked.
        final normallyBookable = canBook(
            state: state,
            myActiveCount: myCount,
            settings: settings,
            isAdmin: false);
        return SlotTile(
          state: state,
          size: SlotTileSize.compact,
          quiet: !normallyBookable,
          onTap: bookable ? () => onBook(day.date, block, lane) : null,
        );
    }
  }
}

/// Admin-only booking dialog: same confirmation as the plain player flow,
/// plus a player picker (defaults to the admin themself, labelled 'já').
/// Pops the chosen player's id, or null on cancel.
class _BookingDialog extends StatefulWidget {
  const _BookingDialog({
    required this.message,
    required this.me,
    required this.players,
  });

  final String message;
  final Profile me;
  final List<PlayerName> players;

  @override
  State<_BookingDialog> createState() => _BookingDialogState();
}

class _BookingDialogState extends State<_BookingDialog> {
  late String _playerId = widget.me.id;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rezervovat termín?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.message),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _playerId,
            decoration: const InputDecoration(labelText: 'Rezervovat pro'),
            items: [
              DropdownMenuItem(value: widget.me.id, child: const Text('já')),
              for (final p in widget.players)
                if (p.id != widget.me.id)
                  DropdownMenuItem(value: p.id, child: Text(p.displayName)),
            ],
            onChanged: (v) => setState(() => _playerId = v!),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Zrušit'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _playerId),
          child: const Text('Rezervovat'),
        ),
      ],
    );
  }
}

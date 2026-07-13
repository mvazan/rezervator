import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart';
import '../../data/providers.dart';
import '../../domain/models.dart';
import '../../domain/schedule.dart';
import '../../domain/calendar_layout.dart' show hourMinuteAt;
import '../admin/matches_screen.dart' show MatchDialog;
import '../admin/widgets/block_dialog.dart';
import '../admin/widgets/blockage_dialog.dart';
import 'day_pager_view.dart';
import 'week_calendar_view.dart';

/// The two schedule layouts a device can be set to; persisted per-device via
/// [scheduleViewPrefKey].
enum ScheduleView { day, week }

/// Live week view: grid computed by buildWeekSchedule, booking via RPCs.
/// Acts as the "shell": owns navigation (week offset) and all provider
/// wiring; delegates rendering to [WeekCalendarView] or [DayPagerView],
/// which both receive the same pre-computed [WeekSchedule] and handlers.
///
/// The view follows the device orientation — portrait shows the day pager,
/// landscape the week calendar — and both always fit the screen width, so
/// there are no toggle buttons to explain.
class WeekScreen extends ConsumerStatefulWidget {
  const WeekScreen({super.key});

  @override
  ConsumerState<WeekScreen> createState() => _WeekScreenState();
}

class _WeekScreenState extends ConsumerState<WeekScreen> {
  int _weekOffset = 0;
  int _dayIndex = 0;

  Day _monday(Day today) => today.addDays(1 - today.weekday + 7 * _weekOffset);

  @override
  void initState() {
    super.initState();
    _dayIndex = Day.fromDateTime(DateTime.now()).weekday - 1;
  }

  Future<void> _book(
    Day date,
    TimeBlock block,
    int lane,
    Profile me,
    bool isAdmin,
  ) async {
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
        playerId: playerId!,
        date: date,
        blockId: block.id,
        lane: lane,
      ),
      success: 'Zarezervováno.',
      errorText: friendlyDbError,
    );
  }

  Future<void> _cancel(
    Day date,
    TimeBlock block,
    Reservation r, {
    required bool ownFuture,
  }) async {
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
    setState(() {
      _weekOffset = delta == 0 ? 0 : _weekOffset + delta;
      if (delta == 0) {
        _dayIndex = Day.fromDateTime(DateTime.now()).weekday - 1;
      }
    });
    // Views cannot stream (see playersProvider doc), so an explicit refresh
    // on navigation is the only way approved-after-start players stop
    // rendering as '?' without a full app restart.
    ref.invalidate(playersProvider);
  }

  /// Called by [DayPagerView] when a swipe crosses the Monday/Sunday edge:
  /// [weekDelta] is +1/-1 and [landingDayIndex] (0=Mon..6=Sun) is the day to
  /// land on in the adjacent week (Sunday when moving back, Monday when
  /// moving forward).
  void _shiftWeek(int weekDelta, int landingDayIndex) {
    setState(() {
      _weekOffset += weekDelta;
      _dayIndex = landingDayIndex;
    });
    ref.invalidate(playersProvider);
  }

  void _selectDay(int dayIndex) => setState(() => _dayIndex = dayIndex);

  @override
  Widget build(BuildContext context) {
    final nowDt = DateTime.now();
    final todayDay = Day.fromDateTime(nowDt);
    final now = HourMinute(nowDt.hour, nowDt.minute);
    final monday = _monday(todayDay);
    // Orientation IS the view switch: portrait reads day-by-day, landscape
    // shows the whole week. Both always stretch to the full width.
    final view = MediaQuery.orientationOf(context) == Orientation.portrait
        ? ScheduleView.day
        : ScheduleView.week;
    const fitWidth = true;

    final settings =
        ref.watch(settingsProvider).value ?? ScheduleSettings.defaults;
    final timeBlocks = ref.watch(timeBlocksProvider);
    final overrides = ref.watch(dayOverridesProvider).value ?? const [];
    final priority = ref.watch(prioritySlotsProvider);
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
            TextButton(onPressed: () => _go(0), child: const Text('dnes')),
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
    // Cells stay inert while the placeholder grid is shown (placeholder ids
    // like 'default-N' are not UUIDs — the RPC would reject them with an
    // unmapped error; the placeholder only shows the shape of the schedule
    // before the backend is seeded) and while this week's reservations are
    // still loading/erroring (booking against a stale/absent view of who
    // already holds the slot would race the RPC's own authoritative check).
    final interactive = blocksFromDb && weekReservations.hasValue && me != null;

    final week = buildWeekSchedule(
      monday: monday,
      today: todayDay,
      now: now,
      settings: settings,
      blocks: blocks,
      overrides: overrides,
      priority: priority,
      rentals: rentals,
      reservations: reservations,
    );
    final myCount = me == null
        ? 0
        : activeReservationCount(mine, me.id, todayDay);
    // Prefer the board nick when set, matching the kiosk board.
    final nameById = {
      for (final p in players) p.id: p.nick.isNotEmpty ? p.nick : p.displayName,
    };
    final clubColorById = {for (final p in players) p.id: p.clubColor};
    final myCountByIndex = [
      for (var i = 0; i < 7; i++)
        _myLiveCountOn(mine, me?.id, monday.addDays(i)),
    ];

    void onBook(Day date, TimeBlock block, int lane) =>
        _book(date, block, lane, me!, me.isAdmin);
    void onCancel(
      Day date,
      TimeBlock block,
      Reservation r, {
      required bool ownFuture,
    }) => _cancel(date, block, r, ownFuture: ownFuture);
    // Admin block gestures (long-press edit, tap-a-gap add) only exist for
    // admins on the real DB block set — never on the placeholder grid.
    // Calendar edits are DAY-SCOPED: they compose a day override around an
    // inactive "special" block instead of touching the weekly template
    // (that lives in Admin → Rozvrh).
    final canEditBlocks = (me?.isAdmin ?? false) && blocksFromDb;
    final overrideByDate = {for (final o in overrides) o.date: o};
    final blockById = {for (final b in dbBlocks) b.id: b};

    // The day's PRE-cancellation block ids (existing override selection or
    // the active weekly template) — what the new override is composed from.
    // A day that renders CLOSED (override or non-training weekday) starts
    // from an empty base: adding a block there opens the day with exactly
    // that block, never with the whole weekly template in tow.
    List<String> dayBaseIds(Day date) {
      final o = overrideByDate[date];
      if (o != null && !o.closed && o.blockIds != null) {
        return [
          for (final id in o.blockIds!)
            if (blockById.containsKey(id)) id,
        ];
      }
      if (week.days[date.weekday - 1] is ClosedDay) return const [];
      return [
        for (final b in dbBlocks)
          if (b.active) b.id,
      ];
    }

    // What the day actually renders — a match-cancelled block hides
    // silently (nothing visible changes), only visible/reserved ones warn.
    Set<String> dayRenderedIds(Day date) {
      final day = week.days[date.weekday - 1];
      return day is OpenDay && day.date == date
          ? {for (final b in day.blocks) b.id}
          : const {};
    }

    // Past days are history: set_day_override would cancel their (already
    // played) reservations and corrupt attendance — the gestures refuse.
    bool guardPast(Day date) {
      if (!date.isBefore(todayDay)) return false;
      snack(context, 'Minulé dny nelze upravovat.');
      return true;
    }

    final onEditBlock = canEditBlocks
        ? (Day date, TimeBlock block) {
            if (guardPast(date)) return;
            showDialog<void>(
              context: context,
              builder: (_) => BlockDialog(
                existing: block,
                blocks: dbBlocks,
                dayContext: date,
                dayBaseIds: dayBaseIds(date),
                dayRenderedIds: dayRenderedIds(date),
                dayHasOverride: overrideByDate[date] != null,
                dayIsTraining:
                    settings.trainingWeekdays.contains(date.weekday),
                dayPriority: week.days[date.weekday - 1].priority,
                dayReason: overrideByDate[date]?.reason ?? '',
              ),
            );
          }
        : null;
    Future<void> openAdd(Day date,
        {HourMinute? start, HourMinute? end}) async {
      if (guardPast(date)) return;
      // Adding a block into a CLOSED day reopens it — that's a bigger
      // decision than the dialog title suggests, so say it out loud.
      if (week.days[date.weekday - 1] is ClosedDay) {
        final reason = overrideByDate[date]?.reason ?? '';
        final proceed = await confirmDialog(
          context,
          title: 'Den je zavřený',
          message: reason.isEmpty
              ? '${dayFull(date)} je zavřeno. Přidáním bloku den '
                  'otevřeš. Pokračovat?'
              : '${dayFull(date)} je zavřeno („$reason"). Přidáním '
                  'bloku den otevřeš. Pokračovat?',
          confirmLabel: 'Otevřít den',
        );
        if (!proceed || !context.mounted) return;
      }
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => BlockDialog(
          existing: null,
          blocks: dbBlocks,
          initialStart: start,
          initialEnd: end,
          dayContext: date,
          dayBaseIds: dayBaseIds(date),
          dayRenderedIds: dayRenderedIds(date),
          dayHasOverride: overrideByDate[date] != null,
          dayIsTraining: settings.trainingWeekdays.contains(date.weekday),
          dayPriority: week.days[date.weekday - 1].priority,
          dayReason: overrideByDate[date]?.reason ?? '',
        ),
      );
    }

    final onAddBlockInGap = canEditBlocks
        ? (Day date, HourMinute start, HourMinute end) =>
            openAdd(date, start: start, end: end)
        : null;

    // Header ＋: add a slot to a day whose column has no empty space left
    // to tap — same dialog, times picked in the dialog.
    final onAddForDay =
        canEditBlocks ? (Day date) => openAdd(date) : null;

    // Click on a blocking band = edit. An úklid child opens its parent
    // match (it is auto-managed); matches open the match dialog, other
    // blockages the blockage dialog.
    final slotTypes = ref.watch(slotTypesProvider).value ?? const [];
    final onEditPrioritySlot = canEditBlocks
        ? (Day date, PrioritySlot slot) {
            var target = slot;
            if (slot.parentId != null) {
              final parent =
                  priority.where((m) => m.id == slot.parentId).firstOrNull;
              if (parent == null) return;
              target = parent;
            }
            showDialog<void>(
              context: context,
              builder: (_) => target.type.isMatch
                  ? MatchDialog(existing: target, types: slotTypes)
                  : BlockageDialog(existing: target, types: slotTypes),
            );
          }
        : null;

    // HOLD-drag moves. A training block moves day-scoped (its sign-ups
    // travel along); a blocking slot just gets new times (the server drags
    // a match's úklid child with it).
    final onMoveBlock = canEditBlocks
        ? (Day date, TimeBlock block, HourMinute newStart) async {
            if (guardPast(date)) return;
            final endMinutes =
                newStart.minutesFromMidnight + block.durationMinutes;
            if (endMinutes > 24 * 60 - 1) {
              snack(context, 'Blok se nevejde do dne.');
              return;
            }
            final newEnd = hourMinuteAt(endMinutes);
            await tryAction(
              context,
              () async {
                // Same day-scoped composition BlockDialog uses: sentinel
                // special (reuse or insert), sign-ups travel, override swap.
                TimeBlock? special;
                for (final b in dbBlocks) {
                  if (!b.active &&
                      b.position < 0 &&
                      b.startsAt == newStart &&
                      b.endsAt == newEnd) {
                    special = b;
                    break;
                  }
                }
                final specialId =
                    special?.id ?? await Api.addSpecialBlock(newStart, newEnd);
                await Api.moveDayReservations(date, block.id, specialId);
                final base = dayBaseIds(date);
                final ids = base.contains(block.id)
                    ? [for (final id in base) id == block.id ? specialId : id]
                    : [...base, specialId];
                await Api.setDayOverride(
                  date: date,
                  closed: false,
                  reason: overrideByDate[date]?.reason ?? '',
                  blockIds: ids,
                );
              },
              success: 'Přesunuto (jen tento den).',
              errorText: friendlyDbError,
            );
          }
        : null;
    final onMovePrioritySlot = canEditBlocks
        ? (Day date, PrioritySlot slot, HourMinute newStart) async {
            if (guardPast(date)) return;
            final dur = slot.endsAt.minutesFromMidnight -
                slot.startsAt.minutesFromMidnight;
            final endMinutes = newStart.minutesFromMidnight + dur;
            if (endMinutes > 24 * 60 - 1) {
              snack(context, 'Slot se nevejde do dne.');
              return;
            }
            await tryAction(
              context,
              () => Api.savePrioritySlot(
                id: slot.id,
                date: date,
                startsAt: newStart,
                endsAt: hourMinuteAt(endMinutes),
                typeId: slot.type.id,
                homeTeam: slot.homeTeam,
                awayTeam: slot.awayTeam,
                prepMinutes: slot.prepMinutes,
                description: slot.description,
              ),
              success: 'Přesunuto.',
              errorText: friendlyDbError,
            );
          }
        : null;

    return Column(
      children: [
        header,
        Expanded(
          child: view == ScheduleView.week
              ? WeekCalendarView(
                  week: week,
                  today: todayDay,
                  now: now,
                  me: me,
                  myCount: myCount,
                  settings: settings,
                  nameById: nameById,
                  clubColorById: clubColorById,
                  interactive: interactive,
                  fitWidth: fitWidth,
                  onBook: onBook,
                  onCancel: onCancel,
                  onEditBlock: onEditBlock,
                  onAddBlockInGap: onAddBlockInGap,
                  onAddForDay: onAddForDay,
                  onEditPrioritySlot: onEditPrioritySlot,
                  onMoveBlock: onMoveBlock,
                  onMovePrioritySlot: onMovePrioritySlot,
                )
              : DayPagerView(
                  week: week,
                  fitWidth: fitWidth,
                  weekOffset: _weekOffset,
                  dayIndex: _dayIndex,
                  today: todayDay,
                  now: now,
                  settings: settings,
                  blocks: blocks,
                  overrides: overrides,
                  priority: priority,
                  rentals: rentals,
                  me: me,
                  myCount: myCount,
                  myCountByIndex: myCountByIndex,
                  nameById: nameById,
                  clubColorById: clubColorById,
                  interactive: interactive,
                  onBook: onBook,
                  onCancel: onCancel,
                  onSelectDay: _selectDay,
                  onShiftWeek: _shiftWeek,
                ),
        ),
      ],
    );
  }
}

/// Count of [playerId]'s live reservations that fall on exactly [date] —
/// the per-day dot count [DayChipStrip] renders (as opposed to
/// [activeReservationCount], which counts cumulatively from a date forward
/// for the active-reservations limit).
int _myLiveCountOn(List<Reservation> mine, String? playerId, Day date) {
  if (playerId == null) return 0;
  return mine
      .where((r) => r.playerId == playerId && r.isLive && r.date == date)
      .length;
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

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ui.dart' show snack;
import '../../data/clock.dart';
import '../../data/providers.dart';
import '../../data/week_schedule.dart';
import '../../domain/freed_spot.dart';
import '../../domain/models.dart';
import '../../domain/schedule.dart';
import '../clubhouse/duties_screen.dart';
import 'calendar_focus.dart';
import 'schedule_actions.dart';
import 'schedule_callbacks.dart';
import 'week_board.dart';
import 'widgets/week_header.dart';
import '../../core/push_screen.dart';

/// Live week view: grid computed by buildWeekSchedule, booking via RPCs.
/// Acts as the "shell": owns navigation (week offset) and all provider
/// wiring; delegates rendering to [WeekBoard], which receives the same
/// pre-computed [WeekSchedule] and the handlers a [ScheduleActions] builds
/// from it; the top strip is a [WeekHeader].
///
/// The view follows the device orientation — portrait shows the day pager,
/// landscape the week calendar — and both always fit the screen width, so
/// there are no toggle buttons to explain (see [WeekBoard]).
class WeekScreen extends ConsumerStatefulWidget {
  const WeekScreen({super.key, this.trailing = const []});

  /// Extra actions appended to the week-navigation row — in landscape the
  /// shell has no AppBar and parks its icons here (one shared top line).
  final List<Widget> trailing;

  @override
  ConsumerState<WeekScreen> createState() => _WeekScreenState();
}

class _WeekScreenState extends ConsumerState<WeekScreen> with WeekNavigation {
  /// A „uvolnilo se místo“ push (calendar_focus.dart): the answer is given
  /// a moment after the day is on screen, from the data as it stands THEN —
  /// the first frame may still show the cached week, in which the spot
  /// looks taken though it was freed a minute ago. [_settleFocus] always
  /// holds the latest build's closure.
  Timer? _focusTimer;
  Timer? _highlightTimer;
  VoidCallback? _settleFocus;

  static const _focusDelay = Duration(milliseconds: 1200);
  static const _highlightFor = Duration(seconds: 8);

  @override
  void dispose() {
    _focusTimer?.cancel();
    _highlightTimer?.cancel();
    super.dispose();
  }

  /// Says what the push's spot is now and, when it is as the push said
  /// (free, or holding the kiosk booking), outlines it.
  void _answerFocus(
    CalendarFocus focus,
    DaySchedule day, {
    required Profile? me,
    required int myCount,
    required ScheduleSettings settings,
    required SlotCallbacks slot,
  }) {
    final current = ref.read(calendarFocusProvider);
    if (!mounted || current == null || current.handled) return;
    final notifier = ref.read(calendarFocusProvider.notifier);
    final blockId = focus.blockId;
    final lane = focus.lane;
    if (blockId == null || lane == null) {
      // An older push names only the day: showing it is the whole answer.
      notifier.clear();
      return;
    }
    final reservationId = focus.reservationId;
    if (reservationId != null) {
      // A kiosk booking: outline it while the spot still holds it.
      final booked = day is OpenDay &&
          day.blocks.any((b) => b.id == blockId) &&
          lane >= 1 &&
          lane <= day.laneCount &&
          switch (day.slot(blockId, lane)) {
            ReservedSlot(:final reservation) => reservation.id == reservationId,
            _ => false,
          };
      if (!booked) {
        snack(context, 'Tahle rezervace už je zrušená.');
        notifier.clear();
        return;
      }
      _highlight(notifier);
      return;
    }
    final result = freedSpotResult(
      day,
      blockId: blockId,
      lane: lane,
      myPlayerId: me?.id,
      myActiveCount: myCount,
      settings: settings,
      isAdmin: me?.isAdmin ?? false,
      forGroup: slot.groupMateIds.isNotEmpty,
      onDuty: slot.onDuty,
    );
    final free = result.outcome == FreedSpotOutcome.free;
    final message = result.message;
    if (message != null) snack(context, message);
    if (!free) {
      notifier.clear();
      return;
    }
    _highlight(notifier);
  }

  /// Outlines the focused cell for [_highlightFor].
  void _highlight(CalendarFocusNotifier notifier) {
    notifier.markHandled(highlight: true);
    _highlightTimer?.cancel();
    _highlightTimer = Timer(_highlightFor, () {
      if (mounted) notifier.clear();
    });
  }

  /// The app's clock read afresh — the duty's day edits ask it again right
  /// before writing (0050), long after this build.
  HourMinute _clockNow() {
    final t = (mounted ? ref.read(nowProvider).value : null) ?? DateTime.now();
    return HourMinute(t.hour, t.minute);
  }

  @override
  Widget build(BuildContext context) {
    // A push asks for a spot: move to its week and day (the answer comes
    // from the build below, once the day is on screen).
    ref.listen(calendarFocusProvider, (_, next) {
      if (next == null || next.handled) return;
      final clock = ref.read(nowProvider).value ?? DateTime.now();
      showDay(next.date, today: Day.fromDateTime(clock));
    });
    final nowDt = ref.watch(nowProvider).value ?? DateTime.now();
    final todayDay = Day.fromDateTime(nowDt);
    final now = HourMinute(nowDt.hour, nowDt.minute);
    final monday = mondayOf(todayDay);

    final settings =
        ref.watch(settingsProvider).value ?? ScheduleSettings.defaults;
    final view = ref.watch(weekScheduleProvider(monday));
    // Still watched here for the admin edit closures and the pager's
    // sentinel weeks; the grid itself arrives composed from the provider.
    final overrides = ref.watch(dayOverridesProvider).value ?? const [];
    final priority = ref.watch(prioritySlotsProvider);
    final rentals = ref.watch(rentalsProvider).value ?? const [];
    final me = ref.watch(myProfileProvider).value;
    final mine = ref.watch(myActiveReservationsProvider).value ?? const [];
    final group = ref.watch(myGroupProvider);

    final header = WeekHeader(
      monday: monday,
      weekOffset: weekOffset,
      onGo: goWeek,
      trailing: widget.trailing,
      duty: ref.watch(weekDutyHeaderProvider(monday)),
      onDutyTap: () => pushScreen<void>(context, (_) => const DutiesScreen()),
    );

    if (view.isLoading) {
      return Column(
        children: [
          header,
          const Expanded(child: Center(child: CircularProgressIndicator())),
        ],
      );
    }

    if (view.hasError) {
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

    final wv = view.value!;
    final blocks = wv.blocks;
    final blocksFromDb = wv.blocksFromDb;
    final dbBlocks = blocksFromDb ? blocks : const <TimeBlock>[];
    final reservations = wv.reservations;
    // The view already withholds interactivity on the placeholder grid and
    // while this week's reservations are loading; a signed-in profile is
    // the app's own extra condition.
    final interactive = wv.interactive && me != null;
    // Match links (video + tap-through) must not wait on booking readiness
    // — a kuželna with no db time blocks yet (still on the placeholder
    // grid) should still let a signed-in player watch/open a match.
    final matchLinks = me != null;
    final week = wv.week;
    final myCount = me == null
        ? 0
        : activeReservationCount(mine, me.id, todayDay);
    final nameById = wv.nameById;
    final clubColorById = wv.clubColorById;
    final myCountByIndex = [
      for (var i = 0; i < 7; i++)
        _myLiveCountOn(mine, me?.id, monday.addDays(i)),
    ];

    // Day-block gestures (long-press edit, tap-a-gap add, move, the day
    // menu) exist for the admin and for a player with canteen duty periods
    // (0050) — on the real DB block set only, never on the placeholder
    // grid. Which days a duty may edit is ScheduleActions.canEditDay's
    // question: the days of their own periods, on duty today or not.
    final duty = ref.watch(myDutyProvider);
    final canEditBlocks =
        ((me?.isAdmin ?? false) || duty.mine.isNotEmpty) && blocksFromDb;
    final slotTypes = ref.watch(slotTypesProvider).value ?? const [];
    final actions = ScheduleActions(
      context: context,
      ref: ref,
      week: week,
      dbBlocks: dbBlocks,
      overrides: overrides,
      priority: priority,
      slotTypes: slotTypes,
      settings: settings,
      today: todayDay,
      now: now,
      reservations: reservations,
      rentals: rentals,
      me: me,
      canEditBlocks: canEditBlocks,
      noAccountIds: wv.noAccountIds,
      groupMateIds: me == null ? const {} : group.matesOf(me.id),
      duty: duty,
      clock: _clockNow,
    );

    final focus = ref.watch(calendarFocusProvider);
    if (focus != null &&
        !focus.handled &&
        interactive &&
        week.days[dayIndex].date == focus.date) {
      final shown = week.days[dayIndex];
      _settleFocus = () => _answerFocus(
        focus,
        shown,
        me: me,
        myCount: myCount,
        settings: settings,
        slot: actions.slot,
      );
      _focusTimer ??= Timer(_focusDelay, () {
        _focusTimer = null;
        _settleFocus?.call();
      });
    }

    return Column(
      children: [
        header,
        Expanded(
          child: WeekBoard(
            week: week,
            weekOffset: weekOffset,
            dayIndex: dayIndex,
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
            matchLinks: matchLinks,
            slot: actions.slot,
            admin: actions.admin,
            onSelectDay: selectDay,
            onShiftWeek: shiftWeek,
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

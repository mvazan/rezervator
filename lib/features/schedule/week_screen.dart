import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/clock.dart';
import '../../data/providers.dart';
import '../../data/week_schedule.dart';
import '../../domain/models.dart';
import '../../domain/schedule.dart';
import 'day_pager_view.dart';
import 'schedule_actions.dart';
import 'week_calendar_view.dart';
import 'widgets/week_header.dart';

/// Live week view: grid computed by buildWeekSchedule, booking via RPCs.
/// Acts as the "shell": owns navigation (week offset) and all provider
/// wiring; delegates rendering to [WeekCalendarView] or [DayPagerView],
/// which both receive the same pre-computed [WeekSchedule] and the handlers
/// a [ScheduleActions] builds from it; the top strip is a [WeekHeader].
///
/// The view follows the device orientation — portrait shows the day pager,
/// landscape the week calendar — and both always fit the screen width, so
/// there are no toggle buttons to explain.
class WeekScreen extends ConsumerStatefulWidget {
  const WeekScreen({super.key, this.trailing = const []});

  /// Extra actions appended to the week-navigation row — in landscape the
  /// shell has no AppBar and parks its icons here (one shared top line).
  final List<Widget> trailing;

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

  void _go(int delta) {
    setState(() {
      _weekOffset = delta == 0 ? 0 : _weekOffset + delta;
      if (delta == 0) {
        _dayIndex = Day.fromDateTime(DateTime.now()).weekday - 1;
      }
    });
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
  }

  void _selectDay(int dayIndex) => setState(() => _dayIndex = dayIndex);

  @override
  Widget build(BuildContext context) {
    final nowDt = ref.watch(nowProvider).value ?? DateTime.now();
    final todayDay = Day.fromDateTime(nowDt);
    final now = HourMinute(nowDt.hour, nowDt.minute);
    final monday = _monday(todayDay);
    // Orientation IS the view switch: portrait reads day-by-day, landscape
    // shows the whole week. Both always stretch to the full width.
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;

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

    final header = WeekHeader(
      monday: monday,
      weekOffset: _weekOffset,
      onGo: _go,
      trailing: widget.trailing,
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

    // Admin block gestures (long-press edit, tap-a-gap add) only exist for
    // admins on the real DB block set — never on the placeholder grid.
    final canEditBlocks = (me?.isAdmin ?? false) && blocksFromDb;
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
      reservations: reservations,
      me: me,
      canEditBlocks: canEditBlocks,
    );

    return Column(
      children: [
        header,
        Expanded(
          child: landscape
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
                  onBook: actions.onBook,
                  onCancel: actions.onCancel,
                  onEditBlock: actions.onEditBlock,
                  onAddBlockInGap: actions.onAddBlockInGap,
                  onAddForDay: actions.onAddForDay,
                  onEditPrioritySlot: actions.onEditPrioritySlot,
                  onMoveBlock: actions.onMoveBlock,
                  onMovePrioritySlot: actions.onMovePrioritySlot,
                )
              : DayPagerView(
                  week: week,
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
                  onBook: actions.onBook,
                  onCancel: actions.onCancel,
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

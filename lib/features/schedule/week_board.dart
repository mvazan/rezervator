/// The schedule board both week screens render — the signed-in app's
/// [WeekScreen] and the public read-only overview — and the week/day
/// navigation they share, so the two look and page identically.
///
/// The view follows the device orientation: portrait reads day by day
/// ([DayPagerView]), landscape shows the whole week ([WeekCalendarView]);
/// both always fit the screen width, so there are no toggle buttons.
library;

import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../../domain/schedule.dart';
import 'day_pager_view.dart';
import 'schedule_callbacks.dart';
import 'week_calendar_view.dart';

/// Which week and day a schedule screen shows, and the moves between them.
mixin WeekNavigation<T extends StatefulWidget> on State<T> {
  /// Weeks away from the current one (0 = this week).
  int weekOffset = 0;

  /// 0 (Monday) .. 6 (Sunday): the day the portrait pager shows.
  int dayIndex = Day.fromDateTime(DateTime.now()).weekday - 1;

  Day mondayOf(Day today) =>
      today.addDays(1 - today.weekday + 7 * weekOffset);

  /// The header's arrows (±1) and its „dnes" (0: back to today).
  void goWeek(int delta) {
    setState(() {
      weekOffset = delta == 0 ? 0 : weekOffset + delta;
      if (delta == 0) {
        dayIndex = Day.fromDateTime(DateTime.now()).weekday - 1;
      }
    });
  }

  /// Called by [DayPagerView] when a swipe crosses the Monday/Sunday edge:
  /// [weekDelta] is +1/-1 and [landingDayIndex] (0=Mon..6=Sun) is the day to
  /// land on in the adjacent week (Sunday when moving back, Monday when
  /// moving forward).
  void shiftWeek(int weekDelta, int landingDayIndex) {
    setState(() {
      weekOffset += weekDelta;
      dayIndex = landingDayIndex;
    });
  }

  void selectDay(int index) => setState(() => dayIndex = index);
}

class WeekBoard extends StatelessWidget {
  const WeekBoard({
    super.key,
    required this.week,
    required this.weekOffset,
    required this.dayIndex,
    required this.today,
    required this.now,
    required this.settings,
    required this.blocks,
    required this.overrides,
    required this.priority,
    required this.rentals,
    required this.me,
    required this.myCount,
    required this.myCountByIndex,
    required this.nameById,
    required this.clubColorById,
    required this.interactive,
    required this.matchLinks,
    required this.slot,
    this.admin = CalendarAdminHooks.none,
    required this.onSelectDay,
    required this.onShiftWeek,
  });

  final WeekSchedule week;
  final int weekOffset;
  final int dayIndex;
  final Day today;
  final HourMinute now;
  final ScheduleSettings settings;

  /// What the pager's sentinel pages rebuild the neighbouring day from.
  final List<TimeBlock> blocks;
  final List<DayOverride> overrides;
  final List<PrioritySlot> priority;
  final List<Rental> rentals;

  final Profile? me;
  final int myCount;
  final List<int> myCountByIndex;
  final Map<String, String> nameById;
  final Map<String, int> clubColorById;
  final bool interactive;

  /// Gates the video control and tap-through in the day-matches dialog —
  /// independent of [interactive] (booking readiness): true whenever a
  /// profile is signed in, whether or not db time blocks/reservations have
  /// loaded yet. False on the public overview; the kiosk board never goes
  /// through [WeekBoard] and hard-codes its own header's `interactive`.
  final bool matchLinks;
  final SlotCallbacks slot;

  /// Calendar-only (landscape): the pager has no admin gestures.
  final CalendarAdminHooks admin;
  final ValueChanged<int> onSelectDay;
  final void Function(int weekDelta, int landingDayIndex) onShiftWeek;

  @override
  Widget build(BuildContext context) {
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    if (landscape) {
      return WeekCalendarView(
        week: week,
        today: today,
        now: now,
        me: me,
        myCount: myCount,
        settings: settings,
        nameById: nameById,
        clubColorById: clubColorById,
        interactive: interactive,
        matchLinks: matchLinks,
        slot: slot,
        admin: admin,
      );
    }
    return DayPagerView(
      week: week,
      weekOffset: weekOffset,
      dayIndex: dayIndex,
      today: today,
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
      slot: slot,
      onSelectDay: onSelectDay,
      onShiftWeek: onShiftWeek,
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/clock.dart';
import '../../data/providers.dart';
import '../../data/week_schedule.dart';
import '../../domain/models.dart';
import '../../domain/schedule.dart';
import 'schedule_actions.dart';
import 'week_board.dart';
import 'widgets/week_header.dart';

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
  @override
  Widget build(BuildContext context) {
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
      rentals: rentals,
      me: me,
      canEditBlocks: canEditBlocks,
      noAccountIds: wv.noAccountIds,
      groupMateIds: me == null ? const {} : group.matesOf(me.id),
    );

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

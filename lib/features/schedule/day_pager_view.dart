/// Day pager: a 7-chip day strip synced to a `PageView` showing one day at a
/// time with large [SlotTile]s. Receives the shell's already-computed
/// [WeekSchedule] plus the plain lists `buildWeekSchedule` needs, so it can
/// render the one or two adjacent "sentinel" days a swipe past Monday/Sunday
/// briefly previews before the shell's week offset actually shifts (see
/// [_pageCount] and the sentinel page index constants below) — no extra
/// provider subscriptions.
library;

import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../../domain/schedule.dart';
import 'week_screen.dart' show slotTileFor;
import 'widgets/day_chip_strip.dart';
import 'widgets/day_header.dart';
import 'widgets/slot_tile.dart';

/// Real pages are indices 1..7 (Monday..Sunday of [week]); index 0 and 8 are
/// sentinels previewing the adjacent week's last/first day mid-swipe.
const _sentinelBefore = 0;
const _firstRealPage = 1;
const _lastRealPage = 7;
const _sentinelAfter = 8;
const _pageCount = 9;

class DayPagerView extends StatefulWidget {
  const DayPagerView({
    super.key,
    required this.week,
    required this.weekOffset,
    required this.dayIndex,
    required this.today,
    required this.now,
    required this.settings,
    required this.blocks,
    required this.overrides,
    required this.matches,
    required this.rentals,
    required this.me,
    required this.myCount,
    required this.myCountByIndex,
    required this.nameById,
    required this.interactive,
    required this.onBook,
    required this.onCancel,
    required this.onSelectDay,
    required this.onShiftWeek,
  });

  /// The currently displayed week (Monday..Sunday), already computed by the
  /// shell from live provider data.
  final WeekSchedule week;

  /// Weeks offset from the current one — used only to derive the Monday of
  /// the adjacent weeks a sentinel page previews.
  final int weekOffset;

  /// 0 (Monday) .. 6 (Sunday): the day currently selected/shown.
  final int dayIndex;

  final Day today;
  final HourMinute now;
  final ScheduleSettings settings;

  /// Plain inputs `buildWeekSchedule` needs besides `reservations`, so a
  /// sentinel page can resolve the adjacent week's day type (open/closed)
  /// and non-reservation slot state (match/rental) correctly. The adjacent
  /// week's live reservations aren't subscribed to (that would duplicate
  /// the shell's realtime wiring for a view that's only ever on-screen for
  /// the last frame of a swipe) — a sentinel page always renders as if that
  /// day had no reservations yet, which self-corrects the instant the swipe
  /// completes and the shell's real [week] for the new offset arrives.
  final List<TimeBlock> blocks;
  final List<DayOverride> overrides;
  final List<Match> matches;
  final List<Rental> rentals;

  final Profile? me;
  final int myCount;

  /// Dot counts per day-of-week index (0=Mon..6=Sun) of [me]'s own live
  /// reservations, for the [DayChipStrip].
  final List<int> myCountByIndex;
  final Map<String, String> nameById;
  final bool interactive;
  final void Function(Day, TimeBlock, int lane) onBook;
  final void Function(Day, TimeBlock, Reservation, {required bool ownFuture})
  onCancel;

  /// Chip tapped directly (no week change).
  final ValueChanged<int> onSelectDay;

  /// A swipe crossed the Monday/Sunday edge: `weekDelta` is +1/-1,
  /// `landingDayIndex` is which day (0=Mon, 6=Sun) to land on in the new
  /// week.
  final void Function(int weekDelta, int landingDayIndex) onShiftWeek;

  @override
  State<DayPagerView> createState() => _DayPagerViewState();
}

class _DayPagerViewState extends State<DayPagerView> {
  late final PageController _controller;

  /// True between a boundary swipe landing on a sentinel and the shell
  /// re-rendering us with the shifted `weekOffset`/`dayIndex` — guards
  /// against re-firing `onShiftWeek` for the same swipe on every rebuild.
  bool _shiftPending = false;

  int get _page => _firstRealPage + widget.dayIndex;

  @override
  void initState() {
    super.initState();
    _controller = PageController(initialPage: _page);
  }

  @override
  void didUpdateWidget(DayPagerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The shell just applied our onSelectDay/onShiftWeek callback and handed
    // back a new dayIndex/week — resync the controller's resting page (a
    // no-op jumpTo when the user's own drag already put it there).
    if (widget.dayIndex != oldWidget.dayIndex ||
        widget.weekOffset != oldWidget.weekOffset) {
      _shiftPending = false;
      if (_controller.hasClients && _controller.page?.round() != _page) {
        _controller.jumpToPage(_page);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onPageChanged(int page) {
    if (page == _sentinelBefore) {
      if (_shiftPending) return;
      _shiftPending = true;
      widget.onShiftWeek(-1, 6);
      return;
    }
    if (page == _sentinelAfter) {
      if (_shiftPending) return;
      _shiftPending = true;
      widget.onShiftWeek(1, 0);
      return;
    }
    widget.onSelectDay(page - _firstRealPage);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: DayChipStrip(
            days: widget.week.days,
            selectedIndex: widget.dayIndex,
            myCountByIndex: widget.myCountByIndex,
            onSelect: (index) {
              widget.onSelectDay(index);
              _controller.animateToPage(
                _firstRealPage + index,
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOut,
              );
            },
          ),
        ),
        Expanded(
          child: PageView.builder(
            controller: _controller,
            itemCount: _pageCount,
            onPageChanged: _onPageChanged,
            itemBuilder: (context, page) => _DayPage(
              day: _dayFor(page),
              today: widget.today,
              me: widget.me,
              myCount: widget.myCount,
              settings: widget.settings,
              nameById: widget.nameById,
              interactive: page >= _firstRealPage && page <= _lastRealPage
                  ? widget.interactive
                  : false,
              onBook: widget.onBook,
              onCancel: widget.onCancel,
            ),
          ),
        ),
      ],
    );
  }

  /// Resolves which [DaySchedule] a page shows: real pages read straight
  /// from [DayPagerView.week]; sentinels compute the adjacent week's single
  /// boundary day on demand (see the [DayPagerView.overrides] doc comment
  /// for why reservations are empty there).
  DaySchedule _dayFor(int page) {
    if (page >= _firstRealPage && page <= _lastRealPage) {
      return widget.week.days[page - _firstRealPage];
    }
    final monday = widget.today.addDays(
      1 - widget.today.weekday + 7 * widget.weekOffset,
    );
    final sentinelMonday = monday.addDays(page == _sentinelBefore ? -7 : 7);
    final sentinelWeek = buildWeekSchedule(
      monday: sentinelMonday,
      today: widget.today,
      now: widget.now,
      settings: widget.settings,
      blocks: widget.blocks,
      overrides: widget.overrides,
      matches: widget.matches,
      rentals: widget.rentals,
      reservations: const [],
    );
    // sentinelBefore previews that week's Sunday (index 6); sentinelAfter
    // previews its Monday (index 0).
    return sentinelWeek.days[page == _sentinelBefore ? 6 : 0];
  }
}

class _DayPage extends StatelessWidget {
  const _DayPage({
    required this.day,
    required this.today,
    required this.me,
    required this.myCount,
    required this.settings,
    required this.nameById,
    required this.interactive,
    required this.onBook,
    required this.onCancel,
  });

  final DaySchedule day;
  final Day today;
  final Profile? me;
  final int myCount;
  final ScheduleSettings settings;
  final Map<String, String> nameById;
  final bool interactive;
  final void Function(Day, TimeBlock, int lane) onBook;
  final void Function(Day, TimeBlock, Reservation, {required bool ownFuture})
  onCancel;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        switch (day) {
          ClosedDay(:final reason) => Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: DayHeader(
                date: day.date,
                matches: day.matches,
                closedReason: reason,
              ),
            ),
          ),
          OpenDay() => _openDay(context, day as OpenDay),
        },
      ],
    );
  }

  Widget _openDay(BuildContext context, OpenDay day) {
    final isAdmin = me?.isAdmin ?? false;
    final freeCount = day.blocks
        .expand(
          (block) => [
            for (var lane = 1; lane <= day.laneCount; lane++) (block, lane),
          ],
        )
        .where(
          (entry) => canBook(
            state: day.slot(entry.$1.id, entry.$2),
            myActiveCount: myCount,
            settings: settings,
            isAdmin: isAdmin,
          ),
        )
        .length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DayHeader(
              date: day.date,
              matches: day.matches,
              chipLabel: '$freeCount volných',
            ),
            const SizedBox(height: 12),
            for (final block in day.blocks) _laneRow(context, day, block),
          ],
        ),
      ),
    );
  }

  Widget _laneRow(BuildContext context, OpenDay day, TimeBlock block) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text(
                block.label,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var lane = 1; lane <= day.laneCount; lane++)
                  SizedBox(
                    width: 96,
                    child: slotTileFor(
                      day: day,
                      block: block,
                      lane: lane,
                      size: SlotTileSize.large,
                      me: me,
                      myCount: myCount,
                      settings: settings,
                      nameById: nameById,
                      interactive: interactive,
                      onBook: onBook,
                      onCancel: onCancel,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

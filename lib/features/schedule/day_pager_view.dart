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
import 'widgets/day_chip_strip.dart';
import 'widgets/day_header.dart';
import 'widgets/gap_rows.dart';
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
    required this.clubColorById,
    required this.interactive,
    required this.fitWidth,
    required this.onBook,
    required this.onCancel,
    this.onLongPressBlock,
    this.onAddBlockInGap,
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
  final Map<String, int> clubColorById;
  final bool interactive;

  /// When true the lane grid drops its horizontal scroller and lets lanes
  /// share the full width (names ellipsis-clipped); see [_DayPage].
  final bool fitWidth;
  final void Function(Day, TimeBlock, int lane) onBook;

  /// Admin-only (null otherwise): long-press a block label to edit it; tap
  /// an empty gap to add a block prefilled with the gap's range.
  final void Function(TimeBlock)? onLongPressBlock;
  final void Function(HourMinute start, HourMinute end)? onAddBlockInGap;
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

  /// True while a programmatic resync (triggered by [didUpdateWidget], not
  /// by the user's own drag/tap) is in flight — set just before the deferred
  /// `jumpToPage` runs, cleared once it's done. [_onPageChanged] still fires
  /// for that jump (PageController always notifies listeners on a page
  /// change, programmatic or not), but must not re-invoke
  /// onSelectDay/onShiftWeek for it: the shell already knows about this page
  /// — it's the one that told us to land here — so re-reporting it would at
  /// best be redundant and at worst re-fire onShiftWeek for a swipe that was
  /// already handled.
  bool _syncing = false;

  /// Target page of a chip-tap `animateToPage` this widget itself kicked off
  /// (see the `onSelect` handler in [build]), while it's still in flight.
  /// `animateToPage` calls `widget.onSelectDay` synchronously *before*
  /// starting the animation, so the shell's ensuing rebuild — and this
  /// widget's own [didUpdateWidget] — run before the controller's `.page`
  /// has moved off its pre-animation value. Without this guard,
  /// [didUpdateWidget] would see `page != _page` and schedule a resync
  /// `jumpToPage`, snapping the view instantly and cutting the 250 ms
  /// animation short. Comparing against this instead of blindly deferring to
  /// the in-flight animation means a *different* dayIndex arriving from
  /// elsewhere (e.g. a boundary-swipe landing) still resyncs immediately.
  int? _animatingToPage;

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
    //
    // This runs synchronously inside the shell's build (didUpdateWidget is
    // called while the parent is still building), so calling jumpToPage here
    // directly would synchronously fire onPageChanged → onSelectDay/
    // onShiftWeek → the shell's setState *during that same build* — a
    // "setState() or markNeedsBuild() called during build" FlutterError in
    // debug. Deferring to the next frame (addPostFrameCallback) moves the
    // jump safely outside the build phase; _syncing (guarded from the
    // moment we schedule the jump, not just once it runs, so a same-frame
    // rebuild can't sneak another jump in first) then keeps that jump's own
    // onPageChanged from re-reporting a page the shell already told us to
    // show.
    if (widget.dayIndex != oldWidget.dayIndex ||
        widget.weekOffset != oldWidget.weekOffset) {
      _shiftPending = false;
      final alreadyAnimatingHere = _animatingToPage == _page;
      if (_controller.hasClients &&
          _controller.page?.round() != _page &&
          !alreadyAnimatingHere) {
        _syncing = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (_controller.hasClients && _controller.page?.round() != _page) {
            _controller.jumpToPage(_page);
          }
          _syncing = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onPageChanged(int page) {
    // Suppress the notification generated by our own deferred resync jump
    // above — it reports a page the shell already handed us, not a fresh
    // user swipe/tap.
    if (_syncing) return;
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
              final target = _firstRealPage + index;
              widget.onSelectDay(index);
              _animatingToPage = target;
              _controller
                  .animateToPage(
                    target,
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOut,
                  )
                  .then((_) {
                    if (_animatingToPage == target) _animatingToPage = null;
                  });
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
              clubColorById: widget.clubColorById,
              interactive: page >= _firstRealPage && page <= _lastRealPage
                  ? widget.interactive
                  : false,
              fitWidth: widget.fitWidth,
              onBook: widget.onBook,
              onCancel: widget.onCancel,
              onLongPressBlock: widget.onLongPressBlock,
              onAddBlockInGap: widget.onAddBlockInGap,
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
    required this.clubColorById,
    required this.interactive,
    required this.fitWidth,
    required this.onBook,
    required this.onCancel,
    this.onLongPressBlock,
    this.onAddBlockInGap,
  });

  final DaySchedule day;
  final Day today;
  final Profile? me;
  final int myCount;
  final ScheduleSettings settings;
  final Map<String, String> nameById;
  final Map<String, int> clubColorById;
  final bool interactive;

  /// See [DayPagerView.fitWidth].
  final bool fitWidth;
  final void Function(Day, TimeBlock, int lane) onBook;
  final void Function(TimeBlock)? onLongPressBlock;
  final void Function(HourMinute start, HourMinute end)? onAddBlockInGap;
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
            // Lane header + block rows always stay column-aligned: every lane
            // cell is the same width in a given mode, and the header row and
            // block rows are built the same way, so column N of the header
            // always sits over column N of every row.
            //
            // In fit-width mode lanes flex to share the full width (Expanded)
            // and there is no horizontal scroller — the whole day is visible,
            // names ellipsis-clip. Otherwise lanes are fixed-width (96px) and
            // the header + every row share ONE horizontal scroller (not a
            // Wrap, which could reflow lanes onto a second line and leave the
            // header's columns no longer over the tiles they label), so a day
            // with more lanes than fit scrolls all rows together.
            if (fitWidth)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _laneHeaderRow(day),
                  ..._dayRows(context, day),
                ],
              )
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: _rowWidth(day.laneCount),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _laneHeaderRow(day),
                      ..._dayRows(context, day),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static const _laneLabelWidth = 64.0;
  static const _laneTileWidth = 96.0;
  static const _laneTileSpacing = 8.0;

  /// Fixed row width in the horizontally-scrolling mode, so full-width gap
  /// rows can match the lane grid exactly.
  double _rowWidth(int laneCount) =>
      _laneLabelWidth +
      laneCount * _laneTileWidth +
      (laneCount - 1) * _laneTileSpacing;

  /// The block's time label; for admins it long-presses into the block
  /// editor (a small edit glyph hints at the gesture).
  Widget _blockLabel(BuildContext context, TimeBlock block) {
    final label = Text(
      block.label,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    );
    if (onLongPressBlock == null) return label;
    return InkWell(
      onLongPress: () => onLongPressBlock!(block),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: label),
          const SizedBox(width: 2),
          Icon(
            Icons.edit_outlined,
            size: 12,
            color: Theme.of(context)
                .colorScheme
                .onSurfaceVariant
                .withValues(alpha: 0.4),
          ),
        ],
      ),
    );
  }

  /// Block rows interleaved with off-block event banners and empty-gap rows,
  /// in time order (see [dayGridItems]).
  List<Widget> _dayRows(BuildContext context, OpenDay day) => [
        for (final item in dayGridItems(day))
          switch (item) {
            BlockItem(:final block) => _laneRow(context, day, block),
            EventItem(:final event) =>
              GapEventBanner(event: event, compact: false),
            final EmptyGapItem gap => EmptyGapRow(
                item: gap,
                onAdd: onAddBlockInGap == null
                    ? null
                    : () => onAddBlockInGap!(gap.start, gap.end),
              ),
          },
      ];

  /// Wraps a lane cell so it either flexes to share the row's width
  /// (fit-width) or keeps its fixed 96px column plus inter-lane spacing.
  Widget _laneCell({
    required int lane,
    required int laneCount,
    required Widget child,
  }) {
    if (fitWidth) {
      return Expanded(
        child: Padding(
          padding: EdgeInsets.only(
            right: lane == laneCount ? 0 : _laneTileSpacing,
          ),
          child: child,
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.only(right: lane == laneCount ? 0 : _laneTileSpacing),
      child: SizedBox(width: _laneTileWidth, child: child),
    );
  }

  Widget _laneHeaderRow(OpenDay day) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(width: _laneLabelWidth),
          for (var lane = 1; lane <= day.laneCount; lane++)
            _laneCell(
              lane: lane,
              laneCount: day.laneCount,
              child: Text(
                'Dráha $lane',
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
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
            width: _laneLabelWidth,
            child: Padding(
              padding: const EdgeInsets.only(top: 14),
              child: _blockLabel(context, block),
            ),
          ),
          for (var lane = 1; lane <= day.laneCount; lane++)
            _laneCell(
              lane: lane,
              laneCount: day.laneCount,
              child: slotTileFor(
                day: day,
                block: block,
                lane: lane,
                size: SlotTileSize.large,
                me: me,
                myCount: myCount,
                settings: settings,
                nameById: nameById,
                clubColorById: clubColorById,
                interactive: interactive,
                onBook: onBook,
                onCancel: onCancel,
              ),
            ),
        ],
      ),
    );
  }
}

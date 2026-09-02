/// The app's week view as a calendar: an hour ruler on the left, days as
/// columns, each block positioned at its true time and holding one bookable
/// row per lane. Off-block matches/rentals render as bands at their true
/// time; empty calendar space is visible time — and for admins, tappable
/// (prefills the add-block dialog with the free gap under the finger).
/// Long-pressing a block card (admin) opens the block editor.
///
/// Geometry: ONE [CalendarWindow] + px/minute pair per build, shared by the
/// ruler and every column — cross-column alignment holds by construction.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;

import '../../domain/calendar_layout.dart';
import '../../domain/models.dart';
import '../../domain/schedule.dart';
import 'widgets/calendar_board.dart';
import 'widgets/schedule_day_column.dart';
import 'widgets/slot_tile.dart';

class WeekCalendarView extends StatefulWidget {
  const WeekCalendarView({
    super.key,
    required this.week,
    required this.today,
    required this.now,
    required this.me,
    required this.myCount,
    required this.settings,
    required this.nameById,
    required this.clubColorById,
    required this.interactive,
    required this.onBook,
    required this.onCancel,
    this.onEditBlock,
    this.onAddBlockInGap,
    this.onAddForDay,
    this.onEditPrioritySlot,
    this.onMoveBlock,
    this.onMovePrioritySlot,
  });

  final WeekSchedule week;
  final Day today;
  final HourMinute now;
  final Profile? me;
  final int myCount;
  final ScheduleSettings settings;
  final Map<String, String> nameById;
  final Map<String, int> clubColorById;
  final bool interactive;
  final void Function(Day, TimeBlock, int lane) onBook;
  final void Function(Day, TimeBlock, Reservation, {required bool ownFuture})
      onCancel;

  /// Admin-only (null otherwise). Click the card's time header (or a
  /// blocking band) to edit FOR THAT DAY; tap empty column space or the
  /// header ＋ to add; HOLD a card/band and drag it onto empty space to
  /// move it within the day (snap 5 min) — see [ScheduleDayColumn].
  final void Function(Day date, TimeBlock block)? onEditBlock;
  final void Function(Day date, HourMinute start, HourMinute end)?
      onAddBlockInGap;
  final void Function(Day date)? onAddForDay;
  final void Function(Day date, PrioritySlot slot)? onEditPrioritySlot;
  final void Function(Day date, TimeBlock block, HourMinute newStart)?
      onMoveBlock;
  final void Function(Day date, PrioritySlot slot, HourMinute newStart)?
      onMovePrioritySlot;

  @override
  State<WeekCalendarView> createState() => _WeekCalendarViewState();
}

class _WeekCalendarViewState extends State<WeekCalendarView> {
  final _vScroll = ScrollController();

  /// Scrolled away from the top: the sticky header strip collapses to the
  /// thin day+date band (events reappear when scrolled back up).
  bool _collapsed = false;

  /// The default vertical position: the first TRAINING block's top. Morning
  /// matches/úklid may stretch the window well above the training hours —
  /// they stay reachable by scrolling up, but the board opens on what the
  /// player came for. Also the baseline the header collapse measures from
  /// (sitting at the default anchor keeps the events visible).
  ///
  /// Re-applied whenever the computed anchor CHANGES until the user scrolls
  /// by hand: streams settle one by one after the first frame (a morning
  /// match arriving late stretches the window upward), so a one-shot jump
  /// would fire before there is anything to scroll past and then leave the
  /// board parked at the morning event.
  ///
  /// Takeover detection is GESTURE-based (see the UserScrollNotification
  /// listener in build), never offset-based: spurious scroll notifications
  /// (scrollbar attach, dimension changes) fire between the build that
  /// computes a new anchor and its post-frame jump, and an offset
  /// comparison there latched a false "user scrolled" that blocked the
  /// jump forever. [_appliedAnchor] is committed only AFTER a successful
  /// jump so an aborted callback retries on the next build.
  double _anchorOffset = 0;
  double? _appliedAnchor;
  bool _userScrolled = false;

  @override
  void initState() {
    super.initState();
    _vScroll.addListener(() {
      if (!_vScroll.hasClients) return;
      // Hysteresis relative to the default anchor: collapse a bit past it,
      // expand when back near (or above) it — no flapping around one magic
      // offset, and no auto-collapse just for opening at the anchor.
      final offset = _vScroll.offset - _anchorOffset;
      final collapsed = _collapsed ? offset > 8 : offset > 32;
      if (collapsed != _collapsed) setState(() => _collapsed = collapsed);
    });
  }

  @override
  void didUpdateWidget(WeekCalendarView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A different week starts fresh: anchor to its training blocks again.
    if (oldWidget.week.days.first.date != widget.week.days.first.date) {
      _userScrolled = false;
      _appliedAnchor = null;
    }
  }

  @override
  void dispose() {
    _vScroll.dispose();
    super.dispose();
  }

  /// Bookable-slot count for the header's quiet subtitle.
  String? _freeLabel(DaySchedule day) {
    if (day is! OpenDay) return null;
    final freeCount = bookableSlotCount(
      day,
      myActiveCount: widget.myCount,
      settings: widget.settings,
      isAdmin: widget.me?.isAdmin ?? false,
    );
    return '$freeCount volných';
  }

  @override
  Widget build(BuildContext context) {
    final week = widget.week;
    final settings = widget.settings;
    final window = calendarWindowFor(
      blocks: [
        for (final day in week.days)
          if (day is OpenDay) ...day.blocks,
      ],
      eventWindows: [
        for (final day in week.days) ...[
          for (final m in day.priority) (m.startsAt, m.endsAt),
          if (day is OpenDay)
            for (final r in day.rentals) (r.startsAt, r.endsAt),
        ],
      ],
    );
    if (window == null) {
      return const Center(child: Text('Tenhle týden se nehraje.'));
    }
    final pxPerMinute = settings.laneCount * laneRowRefHeight / 60;
    // Shared header height: the busiest visible day dictates it for every
    // column, so all event lines fit without clipping.
    var maxHeaderEvents = 0;
    for (final day in week.days) {
      final count = headerEvents(day).length;
      if (count > maxHeaderEvents) maxHeaderEvents = count;
    }
    final headerHeight = boardHeaderHeight(maxHeaderEvents);
    // Half-hour ruler labels/gridlines only when the alley actually uses
    // half-hour block boundaries.
    final halfHourMarks = [
      for (final day in week.days)
        if (day is OpenDay) ...day.blocks,
    ].any((b) => b.startsAt.minute == 30 || b.endsAt.minute == 30);
    // +8: slack so the bottom hour label (centered on its line) isn't
    // half-clipped when scrolled fully down.
    final bodyHeight = window.minutes * pxPerMinute + 8;

    // Default anchor: the earliest TRAINING block of the week. When morning
    // events stretch the window above the training hours, the board still
    // opens on the blocks (scroll up for the matches).
    int? firstBlockMinute;
    for (final day in week.days) {
      if (day is! OpenDay) continue;
      for (final b in day.blocks) {
        final m = b.startsAt.minutesFromMidnight;
        if (firstBlockMinute == null || m < firstBlockMinute) {
          firstBlockMinute = m;
        }
      }
    }
    _anchorOffset = firstBlockMinute == null
        ? 0
        : ((firstBlockMinute - window.startMinute) * pxPerMinute - 8)
            .clamp(0.0, double.infinity);
    if (!_userScrolled && _appliedAnchor != _anchorOffset) {
      final target = _anchorOffset;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _userScrolled || !_vScroll.hasClients) return;
        _vScroll.jumpTo(target.clamp(0.0, _vScroll.position.maxScrollExtent));
        // Committed only now: an aborted callback (not mounted yet, no
        // clients) leaves the anchor unapplied so the next build retries.
        _appliedAnchor = target;
      });
    }

    final columns = [
      for (final day in week.days)
        ScheduleDayColumn(
          // Keyed by date so tests can target one day's column.
          key: ValueKey(day.date),
          day: day,
          window: window,
          pxPerMinute: pxPerMinute,
          halfHourMarks: halfHourMarks,
          nowMinute: day.date == widget.today &&
                  widget.now.minutesFromMidnight >= window.startMinute &&
                  widget.now.minutesFromMidnight < window.endMinute
              ? widget.now.minutesFromMidnight
              : null,
          laneRow: _laneRow,
          onEditBlock: widget.onEditBlock,
          onAddBlockInGap: widget.onAddBlockInGap,
          onEditPrioritySlot: widget.onEditPrioritySlot,
          onMoveBlock: widget.onMoveBlock,
          onMovePrioritySlot: widget.onMovePrioritySlot,
        ),
    ];

    // Sticky header strip: stays pinned while the calendar scrolls
    // vertically, collapsing to a thin day+date band away from the top.
    final headerStrip = Row(
      children: [
        const SizedBox(width: calendarRulerWidth),
        for (final day in week.days)
          Expanded(
            child: BoardColumnHeader(
              date: day.date,
              isToday: day.date == widget.today,
              priority: headerEvents(day),
              height: headerHeight,
              collapsed: _collapsed,
              subtitle: _freeLabel(day),
              onAdd: widget.onAddForDay == null
                  ? null
                  : () => widget.onAddForDay!(day.date),
            ),
          ),
      ],
    );

    return Column(
      children: [
        headerStrip,
        Expanded(
          // A REAL scroll gesture (drag or wheel — both flip the user
          // scroll direction; our own jumpTo only emits idle) hands the
          // vertical position over to the user: no more re-anchoring.
          child: NotificationListener<UserScrollNotification>(
            onNotification: (notification) {
              if (notification.direction != ScrollDirection.idle) {
                _userScrolled = true;
              }
              return false;
            },
            child: SingleChildScrollView(
              controller: _vScroll,
              child: SizedBox(
                height: bodyHeight,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    HourRuler(
                      window: window,
                      pxPerMinute: pxPerMinute,
                      halfHourMarks: halfHourMarks,
                    ),
                    for (final column in columns) Expanded(child: column),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// One lane row of a block card: the lane digit beside a compact
  /// [SlotTile] carrying the app's booking/cancel policy ([slotTileFor]).
  Widget _laneRow(
      BuildContext context, OpenDay openDay, TimeBlock block, int lane) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1.5),
      child: Row(
        children: [
          SizedBox(
            width: 12,
            child: Text(
              '$lane',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            ),
          ),
          const SizedBox(width: 2),
          Expanded(
            child: slotTileFor(
              day: openDay,
              block: block,
              lane: lane,
              size: SlotTileSize.compact,
              me: widget.me,
              myCount: widget.myCount,
              settings: widget.settings,
              nameById: widget.nameById,
              clubColorById: widget.clubColorById,
              interactive: widget.interactive,
              onBook: widget.onBook,
              onCancel: widget.onCancel,
            ),
          ),
        ],
      ),
    );
  }
}

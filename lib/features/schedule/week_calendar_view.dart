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

import '../../domain/calendar_layout.dart';
import '../../domain/models.dart';
import '../../domain/palette.dart';
import '../../domain/schedule.dart';
import 'widgets/calendar_board.dart';
import 'widgets/slot_tile.dart';

/// Drag&drop payloads: what a held card/band carries to the drop target.
/// [hoverMinute] is the live-preview channel: the hovered column publishes
/// the snapped would-be start minute, the drag ghost renders it as od–do.
class BlockDragData {
  BlockDragData(this.date, this.block);
  final Day date;
  final TimeBlock block;
  final ValueNotifier<int?> hoverMinute = ValueNotifier(null);
}

class SlotDragData {
  SlotDragData(this.slot);
  final PrioritySlot slot;
  final ValueNotifier<int?> hoverMinute = ValueNotifier(null);
}

/// D&D snap grid: 5 minutes.
int _snapMinute(int minute) => ((minute + 2) ~/ 5) * 5;

/// Vertical scale: a 60-minute block is as tall as [_refLaneRowHeight] per
/// lane — the same room the old week grid gave its rows.
const double _refLaneRowHeight = 40.0;

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
  /// move it within the day (snap 15 min).
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
  /// player came for. Applied once per mount; also the baseline the header
  /// collapse measures from (sitting at the default anchor keeps the
  /// events visible).
  double _anchorOffset = 0;
  bool _didInitialScroll = false;

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
  void dispose() {
    _vScroll.dispose();
    super.dispose();
  }

  /// Bookable-slot count for the header's quiet subtitle.
  String? _freeLabel(DaySchedule day) {
    if (day is! OpenDay) return null;
    final isAdmin = widget.me?.isAdmin ?? false;
    final freeCount = day.blocks
        .expand((block) =>
            [for (var lane = 1; lane <= day.laneCount; lane++) (block, lane)])
        .where((entry) => canBook(
              state: day.slot(entry.$1.id, entry.$2),
              myActiveCount: widget.myCount,
              settings: widget.settings,
              isAdmin: isAdmin,
            ))
        .length;
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
    final pxPerMinute = settings.laneCount * _refLaneRowHeight / 60;
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
    if (!_didInitialScroll) {
      _didInitialScroll = true;
      final target = _anchorOffset;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_vScroll.hasClients || target <= 0) return;
        _vScroll.jumpTo(target.clamp(0.0, _vScroll.position.maxScrollExtent));
      });
    }

    final columns = [
      for (final day in week.days)
        _DayColumn(
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
          me: widget.me,
          myCount: widget.myCount,
          settings: settings,
          nameById: widget.nameById,
          clubColorById: widget.clubColorById,
          interactive: widget.interactive,
          onBook: widget.onBook,
          onCancel: widget.onCancel,
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
      ],
    );
  }
}

class _DayColumn extends StatelessWidget {
  const _DayColumn({
    super.key,
    required this.day,
    required this.window,
    required this.pxPerMinute,
    required this.halfHourMarks,
    required this.nowMinute,
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
    this.onEditPrioritySlot,
    this.onMoveBlock,
    this.onMovePrioritySlot,
  });

  final DaySchedule day;
  final CalendarWindow window;
  final double pxPerMinute;
  final bool halfHourMarks;
  final int? nowMinute;
  final Profile? me;
  final int myCount;
  final ScheduleSettings settings;
  final Map<String, String> nameById;
  final Map<String, int> clubColorById;
  final bool interactive;
  final void Function(Day, TimeBlock, int lane) onBook;
  final void Function(Day, TimeBlock, Reservation, {required bool ownFuture})
      onCancel;
  final void Function(Day date, TimeBlock block)? onEditBlock;
  final void Function(Day date, HourMinute start, HourMinute end)?
      onAddBlockInGap;
  final void Function(Day date, PrioritySlot slot)? onEditPrioritySlot;
  final void Function(Day date, TimeBlock block, HourMinute newStart)?
      onMoveBlock;
  final void Function(Day date, PrioritySlot slot, HourMinute newStart)?
      onMovePrioritySlot;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final openDay = day is OpenDay ? day as OpenDay : null;

    // Everything this day already shows — blocks AND event bands. Taps on
    // free space prefill the add-block dialog with the surrounding gap, so
    // "occupied" must include event bands or the prefill would overlap a
    // visible rental/match.
    final occupied = mergeIntervals([
      if (openDay != null)
        for (final b in openDay.blocks)
          (b.startsAt.minutesFromMidnight, b.endsAt.minutesFromMidnight),
      for (final m in day.priority)
        (m.startsAt.minutesFromMidnight, m.endsAt.minutesFromMidnight),
      if (openDay != null)
        for (final r in openDay.rentals)
          (r.startsAt.minutesFromMidnight, r.endsAt.minutesFromMidnight),
    ]);

    final onTapFree = onAddBlockInGap == null
        ? null
        : (int minute) {
            final gap = freeGapAt(minute, occupied, window);
            if (gap == null) return;
            onAddBlockInGap!(
                day.date, hourMinuteAt(gap.$1), hourMinuteAt(gap.$2));
          };

    // Drag&drop landing: snap the ghost's top edge to 5 minutes and only
    // accept when the whole slot (a match brings its úklid child along)
    // fits into free space of THIS day.
    void handleDrop(Object data, int minute) {
      final snapped = _snapMinute(minute);
      (int, int)? candidate;
      void Function()? commit;
      List<(int, int)> self = const [];
      if (data is BlockDragData && data.date == day.date) {
        final dur = data.block.durationMinutes;
        candidate = (snapped, snapped + dur);
        self = [
          (
            data.block.startsAt.minutesFromMidnight,
            data.block.endsAt.minutesFromMidnight
          )
        ];
        commit = () =>
            onMoveBlock?.call(day.date, data.block, hourMinuteAt(snapped));
      } else if (data is SlotDragData && data.slot.date == day.date) {
        final s = data.slot;
        final dur = s.endsAt.minutesFromMidnight - s.startsAt.minutesFromMidnight;
        final child = day.priority
            .where((m) => m.parentId == s.id)
            .firstOrNull;
        final childDur = child == null
            ? 0
            : child.endsAt.minutesFromMidnight -
                child.startsAt.minutesFromMidnight;
        candidate = (snapped - childDur, snapped + dur);
        self = [
          (s.startsAt.minutesFromMidnight, s.endsAt.minutesFromMidnight),
          if (child != null)
            (
              child.startsAt.minutesFromMidnight,
              child.endsAt.minutesFromMidnight
            ),
        ];
        commit = () =>
            onMovePrioritySlot?.call(day.date, s, hourMinuteAt(snapped));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Přesun jde jen v rámci stejného dne.')));
        return;
      }
      final (cs, ce) = candidate;
      final selfUnion = mergeIntervals(self);
      final occupiedMinusSelf = mergeIntervals([
        for (final (s0, e0) in occupied)
          ...subtractInterval((s0, e0), selfUnion),
      ]);
      final fits = cs >= window.startMinute &&
          ce <= window.endMinute &&
          !occupiedMinusSelf.any((iv) => iv.$1 < ce && iv.$2 > cs);
      if (!fits) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Tady není volné místo.')));
        return;
      }
      commit();
    }

    final canMove = onMoveBlock != null || onMovePrioritySlot != null;

    // Live drop-time preview: publish the snapped minute to the payload's
    // notifier while its ghost hovers over THIS day's column (a foreign
    // day would refuse the drop, so it previews nothing).
    ValueNotifier<int?>? hoverOf(Object data) => switch (data) {
          BlockDragData d when d.date == day.date => d.hoverMinute,
          SlotDragData d when d.slot.date == day.date => d.hoverMinute,
          _ => null,
        };
    void handleDragAt(Object data, int minute) =>
        hoverOf(data)?.value = _snapMinute(minute);
    void handleDragExit(Object data) => hoverOf(data)?.value = null;

    return CalendarColumn(
      window: window,
      pxPerMinute: pxPerMinute,
      halfHourMarks: halfHourMarks,
      entries: _entries(context, openDay),
      background: openDay == null ? _closedBackground(context, scheme) : null,
      nowMinute: nowMinute,
      onTapFreeAt: onTapFree,
      onDropAt: canMove ? handleDrop : null,
      onDragAt: canMove ? handleDragAt : null,
      onDragExit: canMove ? handleDragExit : null,
    );
  }

  List<CalendarEntry> _entries(BuildContext context, OpenDay? openDay) {
    final entries = <CalendarEntry>[];
    final blockUnion = mergeIntervals([
      if (openDay != null)
        for (final b in openDay.blocks)
          (b.startsAt.minutesFromMidnight, b.endsAt.minutesFromMidnight),
    ]);

    if (openDay != null) {
      for (final block in openDay.blocks) {
        entries.add(CalendarEntry(
          start: block.startsAt,
          end: block.endsAt,
          child: _blockCard(context, openDay, block),
        ));
      }
    }

    final scheme = Theme.of(context).colorScheme;
    // `covered` grows with every emitted band, so overlaps resolve
    // first-wins in emission order: priority slots (start-sorted) before
    // rentals — a renter band can never paint over a match.
    final covered = <(int, int)>[...blockUnion];
    void addBands(
        HourMinute start, HourMinute end, Widget Function() bandBuilder) {
      for (final (s, e) in subtractInterval(
          (start.minutesFromMidnight, end.minutesFromMidnight),
          mergeIntervals(covered))) {
        entries.add(CalendarEntry(
            start: hourMinuteAt(s), end: hourMinuteAt(e), child: bandBuilder()));
        covered.add((s, e));
      }
    }

    for (final m in day.priority) {
      final club = ClubColors.of(m.type.colorIndex, scheme.brightness);
      Widget band() {
        Widget w = CalendarEventBand(
          background: club?.$1 ?? scheme.errorContainer.withValues(alpha: 0.6),
          foreground: club?.$2 ?? scheme.onErrorContainer,
          text: '${m.type.isMatch ? '🏆' : '⛔'} ${m.title}\n'
              '${m.startsAt.display()}–${m.endsAt.display()}',
          bold: true,
        );
        // Click = edit (a click has nothing else to do on a blocking band);
        // an úklid child edits its parent match.
        if (onEditPrioritySlot != null) {
          w = InkWell(
            onTap: () => onEditPrioritySlot!(day.date, m),
            child: w,
          );
        }
        // HOLD = move. Úklid children follow their match, they don't move
        // on their own.
        if (onMovePrioritySlot != null && m.parentId == null) {
          final data = SlotDragData(m);
          w = _draggable(
            context,
            data: data,
            hoverMinute: data.hoverMinute,
            label: m.title,
            heightMinutes: m.endsAt.minutesFromMidnight -
                m.startsAt.minutesFromMidnight,
            child: w,
          );
        }
        return w;
      }

      addBands(m.startsAt, m.endsAt, band);
    }
    if (openDay != null) {
      for (final r in openDay.rentals) {
        final club = ClubColors.of(r.color, scheme.brightness);
        addBands(
          r.startsAt,
          r.endsAt,
          () => CalendarEventBand(
            background:
                club?.$1 ?? scheme.tertiaryContainer.withValues(alpha: 0.5),
            foreground: club?.$2 ?? scheme.onTertiaryContainer,
            text: '🔒 ${r.renterName}\n'
                '${r.startsAt.display()}–${r.endsAt.display()}',
          ),
        );
      }
    }
    return entries;
  }

  Widget _closedBackground(BuildContext context, ColorScheme scheme) {
    final closedDay = day as ClosedDay;
    return Container(
      color: scheme.surfaceContainerLowest.withValues(alpha: 0.5),
      alignment: Alignment.center,
      child: RotatedBox(
        quarterTurns: 3,
        child: Text(
          closedDay.reason.isEmpty
              ? '✕ zavřeno'
              : '✕ zavřeno — ${closedDay.reason}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
          ),
        ),
      ),
    );
  }

  /// One block's calendar card: a thin time header ('17:30–18:30' — for
  /// admins a click-to-edit target) over one bookable [SlotTile] row per
  /// lane. Whole-alley priority slots never reach a rendered block (they
  /// cancel overlapping blocks in buildWeekSchedule and render as
  /// true-time bands); lane-scoped slots resolve per lane row. Admins HOLD
  /// the card to drag it onto empty space (same-day move).
  Widget _blockCard(BuildContext context, OpenDay openDay, TimeBlock block) {
    final scheme = Theme.of(context).colorScheme;

    // Same ground as the card — the header is typography, not a bar: quiet
    // spaced small-caps-like digits that read as a label, not a stripe.
    final headerText = Text(
      block.label,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: 9,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.8,
        fontFeatures: const [FontFeature.tabularFigures()],
        color: scheme.onSurfaceVariant.withValues(alpha: 0.55),
      ),
    );
    final header = Container(
      height: 14,
      alignment: Alignment.center,
      child: onEditBlock == null
          ? headerText
          : InkWell(
              onTap: () => onEditBlock!(openDay.date, block),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  headerText,
                  const SizedBox(width: 3),
                  Icon(
                    Icons.edit_outlined,
                    size: 9,
                    color: scheme.onSurfaceVariant.withValues(alpha: 0.45),
                  ),
                ],
              ),
            ),
    );

    final card = Container(
      // Stable per-block key (unique among one column's entries) so tests
      // can measure card geometry and target gestures.
      key: ValueKey('cal-block-${block.id}'),
      // The 1.5px vertical inset matches CalendarEventBand's, so a band and
      // a touching block card keep a visible seam between them.
      margin: const EdgeInsets.symmetric(horizontal: 1, vertical: 1.5),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        children: [
          header,
          Expanded(
            child: Column(
              children: [
                for (var lane = 1; lane <= openDay.laneCount; lane++)
                  Expanded(child: _laneRow(context, openDay, block, lane)),
              ],
            ),
          ),
        ],
      ),
    );
    if (onMoveBlock == null) return card;
    final data = BlockDragData(openDay.date, block);
    return _draggable(
      context,
      data: data,
      hoverMinute: data.hoverMinute,
      label: block.label,
      heightMinutes: block.durationMinutes,
      child: card,
    );
  }

  /// HOLD-to-drag wrapper shared by cards and bands: the ghost is a simple
  /// tinted box of the slot's true size so the admin can align its top
  /// edge with the target time — which it live-previews as 'od–do' from
  /// [hoverMinute] (published by the hovered column, see handleDragAt).
  Widget _draggable(
    BuildContext context, {
    required Object data,
    required ValueNotifier<int?> hoverMinute,
    required String label,
    required int heightMinutes,
    required Widget child,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) => LongPressDraggable<Object>(
        data: data,
        delay: const Duration(milliseconds: 200),
        feedback: Material(
          color: Colors.transparent,
          child: Container(
            width: constraints.maxWidth,
            height: heightMinutes * pxPerMinute,
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withValues(alpha: 0.75),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: scheme.primary),
            ),
            alignment: Alignment.center,
            child: ValueListenableBuilder<int?>(
              valueListenable: hoverMinute,
              builder: (context, minute, _) => Text(
                minute == null
                    ? label
                    : '${hourMinuteAt(minute).display()}–'
                        '${hourMinuteAt(minute + heightMinutes).display()}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: scheme.onPrimaryContainer,
                ),
              ),
            ),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.35, child: child),
        child: child,
      ),
    );
  }

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

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

/// Vertical scale: a 60-minute block is as tall as [_refLaneRowHeight] per
/// lane — the same room the old week grid gave its rows.
const double _refLaneRowHeight = 40.0;

class WeekCalendarView extends StatelessWidget {
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
    required this.fitWidth,
    required this.onBook,
    required this.onCancel,
    this.onLongPressBlock,
    this.onAddBlockInGap,
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

  /// When true all 7 columns share the available width (no horizontal
  /// scroll); otherwise columns keep a fixed readable width inside a
  /// column-snapping horizontal scroller.
  final bool fitWidth;
  final void Function(Day, TimeBlock, int lane) onBook;
  final void Function(Day, TimeBlock, Reservation, {required bool ownFuture})
      onCancel;

  /// Admin-only (null otherwise): long-press a block card to edit it; tap
  /// an empty stretch of a day column to add a block prefilled with the
  /// free gap around the tapped time.
  final void Function(TimeBlock)? onLongPressBlock;
  final void Function(HourMinute start, HourMinute end)? onAddBlockInGap;

  @override
  Widget build(BuildContext context) {
    final window = calendarWindowFor(
      blocks: [
        for (final day in week.days)
          if (day is OpenDay) ...day.blocks,
      ],
      eventWindows: [
        for (final day in week.days) ...[
          // blockingStart: the prep band renders too, so it must fit.
          for (final m in day.priority) (m.blockingStart, m.endsAt),
          if (day is OpenDay)
            for (final r in day.rentals) (r.startsAt, r.endsAt),
        ],
      ],
    );
    if (window == null) {
      return const Center(child: Text('Tenhle týden se nehraje.'));
    }
    final pxPerMinute = settings.laneCount * _refLaneRowHeight / 60;
    // +8: slack so the bottom hour label (centered on its line) isn't
    // half-clipped when scrolled fully down.
    final totalHeight = calendarHeaderHeight + window.minutes * pxPerMinute + 8;

    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = [
          for (final day in week.days)
            _DayColumn(
              // Keyed by date so tests can target one day's column.
              key: ValueKey(day.date),
              day: day,
              isToday: day.date == today,
              window: window,
              pxPerMinute: pxPerMinute,
              nowMinute: day.date == today &&
                      now.minutesFromMidnight >= window.startMinute &&
                      now.minutesFromMidnight < window.endMinute
                  ? now.minutesFromMidnight
                  : null,
              me: me,
              myCount: myCount,
              settings: settings,
              nameById: nameById,
              clubColorById: clubColorById,
              interactive: interactive,
              onBook: onBook,
              onCancel: onCancel,
              onLongPressBlock: onLongPressBlock,
              onAddBlockInGap: onAddBlockInGap,
            ),
        ];
        final columnWidth = boardColumnWidth(constraints.maxWidth);

        return SingleChildScrollView(
          child: SizedBox(
            height: totalHeight,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Column(
                  children: [
                    const SizedBox(height: calendarHeaderHeight),
                    HourRuler(window: window, pxPerMinute: pxPerMinute),
                  ],
                ),
                Expanded(
                  child: fitWidth
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final column in columns)
                              Expanded(child: column),
                          ],
                        )
                      : SizedBox(
                          height: totalHeight,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            physics:
                                ColumnSnapPhysics(columnWidth: columnWidth),
                            itemCount: columns.length,
                            itemBuilder: (context, index) => SizedBox(
                              width: columnWidth,
                              child: columns[index],
                            ),
                          ),
                        ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _DayColumn extends StatelessWidget {
  const _DayColumn({
    super.key,
    required this.day,
    required this.isToday,
    required this.window,
    required this.pxPerMinute,
    required this.nowMinute,
    required this.me,
    required this.myCount,
    required this.settings,
    required this.nameById,
    required this.clubColorById,
    required this.interactive,
    required this.onBook,
    required this.onCancel,
    this.onLongPressBlock,
    this.onAddBlockInGap,
  });

  final DaySchedule day;
  final bool isToday;
  final CalendarWindow window;
  final double pxPerMinute;
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
  final void Function(TimeBlock)? onLongPressBlock;
  final void Function(HourMinute start, HourMinute end)? onAddBlockInGap;

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
        (m.blockingStart.minutesFromMidnight, m.endsAt.minutesFromMidnight),
      if (openDay != null)
        for (final r in openDay.rentals)
          (r.startsAt.minutesFromMidnight, r.endsAt.minutesFromMidnight),
    ]);

    final onTapFree = onAddBlockInGap == null
        ? null
        : (int minute) {
            final gap = freeGapAt(minute, occupied, window);
            if (gap == null) return;
            onAddBlockInGap!(hourMinuteAt(gap.$1), hourMinuteAt(gap.$2));
          };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        BoardColumnHeader(
          date: day.date,
          isToday: isToday,
          priority: day.priority,
          subtitle: openDay == null ? null : _freeLabel(openDay),
        ),
        CalendarColumn(
          window: window,
          pxPerMinute: pxPerMinute,
          entries: _entries(context, openDay),
          background: openDay == null
              ? _closedBackground(context, scheme)
              : null,
          nowMinute: nowMinute,
          onTapFreeAt: onTapFree,
        ),
      ],
    );
  }

  String? _freeLabel(OpenDay day) {
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
    return '$freeCount volných';
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
    void addBands(
        HourMinute start, HourMinute end, Widget Function() bandBuilder) {
      for (final (s, e) in subtractInterval(
          (start.minutesFromMidnight, end.minutesFromMidnight), blockUnion)) {
        entries.add(CalendarEntry(
            start: hourMinuteAt(s), end: hourMinuteAt(e), child: bandBuilder()));
      }
    }

    for (final m in day.priority) {
      final club = ClubColors.of(m.type.colorIndex, scheme.brightness);
      // Whole-alley slots with prep get an honest muted band over the prep
      // window — the lanes are being prepped there, at that real time.
      if (m.type.lanes == null && m.blockingStart != m.startsAt) {
        addBands(
          m.blockingStart,
          m.startsAt,
          () => CalendarEventBand(
            background: scheme.errorContainer.withValues(alpha: 0.25),
            foreground: scheme.onSurfaceVariant,
            text: '🛠 Příprava drah\n'
                '${m.blockingStart.display()}\u2013${m.startsAt.display()}',
          ),
        );
      }
      addBands(
        m.startsAt,
        m.endsAt,
        () => CalendarEventBand(
          background: club?.$1 ?? scheme.errorContainer.withValues(alpha: 0.6),
          foreground: club?.$2 ?? scheme.onErrorContainer,
          text: '${m.type.isMatch ? '🏆' : '⛔'} ${m.title}\n'
              '${m.startsAt.display()}–${m.endsAt.display()}',
          bold: true,
        ),
      );
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

  /// One block's calendar card: one bookable [SlotTile] row per lane.
  /// Whole-alley priority slots never reach a rendered block (they cancel
  /// overlapping blocks in buildWeekSchedule and render as true-time bands);
  /// lane-scoped slots resolve per lane row. Admins long-press anywhere on
  /// the card to edit the block (a small edit glyph in the corner hints it).
  Widget _blockCard(BuildContext context, OpenDay openDay, TimeBlock block) {
    final scheme = Theme.of(context).colorScheme;

    final content = Column(
      children: [
        for (var lane = 1; lane <= openDay.laneCount; lane++)
          Expanded(child: _laneRow(context, openDay, block, lane)),
      ],
    );

    final card = Container(
      // Stable per-block key (unique among one column's entries) so tests
      // can measure card geometry and target long-presses.
      key: ValueKey('cal-block-${block.id}'),
      margin: const EdgeInsets.symmetric(horizontal: 1),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: onLongPressBlock == null
          ? content
          : Stack(
              children: [
                Positioned.fill(child: content),
                Positioned(
                  top: 2,
                  right: 3,
                  child: IgnorePointer(
                    child: Icon(
                      Icons.edit_outlined,
                      size: 12,
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.4),
                    ),
                  ),
                ),
              ],
            ),
    );
    if (onLongPressBlock == null) return card;
    return GestureDetector(
      onLongPress: () => onLongPressBlock!(block),
      child: card,
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
